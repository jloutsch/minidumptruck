import Foundation
import Testing
@testable import MiniDumpTruckCore

/// Build a PDBIdentity from known-valid test inputs. Force-unwraps
/// the failable init — every test value below is intentionally inside
/// the validator's allowlist, so a nil here is a test-author bug.
private func validIdentity(pdbName: String, guid: String, age: UInt32) -> PDBIdentity {
    guard let id = PDBIdentity(pdbName: pdbName, guid: guid, age: age) else {
        fatalError("test fixture is no longer valid against PDBIdentity validator: \(pdbName), \(guid)")
    }
    return id
}

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
        let key = validIdentity(pdbName: "ntdll.pdb",
                              guid: String(repeating: "a", count: 32),
                              age: 1)
        let expected = String(repeating: "A", count: 32) + "1"
        #expect(key.cacheKey == expected)
    }

    @Test func cacheKeyAgeRendersAsHex() {
        let key = validIdentity(pdbName: "x.pdb",
                              guid: String(repeating: "b", count: 32),
                              age: 0xAB)
        let expected = String(repeating: "B", count: 32) + "AB"
        #expect(key.cacheKey == expected)
    }

    @Test func storeAndReadRoundTrip() async throws {
        let (cache, _, cleanup) = makeIsolatedCache()
        defer { cleanup() }

        let key = validIdentity(pdbName: "test.pdb",
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

        let key = validIdentity(pdbName: "test.pdb",
                              guid: "22222222222222222222222222222222", age: 1)
        try await cache.store(Data("first".utf8), for: key)
        try await cache.store(Data("second".utf8), for: key)
        let read = await cache.data(for: key)
        #expect(read == Data("second".utf8))
    }

    @Test func clearRemovesAllEntries() async throws {
        let (cache, _, cleanup) = makeIsolatedCache()
        defer { cleanup() }

        let a = validIdentity(pdbName: "a.pdb",
                            guid: "00000000000000000000000000000001", age: 1)
        let b = validIdentity(pdbName: "b.pdb",
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

        let key = validIdentity(pdbName: "test.pdb",
                              guid: "33333333333333333333333333333333", age: 1)
        try await cache.store(Data(repeating: 0xAA, count: 4096), for: key)
        let afterStore = await cache.sizeOnDisk()
        #expect(afterStore >= 4096,
                "size on disk must reflect the stored PDB payload")
    }

    // MARK: - PDBIdentity validator
    //
    // Attacker-controlled pdbName / guid from a malicious .dmp must
    // not be able to write outside the cache root or redirect symbol-
    // server URLs. The validator is the trust boundary; these tests
    // pin its contract.

    @Test func rejectsPdbNameWithPathTraversal() {
        #expect(PDBIdentity(pdbName: "..", guid: String(repeating: "a", count: 32), age: 1) == nil)
        #expect(PDBIdentity(pdbName: ".", guid: String(repeating: "a", count: 32), age: 1) == nil)
        #expect(PDBIdentity(pdbName: "../../etc/passwd",
                            guid: String(repeating: "a", count: 32), age: 1) == nil)
    }

    @Test func rejectsPdbNameWithPathSeparators() {
        #expect(PDBIdentity(pdbName: "foo/bar.pdb",
                            guid: String(repeating: "a", count: 32), age: 1) == nil)
        #expect(PDBIdentity(pdbName: "foo\\bar.pdb",
                            guid: String(repeating: "a", count: 32), age: 1) == nil)
    }

    @Test func rejectsPdbNameWithControlChars() {
        #expect(PDBIdentity(pdbName: "foo\u{00}.pdb",
                            guid: String(repeating: "a", count: 32), age: 1) == nil)
        #expect(PDBIdentity(pdbName: "foo\u{0A}.pdb",
                            guid: String(repeating: "a", count: 32), age: 1) == nil)
    }

    @Test func rejectsEmptyPdbName() {
        #expect(PDBIdentity(pdbName: "", guid: String(repeating: "a", count: 32), age: 1) == nil)
    }

    @Test func rejectsTooLongPdbName() {
        let long = String(repeating: "a", count: 129) + ".pdb"
        #expect(PDBIdentity(pdbName: long,
                            guid: String(repeating: "a", count: 32), age: 1) == nil)
    }

    @Test func rejectsMalformedGUID() {
        // Too short
        #expect(PDBIdentity(pdbName: "x.pdb", guid: "abc", age: 1) == nil)
        // Too long
        #expect(PDBIdentity(pdbName: "x.pdb",
                            guid: String(repeating: "a", count: 33), age: 1) == nil)
        // Non-hex character
        #expect(PDBIdentity(pdbName: "x.pdb",
                            guid: "g" + String(repeating: "a", count: 31), age: 1) == nil)
        // Slashes inside guid (would survive URL appendingPathComponent)
        #expect(PDBIdentity(pdbName: "x.pdb",
                            guid: "../" + String(repeating: "a", count: 29), age: 1) == nil)
    }

    @Test func acceptsValidPdbName() {
        // The MSDL allowlist: letters, digits, dot, underscore, hyphen.
        // Cap at 128 chars. Real PDB names like "ntdll.pdb" or
        // "nvlddmkm.sys.pdb" must pass.
        #expect(PDBIdentity(pdbName: "ntdll.pdb",
                            guid: String(repeating: "a", count: 32), age: 1) != nil)
        #expect(PDBIdentity(pdbName: "nvlddmkm.sys.pdb",
                            guid: String(repeating: "a", count: 32), age: 1) != nil)
        #expect(PDBIdentity(pdbName: "msvcrt.pdb",
                            guid: String(repeating: "a", count: 32), age: 1) != nil)
        #expect(PDBIdentity(pdbName: "kernel32_dll.pdb",
                            guid: String(repeating: "a", count: 32), age: 1) != nil)
    }

    @Test func differentAgesAreIndependentEntries() async throws {
        // Same GUID with different ages is technically a different
        // PDB build; the cache must treat them as independent.
        let (cache, _, cleanup) = makeIsolatedCache()
        defer { cleanup() }

        let guid = "44444444444444444444444444444444"
        let age1 = validIdentity(pdbName: "x.pdb", guid: guid, age: 1)
        let age2 = validIdentity(pdbName: "x.pdb", guid: guid, age: 2)

        try await cache.store(Data("age1".utf8), for: age1)
        try await cache.store(Data("age2".utf8), for: age2)

        let r1 = await cache.data(for: age1)
        let r2 = await cache.data(for: age2)
        #expect(r1 == Data("age1".utf8))
        #expect(r2 == Data("age2".utf8))
    }
}
