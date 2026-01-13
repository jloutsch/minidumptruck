import SwiftUI
import MiniDumpTruckCore

struct HandleDataView: View {
    let document: MinidumpDocument
    @Bindable var viewModel: DumpViewModel

    var filteredHandles: [HandleEntry] {
        let handles = document.handles
        if viewModel.handleSearchText.isEmpty {
            return handles
        }
        let searchText = viewModel.handleSearchText.lowercased()
        return handles.filter { handle in
            // Search by type name
            if handle.typeName.lowercased().contains(searchText) {
                return true
            }
            // Search by object name
            if handle.objectName.lowercased().contains(searchText) {
                return true
            }
            // Search by handle value
            if handle.handleHex.lowercased().contains(searchText) {
                return true
            }
            return false
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Summary bar
            if let handleData = document.handleData {
                HStack {
                    Text("\(handleData.entries.count) handles")
                        .font(.headline)

                    Spacer()

                    // Show handle types summary
                    ForEach(handleData.handleTypesSummary.prefix(4), id: \.type) { item in
                        Text("\(item.type): \(item.count)")
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.blue.opacity(0.1))
                            .clipShape(Capsule())
                    }
                }
                .padding(8)
                .background(.bar)

                Divider()
            }

            // Search bar
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search handles by type or name...", text: $viewModel.handleSearchText)
                    .textFieldStyle(.plain)

                if !viewModel.handleSearchText.isEmpty {
                    Button {
                        viewModel.handleSearchText = ""
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

            // Handle list
            List(selection: Binding(
                get: { nil as UUID? },
                set: { _ in }
            )) {
                ForEach(filteredHandles) { handle in
                    HandleRowView(handle: handle)
                }
            }
            .listStyle(.inset)
        }
        .navigationTitle("Handles (\(document.handles.count))")
    }
}

struct HandleRowView: View {
    let handle: HandleEntry

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(handle.handleHex)
                        .fontDesign(.monospaced)
                        .fontWeight(.medium)

                    if !handle.typeName.isEmpty {
                        Text(handle.typeName)
                            .font(.callout)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(colorForType(handle.typeName).opacity(0.2))
                            .foregroundStyle(colorForType(handle.typeName))
                            .clipShape(Capsule())
                    }
                }

                if !handle.objectName.isEmpty {
                    Text(handle.objectName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                HStack(spacing: 12) {
                    Text("Access: \(handle.accessHex)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)

                    if handle.handleCount > 0 {
                        Text("Count: \(handle.handleCount)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }

                    if handle.pointerCount > 0 {
                        Text("Refs: \(handle.pointerCount)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            Spacer()
        }
        .padding(.vertical, 4)
    }

    private func colorForType(_ type: String) -> Color {
        switch type.lowercased() {
        case "file":
            return .blue
        case "key":
            return .purple
        case "event":
            return .green
        case "mutant":
            return .orange
        case "semaphore":
            return .cyan
        case "section":
            return .pink
        case "thread":
            return .red
        case "process":
            return .red
        case "directory":
            return .yellow
        case "token":
            return .indigo
        default:
            return .secondary
        }
    }
}
