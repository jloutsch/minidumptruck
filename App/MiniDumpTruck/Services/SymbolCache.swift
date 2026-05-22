import Foundation

/// On-disk cache for PDBs downloaded from a Microsoft symbol server.
///
/// Layout (matches the symbol-server URL scheme for easy debugging):
///
///     ~/Library/Caches/MiniDumpTruck/SymbolCache/
///       <pdb-name>/<GUID><AGE>/<pdb-name>
///
/// e.g. `ntdll.pdb/8D4...3F1/ntdll.pdb`. The middle directory is the
/// 32-char uppercase GUID concatenated with the age (1-N hex digits),
/// exactly as MSDL serves them. This makes a cached file findable with
/// `find` and inspectable in Finder.
///
/// The cache is purely additive — entries never expire automatically.
/// A misbehaving PDB never goes stale because MSDL serves immutable
/// artifacts (a given GUID+age pair pins a specific build), so cached
/// data is safe to keep indefinitely.
public actor SymbolCache {
    private let root: URL
    private let fileManager: FileManager

    public init(root: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        if let root {
            self.root = root
        } else {
            let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            self.root = caches
                .appendingPathComponent("MiniDumpTruck", isDirectory: true)
                .appendingPathComponent("SymbolCache", isDirectory: true)
        }
    }

    /// Disk path where a PDB for the given identity would live. The
    /// file may or may not exist; use `data(for:)` to actually read.
    public nonisolated func url(for key: PDBIdentity) -> URL {
        root
            .appendingPathComponent(key.pdbName, isDirectory: true)
            .appendingPathComponent(key.cacheKey, isDirectory: true)
            .appendingPathComponent(key.pdbName, isDirectory: false)
    }

    public func exists(_ key: PDBIdentity) -> Bool {
        fileManager.fileExists(atPath: url(for: key).path)
    }

    /// Read the cached PDB bytes, if present. Returns nil on cache miss
    /// or read failure (permissions, race with eviction, etc.).
    public func data(for key: PDBIdentity) -> Data? {
        try? Data(contentsOf: url(for: key))
    }

    /// Store PDB bytes under the cache key. Writes atomically via a
    /// temp file + rename so a partial write can't leave a corrupted
    /// entry that future reads would consume. Returns the final URL
    /// on success.
    @discardableResult
    public func store(_ data: Data, for key: PDBIdentity) throws -> URL {
        let final = url(for: key)
        let dir = final.deletingLastPathComponent()
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        // Atomic option writes to a temp file and renames into place.
        try data.write(to: final, options: .atomic)
        return final
    }

    /// Delete all cached PDBs. Used by a "Clear Symbol Cache" settings
    /// action. Best-effort — never throws.
    public func clear() {
        try? fileManager.removeItem(at: root)
    }

    /// Approximate total bytes consumed by the cache on disk. Walks the
    /// cache root and sums file sizes. Useful for a settings display.
    public func sizeOnDisk() -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            total += Int64(size)
        }
        return total
    }
}

/// Identity of a specific PDB build, used as a cache key and to form
/// symbol-server URLs.
public struct PDBIdentity: Hashable, Sendable {
    public let pdbName: String     // e.g. "ntdll.pdb"
    public let guid: String        // 32 uppercase hex chars, no dashes
    public let age: UInt32         // small integer

    public init(pdbName: String, guid: String, age: UInt32) {
        self.pdbName = pdbName
        self.guid = guid.uppercased()
        self.age = age
    }

    /// The `<GUID><AGE>` directory name MSDL uses. Age is rendered as
    /// hex with no padding — that's the symbol-server convention.
    public var cacheKey: String { "\(guid)\(String(age, radix: 16, uppercase: true))" }
}
