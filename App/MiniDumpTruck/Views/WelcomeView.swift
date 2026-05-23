import SwiftUI
import AppKit
import MiniDumpTruckCore

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
