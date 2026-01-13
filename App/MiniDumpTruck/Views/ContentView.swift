import SwiftUI
import MiniDumpTruckCore

struct ContentView: View {
    let document: MinidumpDocument
    @State private var viewModel = DumpViewModel()
    @State private var documentWrapper: MinidumpDocumentWrapper?

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
        .onReceive(NotificationCenter.default.publisher(for: .goToAddress)) { _ in
            viewModel.showGoToAddressSheet = true
        }
        .sheet(isPresented: $viewModel.showGoToAddressSheet) {
            GoToAddressSheet(viewModel: viewModel, document: document)
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
