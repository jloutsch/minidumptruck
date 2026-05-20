import Foundation

/// Pure-function helper for filtering `ZipEntry` lists by a set of selected IDs.
/// Extracted from `ZipPickerView` so the selection logic is testable without
/// SwiftUI rendering machinery.
public enum ZipEntrySelection {
    /// Returns entries whose `id` is in `ids`, preserving the source order.
    public static func selected(from entries: [ZipEntry], ids: Set<UUID>) -> [ZipEntry] {
        entries.filter { ids.contains($0.id) }
    }
}
