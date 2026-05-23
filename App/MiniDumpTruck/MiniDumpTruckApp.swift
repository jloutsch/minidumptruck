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

extension Notification.Name {
    static let goToAddress = Notification.Name("goToAddress")
    static let exportHTML = Notification.Name("exportHTML")
    static let exportCSV = Notification.Name("exportCSV")
    static let openHelp = Notification.Name("openHelp")
}
