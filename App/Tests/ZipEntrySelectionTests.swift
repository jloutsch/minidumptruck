import Foundation
import Testing
@testable import MiniDumpTruckCore

@Suite("ZipEntrySelection")
struct ZipEntrySelectionTests {
    /// Build a `ZipArchive` with three entries to get real `ZipEntry` values
    /// (each carries a UUID `id` we can select against).
    private func makeArchive() throws -> ZipArchive {
        let bytes = SyntheticZipBuilder.build([
            .init(name: "a.dmp", uncompressed: Data("a".utf8), method: .store),
            .init(name: "b.dmp", uncompressed: Data("b".utf8), method: .store),
            .init(name: "c.dmp", uncompressed: Data("c".utf8), method: .store)
        ])
        return try ZipArchive(data: bytes)
    }

    @Test func emptySelectionReturnsEmpty() throws {
        let archive = try makeArchive()
        let result = ZipEntrySelection.selected(from: archive.entries, ids: [])
        #expect(result.isEmpty)
    }

    @Test func partialSelectionReturnsMatchingEntriesInSourceOrder() throws {
        let archive = try makeArchive()
        // Select entries [0] and [2] in reverse insertion order to test ordering.
        let ids: Set<UUID> = [archive.entries[2].id, archive.entries[0].id]
        let result = ZipEntrySelection.selected(from: archive.entries, ids: ids)
        #expect(result.map(\.name) == ["a.dmp", "c.dmp"])
    }

    @Test func fullSelectionReturnsAllEntriesInSourceOrder() throws {
        let archive = try makeArchive()
        let ids = Set(archive.entries.map(\.id))
        let result = ZipEntrySelection.selected(from: archive.entries, ids: ids)
        #expect(result.map(\.name) == ["a.dmp", "b.dmp", "c.dmp"])
    }

    @Test func unknownIdsAreIgnored() throws {
        let archive = try makeArchive()
        let ids: Set<UUID> = [UUID(), UUID(), archive.entries[1].id]
        let result = ZipEntrySelection.selected(from: archive.entries, ids: ids)
        #expect(result.map(\.name) == ["b.dmp"])
    }
}
