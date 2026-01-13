import SwiftUI

struct ModuleListView: View {
    let document: MinidumpDocument
    @Bindable var viewModel: DumpViewModel
    @State private var sortOrder = [KeyPathComparator(\ModuleInfo.baseAddress)]

    var filteredModules: [ModuleInfo] {
        var modules = document.modules
        if !viewModel.moduleSearchText.isEmpty {
            let search = viewModel.moduleSearchText.lowercased()
            modules = modules.filter { module in
                module.name.lowercased().contains(search) ||
                module.shortName.lowercased().contains(search)
            }
        }
        return modules.sorted(using: sortOrder)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Search bar
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search modules...", text: $viewModel.moduleSearchText)
                    .textFieldStyle(.plain)

                if !viewModel.moduleSearchText.isEmpty {
                    Button {
                        viewModel.moduleSearchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            .background(.bar)

            Divider()

            // Module table
            Table(of: ModuleInfo.self, selection: Binding(
                get: {
                    if case .module(let id) = viewModel.detailSelection {
                        return id
                    }
                    return nil
                },
                set: { newValue in
                    if let id = newValue {
                        viewModel.detailSelection = .module(id)
                    }
                }
            ), sortOrder: $sortOrder) {
                TableColumn("Name", value: \.shortName) { module in
                    Text(module.shortName)
                        .fontWeight(.medium)
                }
                .width(min: 100, ideal: 200)

                TableColumn("Base Address", value: \.baseAddress) { module in
                    Text(String(format: "0x%016llX", module.baseAddress))
                        .fontDesign(.monospaced)
                        .font(.caption)
                }
                .width(min: 140, ideal: 160)

                TableColumn("Size", value: \.sizeOfImage) { module in
                    Text(ByteCountFormatter.string(fromByteCount: Int64(module.sizeOfImage), countStyle: .memory))
                        .font(.caption)
                }
                .width(min: 60, ideal: 80)

                TableColumn("Version") { module in
                    if let version = module.version {
                        Text(version.fileVersion)
                            .font(.caption)
                    } else {
                        Text("-")
                            .foregroundStyle(.secondary)
                    }
                }
                .width(min: 80, ideal: 120)
            } rows: {
                ForEach(filteredModules) { module in
                    TableRow(module)
                }
            }
        }
        .navigationTitle("Modules (\(document.modules.count))")
    }
}

struct ModuleDetailView: View {
    let module: ModuleInfo

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Module Header
                HStack {
                    Image(systemName: "shippingbox")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading) {
                        Text(module.shortName)
                            .font(.title2)
                            .fontWeight(.semibold)

                        Text(module.name)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

                // Address Information
                GroupBox("Memory Layout") {
                    Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
                        GridRow {
                            Text("Base Address:")
                                .fontWeight(.medium)
                            Text(String(format: "0x%016llX", module.baseAddress))
                                .fontDesign(.monospaced)
                        }

                        GridRow {
                            Text("End Address:")
                                .fontWeight(.medium)
                            Text(String(format: "0x%016llX", module.endAddress))
                                .fontDesign(.monospaced)
                        }

                        GridRow {
                            Text("Size:")
                                .fontWeight(.medium)
                            Text("\(ByteCountFormatter.string(fromByteCount: Int64(module.sizeOfImage), countStyle: .memory)) (\(module.sizeOfImage) bytes)")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                // Version Information
                if let version = module.version {
                    GroupBox("Version Information") {
                        Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
                            GridRow {
                                Text("File Version:")
                                    .fontWeight(.medium)
                                Text(version.fileVersion)
                            }

                            GridRow {
                                Text("Product Version:")
                                    .fontWeight(.medium)
                                Text(version.productVersion)
                            }

                            GridRow {
                                Text("File Type:")
                                    .fontWeight(.medium)
                                Text(version.fileTypeDescription)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                // Build Information
                GroupBox("Build Information") {
                    Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
                        GridRow {
                            Text("Timestamp:")
                                .fontWeight(.medium)
                            Text(module.timestamp.formatted())
                        }

                        GridRow {
                            Text("Checksum:")
                                .fontWeight(.medium)
                            Text(String(format: "0x%08X", module.checksum))
                                .fontDesign(.monospaced)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding()
        }
        .navigationTitle(module.shortName)
    }
}
