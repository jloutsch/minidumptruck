import SwiftUI

struct StreamListView: View {
    let directory: StreamDirectory

    var body: some View {
        List {
            ForEach(directory.entries) { entry in
                StreamRowView(entry: entry)
            }
        }
        .listStyle(.inset)
        .navigationTitle("Streams (\(directory.entries.count))")
    }
}

struct StreamRowView: View {
    let entry: StreamDirectoryEntry

    var body: some View {
        HStack {
            Image(systemName: entry.systemImage)
                .foregroundStyle(iconColor)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                Text(entry.displayName)
                    .fontWeight(.medium)

                HStack(spacing: 12) {
                    Text("Type: \(entry.streamType)")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("Size: \(ByteCountFormatter.string(fromByteCount: Int64(entry.dataSize), countStyle: .memory))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Text(String(format: "RVA: 0x%08X", entry.rva))
                .font(.caption)
                .fontDesign(.monospaced)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private var iconColor: Color {
        guard let type = entry.type else { return .secondary }
        switch type {
        case .exception:
            return .red
        case .threadList, .threadExList, .threadInfoList:
            return .blue
        case .moduleList, .unloadedModuleList:
            return .purple
        case .memoryList, .memory64List, .memoryInfoList:
            return .green
        case .systemInfo:
            return .orange
        default:
            return .secondary
        }
    }
}
