import Foundation
import Testing
@testable import MiniDumpTruckCore

@Suite("SymbolCache")
struct SymbolCacheTests {

    /// Create a SymbolCache rooted at a fresh temp directory so tests
    /// don't touch the user's real cache. Caller is responsible for
    /// cleanup via the returned cleanup closure.
    private func makeIsolatedCache() -> (SymbolCache, URL, () -> Void) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MiniDumpTruck-SymbolCacheTests-\(UUID().uuidString)",
                                    isDirectory: true)
        let cache = SymbolCache(root: root)
        return (cache, root, {
            try? FileManager.default.removeItem(at: root)
        })
    }

    @Test func cacheKeyMatchesMSDLDirectoryConvention() {
        // Test GUIDs use single-character repeating patterns so secret
        // scanners don't flag the 32-hex-char string as a possible API
        // key. The real PDB GUIDs from CodeView records will be 32
        // random hex chars; the upper-case normalization is what we
        // assert here.
        let key = PDBIdentity(pdbName: "ntdll.pdb",
                              guid: String(repeating: "a", count: 32),
                              age: 1)
        let expected = String(repeating: "A", count: 32) + "1"
        #expect(key.cacheKey == expected)
    }

    @Test func cacheKeyAgeRendersAsHex() {
        let key = PDBIdentity(pdbName: "x.pdb",
                              guid: String(repeating: "b", count: 32),
                              age: 0xAB)
        let expected = String(repeating: "B", count: 32) + "AB"
        #expect(key.cacheKey == expected)
    }

    @Test func storeAndReadRoundTrip() async throws {
        let (cache, _, cleanup) = makeIsolatedCache()
        defer { cleanup() }

        let key = PDBIdentity(pdbName: "test.pdb",
                              guid: "11111111111111111111111111111111", age: 1)
        let payload = Data("hello pdb".utf8)

        let initiallyMissing = await cache.exists(key)
        #expect(initiallyMissing == false)
        let initiallyNil = await cache.data(for: key)
        #expect(initiallyNil == nil)

        try await cache.store(payload, for: key)
        let hit = await cache.exists(key)
        #expect(hit == true)
        let read = await cache.data(for: key)
        #expect(read == payload)
    }

    @Test func storeIsAtomic() async throws {
        // Overwriting an existing entry must not leave a half-written
        // file even if the OS would let us read the temp file early.
        // We can't easily race a `write`, so this test just verifies
        // the API behavior: a second `store` cleanly replaces the first.
        let (cache, _, cleanup) = makeIsolatedCache()
        defer { cleanup() }

        let key = PDBIdentity(pdbName: "test.pdb",
                              guid: "22222222222222222222222222222222", age: 1)
        try await cache.store(Data("first".utf8), for: key)
        try await cache.store(Data("second".utf8), for: key)
        let read = await cache.data(for: key)
        #expect(read == Data("second".utf8))
    }

    @Test func clearRemovesAllEntries() async throws {
        let (cache, _, cleanup) = makeIsolatedCache()
        defer { cleanup() }

        let a = PDBIdentity(pdbName: "a.pdb",
                            guid: "00000000000000000000000000000001", age: 1)
        let b = PDBIdentity(pdbName: "b.pdb",
                            guid: "00000000000000000000000000000002", age: 1)
        try await cache.store(Data("a".utf8), for: a)
        try await cache.store(Data("b".utf8), for: b)

        await cache.clear()

        let aMissing = await cache.exists(a)
        let bMissing = await cache.exists(b)
        #expect(aMissing == false)
        #expect(bMissing == false)
    }

    @Test func sizeOnDiskReflectsStoredEntries() async throws {
        let (cache, _, cleanup) = makeIsolatedCache()
        defer { cleanup() }

        let initial = await cache.sizeOnDisk()
        #expect(initial == 0)

        let key = PDBIdentity(pdbName: "test.pdb",
                              guid: "33333333333333333333333333333333", age: 1)
        try await cache.store(Data(repeating: 0xAA, count: 4096), for: key)
        let afterStore = await cache.sizeOnDisk()
        #expect(afterStore >= 4096,
                "size on disk must reflect the stored PDB payload")
    }

    @Test func differentAgesAreIndependentEntries() async throws {
        // Same GUID with different ages is technically a different
        // PDB build; the cache must treat them as independent.
        let (cache, _, cleanup) = makeIsolatedCache()
        defer { cleanup() }

        let guid = "44444444444444444444444444444444"
        let age1 = PDBIdentity(pdbName: "x.pdb", guid: guid, age: 1)
        let age2 = PDBIdentity(pdbName: "x.pdb", guid: guid, age: 2)

        try await cache.store(Data("age1".utf8), for: age1)
        try await cache.store(Data("age2".utf8), for: age2)

        let r1 = await cache.data(for: age1)
        let r2 = await cache.data(for: age2)
        #expect(r1 == Data("age1".utf8))
        #expect(r2 == Data("age2".utf8))
    }
}
