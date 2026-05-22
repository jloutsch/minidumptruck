import SwiftUI
import AppKit
import MiniDumpTruckCore

extension NSDocumentController: RecentDocumentsHost {}

/// Modal confirm-before-replace prompt for the `.onOpenURL` happy path.
/// Returns `true` if the user wants the new file to replace the current
/// document, `false` to keep the current document and discard the open.
@MainActor
private func confirmReplaceCurrentDocument(newFile name: String) -> Bool {
    let alert = NSAlert()
    alert.messageText = "Replace open dump?"
    alert.informativeText = "Opening \(name) will close the current analysis. Continue?"
    alert.alertStyle = .warning
    alert.addButton(withTitle: "Open")
    alert.addButton(withTitle: "Cancel")
    return alert.runModal() == .alertFirstButtonReturn
}

/// App-level convenience that wires the shared `NSDocumentController` and
/// `TempStore.isInsideCache` into the testable `sweepCacheEntries` core
/// helper. We can't intercept individual `noteNewRecentDocumentURL`
/// calls without subclassing `NSDocumentController`, and subclassing
/// crashes SwiftUI's `PlatformDocumentController` during
/// `applicationWillFinishLaunching` in `.app`-bundle launches (#46).
/// Instead we sweep on a known cadence: launch, after
/// `TempStore.cleanupAged`, and at termination.
@MainActor
private func purgeStaleCacheEntries() {
    sweepCacheEntries(from: NSDocumentController.shared, isCacheURL: TempStore.isInsideCache)
}

@main
struct MiniDumpTruckApp: App {
    @State private var openedDocument: MinidumpDocument?
    /// Set when a file open arrives via `.onOpenURL` (Finder, Dock, `open`)
    /// and resolves to anything other than `.openInPlace` — e.g. a zip
    /// that needs the picker, or a parse failure. WelcomeView observes
    /// and runs it through the same `WelcomeRouter` path as drag-and-drop.
    @State private var pendingExternalOutcome: PendingOutcome?
    @AppStorage("zoomScale") private var zoomScale: Double = 1.0

    init() {
        // Sweep cache URLs out of Recent Documents once AppKit has finished
        // its own applicationWillFinishLaunching — touching
        // recentDocumentURLs earlier risks racing the shared controller's
        // own initialization. willFinishLaunchingNotification fires just
        // before AppKit asks the controller to restore documents, which is
        // also when stale "open recent" entries would otherwise be exposed.
        //
        // The returned observer token is intentionally discarded: this
        // observer lives for the lifetime of the process. NSNotificationCenter
        // holds a weak reference to the block-based observer's host object;
        // since we have no removal site we don't need the token.
        _ = NotificationCenter.default.addObserver(
            forName: NSApplication.willFinishLaunchingNotification,
            object: nil,
            queue: nil
        ) { _ in
            // Bridge through `Task { @MainActor in ... }` rather than
            // `MainActor.assumeIsolated` because the latter relies on
            // OperationQueue.main being main-actor-isolated, which is
            // implementation detail rather than a documented Swift
            // concurrency guarantee.
            Task { @MainActor in purgeStaleCacheEntries() }
        }

        // Defense in depth: sweep at termination so anything that landed
        // in recents during this session is gone before AppKit flushes
        // the prefs plist. With no DocumentGroup wiring, the current code
        // path doesn't auto-record URLs — but this guard survives future
        // changes (e.g. adding an Open Recent menu) that might.
        _ = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: nil
        ) { _ in
            Task { @MainActor in purgeStaleCacheEntries() }
        }

        // Best-effort cleanup of zip-extracted tempfiles older than 24 hours.
        // Sweep recents again after the cleanup so entries pointing at
        // just-deleted files don't survive until the next launch.
        Task.detached(priority: .background) {
            await TempStore.cleanupAged(olderThan: 24 * 3600)
            await MainActor.run { purgeStaleCacheEntries() }
        }
    }

    var body: some Scene {
        // ⚠️  Do NOT add `DocumentGroup(viewing: MinidumpDocument.self)` to
        // this body. SwiftUI's `DocumentGroup` crashes inside
        // `PlatformDocumentController.createDocumentClassIfNeeded` during
        // `applicationWillFinishLaunching` whenever the app is launched
        // from a hand-built `.app` bundle (the distribution path, not the
        // Xcode debug path). Issue #46 confirms this; removing the
        // previous `NSDocumentController` subclass did not resolve it.
        // External file opens (Finder double-click, Dock drag, `open
        // file.dmp`) route through `.onOpenURL` below into the same
        // `InputPipeline.ingest` path that WelcomeView uses for
        // drag/Open-File. Recent Documents is managed manually via
        // `NSDocumentController.shared`; multi-window fan-out for zips
        // goes through `NSWorkspace.shared.open` (which loops back through
        // `.onOpenURL`).
        WindowGroup {
            GeometryReader { geo in
                Group {
                    if let document = openedDocument {
                        ContentView(document: document)
                    } else {
                        WelcomeView(
                            openedDocument: $openedDocument,
                            pendingExternalOutcome: $pendingExternalOutcome
                        )
                    }
                }
                .frame(
                    width: geo.size.width / zoomScale,
                    height: geo.size.height / zoomScale
                )
                .scaleEffect(zoomScale, anchor: .topLeading)
            }
            .helpWindowHandler()
            .onOpenURL { url in
                // Guard against non-file URLs (custom scheme handlers) and
                // non-regular files (FIFOs, devices, directories). The
                // previous DocumentGroup path went through NSDocument which
                // enforces this; the .onOpenURL path does not.
                guard url.isFileURL,
                      (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
                else { return }
                Task {
                    let outcome = await InputPipeline.ingest(url: url)
                    await MainActor.run {
                        switch externalOpenAction(for: outcome) {
                        case .showDocument(let parsed, let size):
                            // Confirm before replacing an in-progress
                            // analysis — DocumentGroup used to open each
                            // file in its own window for free; without
                            // that, silently clobbering the current view
                            // is a data-loss surprise for the user.
                            if openedDocument != nil,
                               !confirmReplaceCurrentDocument(newFile: url.lastPathComponent) {
                                return
                            }
                            openedDocument = MinidumpDocument(parsedDump: parsed, fileSize: size)
                        case .deferToWelcomeView(let outcome):
                            openedDocument = nil
                            pendingExternalOutcome = PendingOutcome(outcome: outcome)
                        }
                    }
                }
            }
        }
        .defaultSize(width: 1200, height: 800)
        .commands {
            CommandGroup(after: .toolbar) {
                Button("Go to Address...") {
                    NotificationCenter.default.post(name: .goToAddress, object: nil)
                }
                .keyboardShortcut("g", modifiers: .command)

                Divider()

                Button("Zoom In") {
                    zoomScale = min(round((zoomScale + 0.1) * 10) / 10, 2.0)
                }
                .keyboardShortcut("=", modifiers: .command)
                .disabled(zoomScale >= 2.0)

                Button("Zoom Out") {
                    zoomScale = max(round((zoomScale - 0.1) * 10) / 10, 0.5)
                }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(zoomScale <= 0.5)

                Button("Actual Size") {
                    zoomScale = 1.0
                }
                .keyboardShortcut("0", modifiers: .command)
            }
            CommandGroup(replacing: .importExport) {
                Button("Export as HTML Report...") {
                    NotificationCenter.default.post(name: .exportHTML, object: nil)
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])

                Button("Export as CSV...") {
                    NotificationCenter.default.post(name: .exportCSV, object: nil)
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .help) {
                Button("MiniDumpTruck Help") {
                    NotificationCenter.default.post(name: .openHelp, object: nil)
                }
                .keyboardShortcut("?", modifiers: .command)

                Divider()

                Link("Visit GitHub Repository",
                     destination: URL(string: "https://github.com/jloutsch/minidumptruck")!)
            }
        }

        Window("MiniDumpTruck Help", id: "help") {
            HelpView()
        }
        .defaultSize(width: 600, height: 700)
    }
}

struct WelcomeView: View {
    @Binding var openedDocument: MinidumpDocument?
    @Binding var pendingExternalOutcome: PendingOutcome?
    @State private var isDragging = false
    @State private var isLoading = false
    @State private var loadingFileName: String = ""
    @State private var loadingFileSize: Int = 0
    @State private var pickerArchive: ZipArchive?
    @State private var pickerEntries: [ZipEntry] = []
    @State private var pickerZipName: String = ""
    @State private var isPickerPresented: Bool = false

    var body: some View {
        ZStack {
            VStack(spacing: 24) {
                Spacer()

                // Custom dump truck icon — decorative, hidden from VoiceOver
                DumpTruckIcon()
                    .frame(width: 120, height: 100)
                    .accessibilityHidden(true)

                Text("MiniDumpTruck")
                    .font(.largeTitle)
                    .fontWeight(.bold)

                Text("Windows Crash Dump Analyzer for macOS")
                    .font(.title3)
                    .foregroundStyle(.secondary)

                Spacer()

                // Drop zone
                VStack(spacing: 16) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 16)
                            .strokeBorder(
                                isDragging ? Color.blue : Color.secondary.opacity(0.3),
                                style: StrokeStyle(lineWidth: 2, dash: [8])
                            )
                            .background(
                                RoundedRectangle(cornerRadius: 16)
                                    .fill(isDragging ? Color.blue.opacity(0.1) : Color.clear)
                            )
                            .frame(width: 400, height: 150)

                        VStack(spacing: 12) {
                            Image(systemName: "arrow.down.doc")
                                .font(.system(size: 40))
                                .foregroundStyle(isDragging ? .blue : .secondary)

                            Text("Drop a .dmp or .zip file here")
                                .font(.headline)
                                .foregroundStyle(isDragging ? .blue : .secondary)

                            Text("or")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            Button("Open File...") {
                                openFile()
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(isLoading)
                        }
                    }
                    .onDrop(of: [.fileURL], isTargeted: $isDragging) { providers in
                        handleDrop(providers: providers)
                    }
                }

                Spacer()

                // Footer
                HStack(spacing: 20) {
                    Label("Threads", systemImage: "text.line.first.and.arrowtriangle.forward")
                    Label("Modules", systemImage: "shippingbox")
                    Label("Memory", systemImage: "memorychip")
                    Label("Analysis", systemImage: "wand.and.stars")
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                Spacer()
            }
            .disabled(isLoading)

            // Loading overlay
            if isLoading {
                ZStack {
                    Color(nsColor: .windowBackgroundColor)
                        .opacity(0.9)

                    VStack(spacing: 16) {
                        ProgressView()
                            .scaleEffect(1.5)

                        Text("Opening \(loadingFileName)...")
                            .font(.headline)

                        Text(ByteCountFormatter.string(fromByteCount: Int64(loadingFileSize), countStyle: .file))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        Text("Parsing minidump streams...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(40)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
                .transition(.opacity)
            }
        }
        .onChange(of: pendingExternalOutcome) { _, new in
            // Externally-opened file (Finder, Dock, `open`) that needs UI —
            // zip picker, alert, or multi-file fan-out. Consume the pending
            // outcome and route through the same WelcomeRouter handler as
            // drop / Open File panel so behavior stays consistent.
            guard let new else { return }
            pendingExternalOutcome = nil
            handle(outcome: new.outcome)
        }
        .sheet(isPresented: $isPickerPresented) {
            if let archive = pickerArchive {
                ZipPickerView(
                    zipName: pickerZipName,
                    entries: pickerEntries,
                    onConfirm: { picks in
                        // Capture before clearing state — extraction continues on a detached task.
                        let zipName = pickerZipName
                        isPickerPresented = false
                        pickerArchive = nil
                        pickerEntries = []
                        pickerZipName = ""
                        extractAndOpen(picks: picks, from: archive, zipName: zipName)
                    },
                    onCancel: {
                        isPickerPresented = false
                        pickerArchive = nil
                        pickerEntries = []
                        pickerZipName = ""
                    }
                )
            }
        }
        .frame(minWidth: 500, minHeight: 400)
        .background(Color(nsColor: .windowBackgroundColor))
        .animation(.easeInOut(duration: 0.2), value: isLoading)
    }

    private func openFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Select a Windows minidump file (.dmp) or a zip containing one"

        if panel.runModal() == .OK, let url = panel.url {
            ingest(url: url)
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard !providers.isEmpty else { return false }

        for provider in providers {
            provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, error in
                if let error = error {
                    DispatchQueue.main.async {
                        let alert = NSAlert()
                        alert.messageText = "Could Not Read Dropped File"
                        alert.informativeText = error.localizedDescription
                        alert.alertStyle = .warning
                        alert.runModal()
                    }
                    return
                }
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else {
                    return
                }
                DispatchQueue.main.async {
                    ingest(url: url)
                }
            }
        }

        return true
    }

    private func extractAndOpen(picks: [ZipEntry], from archive: ZipArchive, zipName: String) {
        guard !isLoading else { return }
        loadingFileName = zipName
        isLoading = true
        Task.detached(priority: .userInitiated) {
            let outcome = await InputPipeline.extractSelected(picks, from: archive, sourceName: zipName)
            await MainActor.run {
                handle(outcome: outcome)
            }
        }
    }

    private func ingest(url: URL) {
        guard !isLoading else { return }
        loadingFileName = url.lastPathComponent
        loadingFileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        isLoading = true

        Task.detached(priority: .userInitiated) {
            let outcome = await InputPipeline.ingest(url: url)
            await MainActor.run {
                handle(outcome: outcome)
            }
        }
    }

    @MainActor
    private func handle(outcome: InputPipeline.Outcome) {
        isLoading = false
        switch WelcomeRouter.route(outcome) {
        case .openDocument(let parsed, let size):
            openedDocument = MinidumpDocument(parsedDump: parsed, fileSize: size)
        case .openWindows(let urls):
            var failed: [URL] = []
            for url in urls {
                if !NSWorkspace.shared.open(url) {
                    failed.append(url)
                }
            }
            if !failed.isEmpty {
                let alert = NSAlert()
                alert.messageText = "Could Not Open All Dumps"
                let names = failed.map(\.lastPathComponent).joined(separator: ", ")
                alert.informativeText = "Failed to open: \(names)"
                alert.alertStyle = .warning
                alert.runModal()
            }
        case .showPicker(let archive, let entries, let zipName):
            pickerArchive = archive
            pickerEntries = entries
            pickerZipName = zipName
            isPickerPresented = true
        case .showAlert(let title, let message):
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = message
            alert.alertStyle = .warning
            alert.runModal()
        }
    }
}

extension Notification.Name {
    static let goToAddress = Notification.Name("goToAddress")
    static let exportHTML = Notification.Name("exportHTML")
    static let exportCSV = Notification.Name("exportCSV")
    static let openHelp = Notification.Name("openHelp")
}

/// One-shot carrier for an external-open outcome that needs UI (picker /
/// alert / multi-window fan-out).
///
/// `Equatable` compares only `id` (a per-instance `UUID`) — distinct
/// instances are NEVER equal, even when they wrap structurally identical
/// outcomes. This is load-bearing: SwiftUI's `.onChange(of: optional)`
/// requires the wrapped type to be `Equatable`, and id-only equality
/// guarantees `.onChange` fires every time we assign a new outcome (so a
/// user double-clicking the same broken file twice gets the alert twice).
/// **Do not** swap this conformance for structural equality without
/// rethinking the `.onChange` contract in WelcomeView.
struct PendingOutcome: Identifiable, Equatable {
    let id = UUID()
    let outcome: InputPipeline.Outcome

    static func == (lhs: PendingOutcome, rhs: PendingOutcome) -> Bool { lhs.id == rhs.id }
}

private struct HelpWindowHandler: ViewModifier {
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .openHelp)) { _ in
                openWindow(id: "help")
            }
    }
}

extension View {
    func helpWindowHandler() -> some View {
        modifier(HelpWindowHandler())
    }
}

struct HelpView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Header
                HStack(spacing: 12) {
                    Image(systemName: "truck.box.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(.blue)
                    VStack(alignment: .leading) {
                        Text("MiniDumpTruck")
                            .font(.title)
                            .fontWeight(.bold)
                        Text("Windows Crash Dump Analyzer for macOS")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

                helpSection("Overview") {
                    Text("MiniDumpTruck lets you open and analyze Windows minidump (.dmp) files on macOS. It parses the binary dump format and presents crash data in an interactive interface \u{2014} no Windows or WinDbg required.")
                }

                helpSection("Supported File Types") {
                    Label(".dmp", systemImage: "doc")
                    Label(".mdmp", systemImage: "doc")
                    Label(".minidump", systemImage: "doc")
                    Label(".zip (containing a .dmp)", systemImage: "doc.zipper")
                }

                helpSection("Sidebar Navigation") {
                    navigationItem("Summary", icon: "doc.text", description: "Crash overview with exception and system context")
                    navigationItem("Threads", icon: "text.line.first.and.arrowtriangle.forward", description: "Thread list with faulting thread highlighted")
                    navigationItem("Modules", icon: "shippingbox", description: "Loaded DLLs with addresses, versions, and search")
                    navigationItem("Memory", icon: "memorychip", description: "Memory regions with address lookup")
                    navigationItem("Exception", icon: "exclamationmark.triangle", description: "Exception details and crash context")
                    navigationItem("System Info", icon: "cpu", description: "OS version, architecture, and processor details")
                    navigationItem("Handles", icon: "door.left.hand.open", description: "Open kernel object handles")
                    navigationItem("Crash Analysis", icon: "wand.and.stars", description: "Automated diagnosis with blame attribution")
                    navigationItem("Hex Viewer", icon: "number", description: "Raw memory inspection with search")
                    navigationItem("Stream Directory", icon: "list.bullet.rectangle", description: "Low-level stream index")
                }

                helpSection("Keyboard Shortcuts") {
                    shortcutRow("Go to Address", shortcut: "\u{2318}G")
                    shortcutRow("Export HTML Report", shortcut: "\u{21E7}\u{2318}E")
                    shortcutRow("Export CSV", shortcut: "\u{21E7}\u{2318}S")
                    shortcutRow("MiniDumpTruck Help", shortcut: "\u{2318}?")
                }

                helpSection("Command-Line Tool") {
                    Text("MiniDumpTruck includes a CLI for scripting and automation.")
                        .font(.callout)

                    cliCommandRow("analyze <path>", description: "Analyze a dump file or directory of dumps")
                    cliCommandRow("export <path>", description: "Export as text, HTML, CSV, or JSON (-f format)")
                    cliCommandRow("info <path>", description: "Quick triage summary of a dump file")

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Key flags:")
                            .font(.callout)
                            .fontWeight(.medium)
                        cliOptionRow("-v, --verbose", description: "Include registers and memory regions")
                        cliOptionRow("-f, --format", description: "Output format: text, html, csv, json")
                        cliOptionRow("-s, --summary", description: "Batch summary only (directory mode)")
                        cliOptionRow("-j, --jobs N", description: "Concurrent analyses (default: 4)")
                        cliOptionRow("--manual", description: "Display the full CLI manual")
                    }

                    Text("Run **minidumptruck-cli --manual** for the complete reference.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                helpSection("Tips") {
                    tipRow("Drag and drop a .dmp file onto the welcome screen to open it quickly.")
                    tipRow("Use Crash Analysis for automated diagnosis \u{2014} it walks the stack and attributes blame to a specific module.")
                    tipRow("The Hex Viewer lets you inspect raw memory bytes at any address captured in the dump.")
                    tipRow("Export reports as HTML for sharing or CSV for spreadsheet analysis.")
                }
            }
            .padding(24)
        }
    }

    private func helpSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            content()
        }
    }

    private func navigationItem(_ name: String, icon: String, description: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .frame(width: 20)
                .foregroundStyle(.blue)
            Text(name)
                .fontWeight(.medium)
            Text("\u{2014} \(description)")
                .foregroundStyle(.secondary)
        }
        .font(.callout)
    }

    private func shortcutRow(_ action: String, shortcut: String) -> some View {
        HStack {
            Text(action)
            Spacer()
            Text(shortcut)
                .font(.system(.callout, design: .monospaced))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
        }
        .font(.callout)
    }

    private func cliCommandRow(_ command: String, description: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal")
                .frame(width: 20)
                .foregroundStyle(.green)
            Text(command)
                .font(.system(.callout, design: .monospaced))
                .fontWeight(.medium)
            Text("\u{2014} \(description)")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func cliOptionRow(_ flag: String, description: String) -> some View {
        HStack(spacing: 0) {
            Text(flag)
                .font(.system(.caption, design: .monospaced))
                .frame(width: 130, alignment: .leading)
            Text(description)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.leading, 28)
    }

    private func tipRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "lightbulb")
                .foregroundStyle(.yellow)
                .frame(width: 20)
            Text(text)
                .font(.callout)
        }
    }
}

/// Custom dump truck icon drawn with SwiftUI
struct DumpTruckIcon: View {
    var body: some View {
        Canvas { context, size in
            let width = size.width
            let height = size.height

            // Colors
            let truckBlue = Color.blue
            let darkBlue = Color.blue.opacity(0.8)
            let wheelGray = Color.gray.opacity(0.7)
            let dumpYellow = Color.orange

            // Scale factors
            let scale = min(width / 120, height / 100)
            let yOffset: CGFloat = 18 * scale  // Shift everything down so dump bed isn't cut off

            // Draw dump bed (rectangle rotated around back pivot point)
            // Raised at front, pivots from back-bottom corner
            let bedWidth: CGFloat = 70 * scale
            let bedHeight: CGFloat = 26 * scale
            let pivotX: CGFloat = 108 * scale
            let pivotY: CGFloat = 48 * scale + yOffset
            let angle: CGFloat = 32 * .pi / 180  // +32 degrees clockwise (raises front up)

            // Create rectangle and rotate around pivot point
            var dumpBed = Path()
            dumpBed.addRect(CGRect(x: 0, y: 0, width: bedWidth, height: bedHeight))

            var transform = CGAffineTransform.identity
            transform = transform.translatedBy(x: pivotX, y: pivotY)
            transform = transform.rotated(by: angle)
            transform = transform.translatedBy(x: -bedWidth, y: -bedHeight)

            dumpBed = dumpBed.applying(transform)
            context.fill(dumpBed, with: .color(dumpYellow))
            context.stroke(dumpBed, with: .color(dumpYellow.opacity(0.7)), lineWidth: 2 * scale)

            // Calculate front-bottom corner position for hydraulic arm
            let frontBottomLocal = CGPoint(x: 0, y: bedHeight)
            let cosA = cos(angle)
            let sinA = sin(angle)
            let frontBottomX = pivotX + (frontBottomLocal.x - bedWidth) * cosA - (frontBottomLocal.y - bedHeight) * sinA
            let frontBottomY = pivotY + (frontBottomLocal.x - bedWidth) * sinA + (frontBottomLocal.y - bedHeight) * cosA

            // Draw dump bed ridges (parallel lines inside the rotated rectangle)
            for i in 0..<5 {
                var ridge = Path()
                let ridgeY = CGFloat(4 + i * 5) * scale
                ridge.move(to: CGPoint(x: 4 * scale, y: ridgeY))
                ridge.addLine(to: CGPoint(x: bedWidth - 4 * scale, y: ridgeY))
                ridge = ridge.applying(transform)
                context.stroke(ridge, with: .color(dumpYellow.opacity(0.5)), lineWidth: 1.5 * scale)
            }

            // Draw cab (front of truck)
            var cab = Path()
            cab.addRoundedRect(
                in: CGRect(x: 5 * scale, y: 25 * scale + yOffset, width: 35 * scale, height: 30 * scale),
                cornerSize: CGSize(width: 5 * scale, height: 5 * scale)
            )
            context.fill(cab, with: .color(truckBlue))

            // Draw cab window
            var window = Path()
            window.addRoundedRect(
                in: CGRect(x: 10 * scale, y: 30 * scale + yOffset, width: 18 * scale, height: 12 * scale),
                cornerSize: CGSize(width: 3 * scale, height: 3 * scale)
            )
            context.fill(window, with: .color(.white.opacity(0.8)))

            // Draw chassis/frame
            var chassis = Path()
            chassis.addRect(CGRect(x: 5 * scale, y: 50 * scale + yOffset, width: 100 * scale, height: 8 * scale))
            context.fill(chassis, with: .color(darkBlue))

            // Draw wheels
            let wheelRadius: CGFloat = 12 * scale
            let wheelY: CGFloat = 58 * scale + yOffset

            // Front wheel
            var frontWheel = Path()
            frontWheel.addEllipse(in: CGRect(
                x: 15 * scale - wheelRadius,
                y: wheelY - wheelRadius,
                width: wheelRadius * 2,
                height: wheelRadius * 2
            ))
            context.fill(frontWheel, with: .color(wheelGray))

            // Front wheel hub
            var frontHub = Path()
            frontHub.addEllipse(in: CGRect(
                x: 15 * scale - wheelRadius * 0.4,
                y: wheelY - wheelRadius * 0.4,
                width: wheelRadius * 0.8,
                height: wheelRadius * 0.8
            ))
            context.fill(frontHub, with: .color(.gray))

            // Rear wheel 1
            var rearWheel1 = Path()
            rearWheel1.addEllipse(in: CGRect(
                x: 70 * scale - wheelRadius,
                y: wheelY - wheelRadius,
                width: wheelRadius * 2,
                height: wheelRadius * 2
            ))
            context.fill(rearWheel1, with: .color(wheelGray))

            // Rear wheel 1 hub
            var rearHub1 = Path()
            rearHub1.addEllipse(in: CGRect(
                x: 70 * scale - wheelRadius * 0.4,
                y: wheelY - wheelRadius * 0.4,
                width: wheelRadius * 0.8,
                height: wheelRadius * 0.8
            ))
            context.fill(rearHub1, with: .color(.gray))

            // Rear wheel 2
            var rearWheel2 = Path()
            rearWheel2.addEllipse(in: CGRect(
                x: 95 * scale - wheelRadius,
                y: wheelY - wheelRadius,
                width: wheelRadius * 2,
                height: wheelRadius * 2
            ))
            context.fill(rearWheel2, with: .color(wheelGray))

            // Rear wheel 2 hub
            var rearHub2 = Path()
            rearHub2.addEllipse(in: CGRect(
                x: 95 * scale - wheelRadius * 0.4,
                y: wheelY - wheelRadius * 0.4,
                width: wheelRadius * 0.8,
                height: wheelRadius * 0.8
            ))
            context.fill(rearHub2, with: .color(.gray))

            // Draw hydraulic arm (connects chassis to front-bottom of tilted bed)
            var hydraulic = Path()
            hydraulic.move(to: CGPoint(x: 45 * scale, y: 50 * scale + yOffset))
            hydraulic.addLine(to: CGPoint(x: frontBottomX, y: frontBottomY))
            context.stroke(hydraulic, with: .color(darkBlue), lineWidth: 4 * scale)

            // Draw exhaust pipe
            var exhaust = Path()
            exhaust.addRoundedRect(
                in: CGRect(x: 32 * scale, y: 15 * scale + yOffset, width: 4 * scale, height: 15 * scale),
                cornerSize: CGSize(width: 1 * scale, height: 1 * scale)
            )
            context.fill(exhaust, with: .color(.gray))
        }
    }
}
