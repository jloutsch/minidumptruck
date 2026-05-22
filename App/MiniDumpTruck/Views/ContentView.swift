import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MiniDumpTruckCore

struct ContentView: View {
    let document: MinidumpDocument
    @State private var viewModel = DumpViewModel()
    @State private var documentWrapper: MinidumpDocumentWrapper?
    /// Process-wide symbol cache + server. Held in the view so the
    /// actor's storage survives across re-renders of this dump.
    @State private var symbolService = SymbolicationService(
        cache: SymbolCache(),
        server: SymbolServer()
    )

    var body: some View {
        Group {
            if let error = document.parseError {
                ErrorView(error: error)
            } else if document.parsedDump != nil {
                NavigationSplitView {
                    SidebarView(document: document, viewModel: viewModel)
                } content: {
                    DetailContentView(document: document, viewModel: viewModel)
                } detail: {
                    DetailInspectorView(document: document, viewModel: viewModel)
                }
                .navigationSplitViewStyle(.balanced)
                .toolbar {
                    ToolbarItemGroup(placement: .primaryAction) {
                        Menu {
                            Button {
                                exportHTML()
                            } label: {
                                Label("Export as HTML Report", systemImage: "doc.richtext")
                            }
                            Button {
                                exportCSV()
                            } label: {
                                Label("Export as CSV", systemImage: "tablecells")
                            }
                        } label: {
                            Label("Export", systemImage: "square.and.arrow.up")
                        }
                        .help("Export report")
                    }
                }
            } else {
                ContentUnavailableView(
                    "No Dump Loaded",
                    systemImage: "doc",
                    description: Text("Open a .dmp file to begin analysis")
                )
            }
        }
        .onAppear {
            // Set up document reference for address lookups
            documentWrapper = MinidumpDocumentWrapper(document: document)
            viewModel.documentReference = documentWrapper
        }
        .task(id: document.parsedDump?.header.timeDateStamp) {
            // Fire off PDB symbol resolution once per opened dump.
            // `.task(id:)` cancels the in-flight task if the user
            // switches to a different document, so we don't leak
            // a fetch when the view's document changes underneath us.
            guard let dump = document.parsedDump else { return }
            await viewModel.loadSymbols(for: dump, service: symbolService)
        }
        .onReceive(NotificationCenter.default.publisher(for: .goToAddress)) { _ in
            viewModel.showGoToAddressSheet = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .exportHTML)) { _ in
            exportHTML()
        }
        .onReceive(NotificationCenter.default.publisher(for: .exportCSV)) { _ in
            exportCSV()
        }
        .sheet(isPresented: $viewModel.showGoToAddressSheet) {
            GoToAddressSheet(viewModel: viewModel, document: document)
        }
    }

    private func exportHTML() {
        guard let dump = document.parsedDump else { return }

        let analysis = CrashAnalyzer(dump: dump).analyze()
        let html = HTMLExporter.generateReport(from: dump, analysis: analysis)

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.html]
        panel.nameFieldStringValue = "crash-report.html"
        panel.title = "Export HTML Report"

        if panel.runModal() == .OK, let url = panel.url {
            do {
                try html.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                let alert = NSAlert(error: error)
                alert.runModal()
            }
        }
    }

    private func exportCSV() {
        guard let dump = document.parsedDump else { return }

        let csv = CSVExporter.generateCSV(from: dump)

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "crash-data.csv"
        panel.title = "Export CSV Data"

        if panel.runModal() == .OK, let url = panel.url {
            do {
                try csv.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                let alert = NSAlert(error: error)
                alert.runModal()
            }
        }
    }
}

struct ErrorView: View {
    let error: Error

    var body: some View {
        ContentUnavailableView {
            Label("Parse Error", systemImage: "exclamationmark.triangle")
        } description: {
            Text(error.localizedDescription)
        } actions: {
            Text("The file may be corrupted or not a valid Windows minidump.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct GoToAddressSheet: View {
    @Bindable var viewModel: DumpViewModel
    let document: MinidumpDocument
    @Environment(\.dismiss) private var dismiss
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 16) {
            Text("Go to Address")
                .font(.headline)

            TextField("Address (e.g., 0x7FF...)", text: $viewModel.goToAddressText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 300)

            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Go") {
                    goToAddress()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(viewModel.parseAddress(viewModel.goToAddressText) == nil)
            }
        }
        .padding()
        .frame(width: 350)
    }

    private func goToAddress() {
        guard let address = viewModel.parseAddress(viewModel.goToAddressText) else {
            errorMessage = "Invalid address format"
            return
        }

        // Check if address is in any memory region
        if document.memoryRegions.first(where: { $0.contains(address: address) }) != nil {
            viewModel.goToAddressInDocument(address, document: document)
            dismiss()
        } else {
            errorMessage = "Address not found in any memory region"
        }
    }
}
