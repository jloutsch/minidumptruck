import SwiftUI
import MiniDumpTruckCore

/// Modal sheet shown when a zip contains more than one minidump.
/// Lets the user multi-select which entries to open; each selection
/// becomes its own window via the standard DocumentGroup open path.
struct ZipPickerView: View {
    let zipName: String
    let entries: [ZipEntry]
    let onConfirm: ([ZipEntry]) -> Void
    let onCancel: () -> Void

    @State private var selected: Set<UUID> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(zipName) contains \(entries.count) minidump files.")
                .font(.headline)
            Text("Select one or more to open. Each opens in its own window.")
                .font(.caption)
                .foregroundStyle(.secondary)

            List(entries) { entry in
                HStack {
                    Toggle(isOn: Binding(
                        get: { selected.contains(entry.id) },
                        set: { isOn in
                            if isOn { selected.insert(entry.id) }
                            else { selected.remove(entry.id) }
                        }
                    )) {
                        VStack(alignment: .leading) {
                            Text(entry.name)
                                .font(.system(.body, design: .monospaced))
                            Text(ByteCountFormatter.string(
                                fromByteCount: Int64(entry.uncompressedSize),
                                countStyle: .file))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(minHeight: 180, maxHeight: 360)

            HStack {
                Button("Cancel", role: .cancel) { onCancel() }
                Spacer()
                Button(selected.isEmpty ? "Open Selected" : "Open \(selected.count) Selected") {
                    let picks = entries.filter { selected.contains($0.id) }
                    onConfirm(picks)
                }
                .buttonStyle(.borderedProminent)
                .disabled(selected.isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
