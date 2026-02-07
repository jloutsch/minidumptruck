import SwiftUI
import MiniDumpTruckCore

struct MemoryListView: View {
    let document: MinidumpDocument
    @Bindable var viewModel: DumpViewModel
    @State private var sortOrder = [KeyPathComparator(\MemoryRegion.baseAddress)]
    @State private var addressError: String?

    var body: some View {
        VStack(spacing: 0) {
            // Address search bar
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Go to address (e.g., 0x7FF...)", text: $viewModel.memoryAddressText)
                    .textFieldStyle(.plain)
                    .onSubmit {
                        addressError = nil
                        guard let address = viewModel.parseAddress(viewModel.memoryAddressText) else {
                            addressError = "Invalid hex address"
                            return
                        }
                        if let region = document.memoryRegions.first(where: { $0.contains(address: address) }) {
                            viewModel.detailSelection = .memoryRegion(region.id)
                        } else {
                            addressError = "Address not in any memory region"
                        }
                    }

                if !viewModel.memoryAddressText.isEmpty {
                    Button {
                        viewModel.memoryAddressText = ""
                        addressError = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }

                if let error = addressError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding(8)
            .background(.bar)

            Divider()

            // Memory regions table
            Table(of: MemoryRegion.self, selection: Binding(
                get: {
                    if case .memoryRegion(let id) = viewModel.detailSelection {
                        return id
                    }
                    return nil
                },
                set: { newValue in
                    if let id = newValue {
                        viewModel.detailSelection = .memoryRegion(id)
                    }
                }
            ), sortOrder: $sortOrder) {
                TableColumn("Base Address", value: \.baseAddress) { region in
                    Text(String(format: "0x%016llX", region.baseAddress))
                        .fontDesign(.monospaced)
                        .font(.caption)
                }
                .width(min: 140, ideal: 160)

                TableColumn("End Address") { region in
                    Text(String(format: "0x%016llX", region.endAddress))
                        .fontDesign(.monospaced)
                        .font(.caption)
                }
                .width(min: 140, ideal: 160)

                TableColumn("Size", value: \.regionSize) { region in
                    Text(ByteCountFormatter.string(fromByteCount: Int64(clamping: region.regionSize), countStyle: .memory))
                        .font(.caption)
                }
                .width(min: 80, ideal: 100)

                TableColumn("Module") { region in
                    if let module = document.module(containing: region.baseAddress) {
                        Text(module.shortName)
                            .font(.caption)
                    } else {
                        Text("-")
                            .foregroundStyle(.secondary)
                    }
                }
                .width(min: 100, ideal: 150)
            } rows: {
                ForEach(document.memoryRegions.sorted(using: sortOrder)) { region in
                    TableRow(region)
                }
            }
        }
        .navigationTitle("Memory Regions (\(document.memoryRegions.count))")
    }
}
