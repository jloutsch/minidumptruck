import Foundation
import os

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
        do {
            let data = try Data(contentsOf: url(for: key))
            Logger.symbols.debug("cache hit \(key.pdbName, privacy: .public) (\(data.count) bytes)")
            return data
        } catch {
            // CocoaError.fileReadNoSuchFile is the common case (cache
            // miss) — log at trace level so we don't spam. Other errors
            // (permission denied, IO failure) are notable.
            let nsErr = error as NSError
            if nsErr.domain == NSCocoaErrorDomain && nsErr.code == NSFileReadNoSuchFileError {
                Logger.symbols.trace("cache miss \(key.pdbName, privacy: .public)")
            } else {
                Logger.symbols.error("cache read failed for \(key.pdbName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
            return nil
        }
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
        Logger.symbols.info("cache store \(key.pdbName, privacy: .public) (\(data.count) bytes)")
        return final
    }

    /// Remove a single cache entry. Used by the corruption-recovery
    /// path in `SymbolicationService` when a cached PDB fails to parse:
    /// evict, re-fetch, retry. Best-effort — never throws.
    public func evict(_ key: PDBIdentity) {
        let target = url(for: key)
        try? fileManager.removeItem(at: target)
        // Also clean up the now-empty parent directory so the cache
        // doesn't accumulate empty <GUID><AGE> dirs over time.
        let parent = target.deletingLastPathComponent()
        if let contents = try? fileManager.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil),
           contents.isEmpty {
            try? fileManager.removeItem(at: parent)
        }
        Logger.symbols.info("cache evict \(key.pdbName, privacy: .public)")
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
///
/// The `pdbName` and `guid` flow into both filesystem paths and URLs,
/// so the initializer validates them strictly. An attacker controls
/// the CodeView record in a malicious .dmp; without these guards, a
/// `pdbName` of `"../../../../etc/passwd"` would survive
/// `URL.appendingPathComponent` (which does not normalize `..`) and
/// could clobber arbitrary user-writable files when the cache stores
/// a PDB. A `guid` containing slashes would similarly redirect URL
/// requests. Reject both.
public struct PDBIdentity: Hashable, Sendable {
    public let pdbName: String     // e.g. "ntdll.pdb"
    public let guid: String        // 32 uppercase hex chars, no dashes
    public let age: UInt32         // small integer

    /// Failable initializer that rejects pdbName / guid values that
    /// would be unsafe in a filesystem path or URL. Returns nil on:
    ///   - empty pdbName or guid
    ///   - pdbName containing path separators, `..`, `.`, control
    ///     characters, NUL, or anything outside [A-Za-z0-9._-]
    ///   - pdbName too long (>128 chars) or missing
    ///   - guid not exactly 32 hex characters
    public init?(pdbName: String, guid: String, age: UInt32) {
        guard Self.isValidPDBName(pdbName),
              Self.isValidGUID(guid) else { return nil }
        self.pdbName = pdbName
        self.guid = guid.uppercased()
        self.age = age
    }

    /// Allowed: [A-Za-z0-9._-]{1,128}. No path separators, no `..`
    /// (rejected via the `.` filter), no control chars, no NULs.
    private static func isValidPDBName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 128 else { return false }
        // Reject anything containing characters outside the safe set.
        let allowed: Set<Character> = Set(
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"
        )
        guard name.allSatisfy({ allowed.contains($0) }) else { return false }
        // `..` and `.` as full names would be path-traversal primitives
        // even though `.` is in the allowed set above. Reject explicitly.
        guard name != "." && name != ".." else { return false }
        return true
    }

    /// Allowed: exactly 32 hex characters (case-insensitive).
    private static func isValidGUID(_ guid: String) -> Bool {
        guard guid.count == 32 else { return false }
        let hex: Set<Character> = Set("0123456789abcdefABCDEF")
        return guid.allSatisfy { hex.contains($0) }
    }

    /// The `<GUID><AGE>` directory name MSDL uses. Age is rendered as
    /// hex with no padding — that's the symbol-server convention.
    public var cacheKey: String { "\(guid)\(String(age, radix: 16, uppercase: true))" }
}
