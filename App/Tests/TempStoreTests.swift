import Foundation
import Testing
@testable import MiniDumpTruckCore

@Suite("TempStore")
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
        // Backdate the "stale" dir's modification time.
        let oneWeekAgo = Date().addingTimeInterval(-7 * 24 * 3600)
        try FileManager.default.setAttributes([.modificationDate: oneWeekAgo],
                                              ofItemAtPath: stale.path)

        await TempStore.cleanupAged(olderThan: 24 * 3600)

        #expect(FileManager.default.fileExists(atPath: fresh.path))
        #expect(!FileManager.default.fileExists(atPath: stale.path))
    }
}
