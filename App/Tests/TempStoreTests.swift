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
        let deeplyNested = dir.appendingPathComponent("a/b/c/d/e.dmp")

        #expect(TempStore.isInsideCache(dir))
        #expect(TempStore.isInsideCache(inside))
        #expect(TempStore.isInsideCache(deeplyNested))
    }

    @Test func isInsideCacheRootItselfMatches() {
        // The == cacheRoot branch — a refactor dropping the equality
        // clause must fail this test.
        #expect(TempStore.isInsideCache(TempStore.root()))
    }

    @Test func isInsideCacheRejectsRegularDocuments() {
        let outside = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Documents/crashes/dump.dmp")
        #expect(!TempStore.isInsideCache(outside))
    }

    @Test func isInsideCacheRejectsSiblingWithSharedPrefix() throws {
        // A directory whose path string shares the cache-root prefix
        // but is NOT a child must not be filtered. Build the sibling
        // from the resolved cache root path so the assertion exercises
        // the component-boundary check rather than any symlink-form
        // mismatch.
        let resolvedRoot = TempStore.root().resolvingSymlinksInPath().path
        let sibling = URL(fileURLWithPath: resolvedRoot + "-other-app")
            .appendingPathComponent("dump.dmp")
        #expect(!TempStore.isInsideCache(sibling))
    }

    @Test func isInsideCacheNormalizesDotsAndParents() throws {
        // `..` segments that resolve back into the cache should be
        // treated as inside; `..` segments that escape should not.
        let dir = try TempStore.makeDir(sourceName: "norm.zip")
        defer { try? FileManager.default.removeItem(at: dir) }

        // dir/inner/../payload.dmp resolves to dir/payload.dmp — inside.
        let resolvingBack = dir.appendingPathComponent("inner/../payload.dmp")
        #expect(TempStore.isInsideCache(resolvingBack))

        // dir/../escaped.dmp resolves to <parent-of-cache>/escaped.dmp — outside.
        let escaping = dir.appendingPathComponent("../../escaped.dmp")
        #expect(!TempStore.isInsideCache(escaping))
    }

    @Test func isInsideCacheIsCaseInsensitive() {
        // Default macOS APFS is case-insensitive-comparing; a URL with
        // mismatched case still points at the same file.
        let cacheRoot = TempStore.root()
        let upper = URL(fileURLWithPath: cacheRoot.path.uppercased())
            .appendingPathComponent("zip-test/dump.dmp")
        #expect(TempStore.isInsideCache(upper))
    }

    @Test func isInsideCacheResolvesSymlinkedPath() throws {
        // Construct an explicit symlink scenario so the test is
        // deterministic regardless of where the host's cache lives
        // (cache root may be under ~/Library/Caches/ on a user account
        // or under /var/folders/ in a sandbox — both forms are valid).
        let dir = try TempStore.makeDir(sourceName: "symlink.zip")
        defer { try? FileManager.default.removeItem(at: dir) }

        let linkURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("isInsideCache-link-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: dir)
        defer { try? FileManager.default.removeItem(at: linkURL) }

        // Touch a real file in the cache dir so the path through the
        // symlink fully exists on disk — `resolvingSymlinksInPath`
        // may bail if intermediate components don't resolve.
        let realFile = dir.appendingPathComponent("payload.dmp")
        try Data().write(to: realFile)
        defer { try? FileManager.default.removeItem(at: realFile) }

        let viaLink = linkURL.appendingPathComponent("payload.dmp")
        #expect(TempStore.isInsideCache(viaLink),
                "expected URL through symlink '\(viaLink.path)' to resolve into cache root")
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
