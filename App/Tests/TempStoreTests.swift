import Foundation
import Testing
@testable import MiniDumpTruckCore

@Suite("TempStore", .serialized)
struct TempStoreTests {
    @Test func makeDirCreatesUniquePath() throws {
        let a = try TempStore.makeDir(sourceName: "crashes.zip")
        let b = try TempStore.makeDir(sourceName: "crashes.zip")
        defer {
            try? FileManager.default.removeItem(at: a)
            try? FileManager.default.removeItem(at: b)
        }
        #expect(a != b)
        #expect(FileManager.default.fileExists(atPath: a.path))
        #expect(FileManager.default.fileExists(atPath: b.path))
        // Path is under cache root with the zip-<uuid> pattern.
        #expect(a.lastPathComponent.hasPrefix("zip-"))
    }

    @Test func cleanupAgedRemovesOldDirsKeepsFreshOnes() async throws {
        let fresh = try TempStore.makeDir(sourceName: "fresh.zip")
        let stale = try TempStore.makeDir(sourceName: "stale.zip")
        defer {
            try? FileManager.default.removeItem(at: fresh)
            try? FileManager.default.removeItem(at: stale)
        }
        // Backdate the stale dir's creationDate by 1 week. `.creationDate`
        // is settable via setAttributes on Apple platforms.
        let oneWeekAgo = Date().addingTimeInterval(-7 * 24 * 3600)
        try FileManager.default.setAttributes([.creationDate: oneWeekAgo],
                                              ofItemAtPath: stale.path)

        await TempStore.cleanupAged(olderThan: 24 * 3600)

        #expect(FileManager.default.fileExists(atPath: fresh.path))
        #expect(!FileManager.default.fileExists(atPath: stale.path))
    }

    @Test func isInsideCacheMatchesActualTempdir() throws {
        let dir = try TempStore.makeDir(sourceName: "filter.zip")
        defer { try? FileManager.default.removeItem(at: dir) }
        let inside = dir.appendingPathComponent("payload.dmp")

        #expect(TempStore.isInsideCache(dir))
        #expect(TempStore.isInsideCache(inside))
    }

    @Test func isInsideCacheRejectsRegularDocuments() {
        let outside = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Documents/crashes/dump.dmp")
        #expect(!TempStore.isInsideCache(outside))
    }

    @Test func isInsideCacheRejectsSiblingWithSharedPrefix() throws {
        // A directory whose path string shares the cache-root prefix
        // but is NOT a child must not be filtered. Construct a sibling
        // by appending characters to the cache root path string itself.
        let cacheRootPath = TempStore.root().path
        let sibling = URL(fileURLWithPath: cacheRootPath + "-other-app")
            .appendingPathComponent("dump.dmp")
        #expect(!TempStore.isInsideCache(sibling))
    }

    @Test func isInsideCacheResolvesPrivateVarSymlink() {
        // On macOS, /var is a symlink to /private/var, and the system
        // tmp dir often lives under /var/folders/... The cache-root
        // computation may return one form while a user-supplied URL
        // may carry the other. Both must compare equal.
        let cacheRoot = TempStore.root()
        let path = cacheRoot.path
        let inside = cacheRoot.appendingPathComponent("zip-test/dump.dmp")

        let toggled: URL
        if path.hasPrefix("/private/var/") {
            // /private/var/X/.../zip-test → /var/X/.../zip-test
            let stripped = String(path.dropFirst("/private".count))
            toggled = URL(fileURLWithPath: stripped)
                .appendingPathComponent("zip-test/dump.dmp")
        } else if path.hasPrefix("/var/") {
            toggled = URL(fileURLWithPath: "/private" + path)
                .appendingPathComponent("zip-test/dump.dmp")
        } else {
            // Cache root isn't under /var on this host — exercise the
            // standardized-path code path with the unchanged form so
            // the test still asserts something useful instead of
            // silently passing.
            toggled = inside
        }

        #expect(TempStore.isInsideCache(toggled),
                "expected toggled-symlink form '\(toggled.path)' to be inside cache '\(path)'")
    }

    @Test func cleanupAgedUsesInjectableClock() async throws {
        // Verify TempStore.now is overridable — exercise the cutoff via the
        // clock, not via real wall-clock elapsed time.
        let realNow = TempStore.now
        defer { TempStore.now = realNow }

        let dir = try TempStore.makeDir(sourceName: "test.zip")
        defer { try? FileManager.default.removeItem(at: dir) }

        // Freeze the clock 2 days in the future relative to the dir's
        // creation. cleanupAged(24h) computes cutoff = frozen - 24h =
        // creation + 24h, which is AFTER the dir's creationDate → stale.
        let dirCtime = (try? dir.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
        TempStore.now = { dirCtime.addingTimeInterval(2 * 24 * 3600) }

        await TempStore.cleanupAged(olderThan: 24 * 3600)

        #expect(!FileManager.default.fileExists(atPath: dir.path),
                "dir should be deleted: frozen now() places its creationDate past the cutoff")
    }
}
