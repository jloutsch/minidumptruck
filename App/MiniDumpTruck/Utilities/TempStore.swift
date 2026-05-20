import Foundation

/// Filesystem temp store for ZIP-extracted files, used by `InputPipeline`.
/// Lives under `~/Library/Caches/MiniDumpTruck/zip-<uuid>/`. macOS may
/// reclaim caches under disk pressure; `cleanupAged` provides explicit
/// best-effort housekeeping.
public enum TempStore {
    /// Root: ~/Library/Caches/MiniDumpTruck/
    public static func root() -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("MiniDumpTruck", isDirectory: true)
    }

    /// Create a fresh `zip-<uuid>/` directory under the cache root.
    /// `sourceName` is informational; the directory name itself is a UUID
    /// for uniqueness across concurrent extractions.
    public static func makeDir(sourceName: String) throws -> URL {
        let dir = root().appendingPathComponent("zip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Delete any `zip-*` subdirectory of the cache root whose modification
    /// date is older than `olderThan` seconds. Best-effort: never throws.
    public static func cleanupAged(olderThan: TimeInterval) async {
        let fm = FileManager.default
        let root = root()
        guard let entries = try? fm.contentsOfDirectory(at: root,
                                                        includingPropertiesForKeys: [.contentModificationDateKey],
                                                        options: [.skipsHiddenFiles]) else {
            return
        }
        let cutoff = Date().addingTimeInterval(-olderThan)
        for entry in entries {
            guard entry.lastPathComponent.hasPrefix("zip-") else { continue }
            let values = try? entry.resourceValues(forKeys: [.contentModificationDateKey])
            guard let mtime = values?.contentModificationDate, mtime < cutoff else { continue }
            try? fm.removeItem(at: entry)
        }
    }
}
