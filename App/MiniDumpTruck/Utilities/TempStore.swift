import Foundation

/// Filesystem temp store for ZIP-extracted files, used by `InputPipeline`.
/// Lives under `~/Library/Caches/MiniDumpTruck/zip-<uuid>/`. macOS may
/// reclaim caches under disk pressure; `cleanupAged` provides explicit
/// best-effort housekeeping.
public enum TempStore {
    /// Test-injectable clock. Default: real time.
    public static var now: () -> Date = Date.init

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

    /// Whether `url` points inside the cache root (used to suppress
    /// Recent Documents entries for ephemeral extracted files).
    ///
    /// Standardizes both paths so the `/var` ↔ `/private/var` symlink
    /// resolution does not produce a false negative, and matches on
    /// full path components so `~/Library/Caches/MiniDumpTruck-other`
    /// does not falsely match `~/Library/Caches/MiniDumpTruck`.
    public static func isInsideCache(_ url: URL) -> Bool {
        let cacheRoot = root().standardizedFileURL.path
        let target = url.standardizedFileURL.path
        return target == cacheRoot || target.hasPrefix(cacheRoot + "/")
    }

    /// Delete any `zip-*` subdirectory of the cache root whose creation
    /// date is older than `olderThan` seconds. Best-effort: never throws.
    public static func cleanupAged(olderThan: TimeInterval) async {
        let fm = FileManager.default
        let root = root()
        guard let entries = try? fm.contentsOfDirectory(at: root,
                                                        includingPropertiesForKeys: [.creationDateKey],
                                                        options: [.skipsHiddenFiles]) else {
            return
        }
        let cutoff = now().addingTimeInterval(-olderThan)
        for entry in entries {
            guard entry.lastPathComponent.hasPrefix("zip-") else { continue }
            let values = try? entry.resourceValues(forKeys: [.creationDateKey])
            guard let ctime = values?.creationDate, ctime < cutoff else { continue }
            try? fm.removeItem(at: entry)
        }
    }
}
