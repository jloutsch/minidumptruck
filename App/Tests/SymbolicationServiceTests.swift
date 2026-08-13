import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import MiniDumpTruckCore

@Suite("SymbolicationService", .serialized)
struct SymbolicationServiceTests {

    private static let testBase = URL(string: "https://msdl-svc.test/symbols")!

    /// Build a SymbolicationService rooted in a fresh tmp cache so
    /// tests don't pollute the user's real symbol cache.
    private func makeService() -> (SymbolicationService, SymbolCache, () -> Void) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MDT-symsvc-\(UUID().uuidString)", isDirectory: true)
        let cache = SymbolCache(root: root)
        let server = SymbolServer(baseURL: Self.testBase,
                                  urlSession: StubURLProtocol.session())
        let svc = SymbolicationService(cache: cache, server: server)
        return (svc, cache, { try? FileManager.default.removeItem(at: root) })
    }

    /// Build a synthetic dump with N modules, each carrying a valid
    /// CodeView record. The CV records are constructed via the
    /// CodeViewRecord byte parser to ensure realistic shape.
    private func makeDumpWithModules(_ count: Int) throws -> ParsedMinidump {
        // Use the existing CrashAnalyzerDetailTests synthetic-dump
        // pattern via SyntheticDump.build — but that only emits one
        // module per call. For tests that need N modules with N
        // distinct CVs, we'd have to build the bytes by hand.
        //
        // Pragmatic alternative: use makeMinimalDump() and inject a
        // hand-built ModuleList carrying CV records constructed via
        // CodeViewRecord byte parsing.
        var dump = makeMinimalDump()
        var modules: [ModuleInfo] = []
        for i in 0..<count {
            modules.append(moduleWithCV(
                index: i,
                baseAddress: UInt64(0x7FF8_0000_0000) + UInt64(i) * 0x10_0000
            ))
        }
        dump.moduleList = ModuleList(modules: modules)
        return dump
    }

    /// Build a ModuleInfo whose codeViewRecord encodes a synthetic
    /// CV_INFO_PDB70 record. The makeModule TestHelper produces a
    /// ModuleInfo from raw bytes (no CV record); we then attach a
    /// hand-built CV record to its public `codeViewRecord` field.
    ///
    /// CV_INFO_PDB70 layout:
    ///   sig "RSDS" (4 bytes) + GUID (16 bytes) + age (4 bytes) +
    ///   null-terminated PDB filename.
    private func moduleWithCV(index: Int, baseAddress: UInt64) -> ModuleInfo {
        var module = makeModule(name: "test\(index).dll", base: baseAddress)
        module.codeViewRecord = Self.makeCV(
            pdbName: "test\(index).pdb",
            uniqueByte: UInt8(index & 0xFF)
        )
        return module
    }

    /// Build a synthetic CV_INFO_PDB70 record by writing its bytes and
    /// parsing them with `CodeViewRecord(from:at:size:)`. Returns nil
    /// only on test-author error.
    private static func makeCV(pdbName: String, uniqueByte: UInt8) -> CodeViewRecord? {
        let pdbNameBytes = Array(pdbName.utf8) + [0]  // null-terminated
        var cvBytes = Data()
        cvBytes.append(contentsOf: [0x52, 0x53, 0x44, 0x53])  // "RSDS"
        // GUID: not all-zero (parser-rejected). Mix in `uniqueByte` so
        // each module has a distinct identity.
        var guidBytes = [UInt8](repeating: 0, count: 16)
        guidBytes[0] = 0x01           // ensure non-zero
        guidBytes[15] = uniqueByte
        cvBytes.append(contentsOf: guidBytes)
        cvBytes.append(contentsOf: [0x01, 0x00, 0x00, 0x00])  // age = 1
        cvBytes.append(contentsOf: pdbNameBytes)
        return CodeViewRecord(from: cvBytes, at: 0, size: cvBytes.count)
    }

    @Test func emptyDumpYieldsEmptyResult() async {
        let (svc, _, cleanup) = makeService()
        defer { cleanup() }
        let dump = makeMinimalDump()  // no modules
        let result = await svc.loadSymbols(for: dump)
        #expect(result.isEmpty)
    }

    @Test func modulesWithoutCodeViewAreSkipped() async throws {
        let (svc, _, cleanup) = makeService()
        defer { cleanup() }

        // Build a dump where modules have no CodeView record.
        var dump = makeMinimalDump()
        dump.moduleList = ModuleList(modules: [
            makeModule(name: "no-cv.dll", base: 0x7FF8_0000_0000)
        ])
        let result = await svc.loadSymbols(for: dump)
        #expect(result.isEmpty,
                "modules without a CodeView record contribute no symbols")
    }

    @Test func loadSymbolsHonorsAllModulesPastConcurrencyCap() async throws {
        // The internal max-concurrent is 8. A 12-module dump must
        // still produce 12 results — the prime-and-drain queue
        // management correctly schedules everyone.
        let (svc, _, cleanup) = makeService()
        defer { cleanup() }

        let payload = SyntheticPDB.build(
            sections: [SyntheticPDB.Section(virtualAddress: 0x1000, virtualSize: 0x10000)],
            symbols: [SyntheticPDB.Symbol(name: "Sym", segment: 1, offset: 0x100)]
        )
        StubURLProtocol.setHandler(forHost: "msdl-svc.test"){ request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
             payload)
        }
        defer { StubURLProtocol.reset(host: "msdl-svc.test") }

        let dump = try makeDumpWithModules(12)
        let result = await svc.loadSymbols(for: dump)
        #expect(result.count == 12,
                "all 12 modules must resolve despite the 8-concurrent cap")
    }

    @Test func networkFailureDoesNotPopulateResult() async throws {
        let (svc, _, cleanup) = makeService()
        defer { cleanup() }
        StubURLProtocol.setHandler(forHost: "msdl-svc.test"){ request in
            (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!,
             Data())
        }
        defer { StubURLProtocol.reset(host: "msdl-svc.test") }

        let dump = try makeDumpWithModules(2)
        let result = await svc.loadSymbols(for: dump)
        #expect(result.isEmpty,
                "404 from MSDL must not crash and must leave result empty")

        let stats = await svc.stats()
        #expect(stats.attempted == 2)
        #expect(stats.failures == 2,
                "both modules failed to fetch — failure counter must reflect this")
    }

    @Test func malformedPDBBytesDoNotPoisonResult() async throws {
        let (svc, _, cleanup) = makeService()
        defer { cleanup() }
        // Serve garbage bytes that won't parse as MSF.
        StubURLProtocol.setHandler(forHost: "msdl-svc.test"){ request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
             Data(repeating: 0xCC, count: 1024))
        }
        defer { StubURLProtocol.reset(host: "msdl-svc.test") }

        let dump = try makeDumpWithModules(1)
        let result = await svc.loadSymbols(for: dump)
        #expect(result.isEmpty,
                "PDB that fails MSF parse must produce no result for the affected module")
    }

    @Test func cachedCorruptPDBTriggersEvictionAndRefetch() async throws {
        let (svc, cache, cleanup) = makeService()
        defer { cleanup() }

        // Pre-seed the cache with garbage under the expected key.
        // We need to know what PDBIdentity SymbolicationService will
        // derive — easiest: build a dump with 1 module, derive the
        // identity via the public helper, store garbage there.
        let dump = try makeDumpWithModules(1)
        let module = dump.moduleList!.modules.first!
        let key = svc.identity(for: module)!
        try await cache.store(Data(repeating: 0x42, count: 100), for: key)

        // Now serve a valid PDB on refetch.
        let validPDB = SyntheticPDB.build(
            sections: [SyntheticPDB.Section(virtualAddress: 0x1000, virtualSize: 0x10000)],
            symbols: [SyntheticPDB.Symbol(name: "Recovered", segment: 1, offset: 0x100)]
        )
        StubURLProtocol.setHandler(forHost: "msdl-svc.test"){ request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
             validPDB)
        }
        defer { StubURLProtocol.reset(host: "msdl-svc.test") }

        let result = await svc.loadSymbols(for: dump)
        #expect(result.count == 1,
                "corruption recovery must re-fetch and produce a valid symbol table")

        let stats = await svc.stats()
        #expect(stats.cacheHits == 1, "the corrupt-then-evicted entry counts as a hit")
        #expect(stats.corruptionEvictions == 1)
        #expect(stats.serverFetches == 1, "refetch must have happened")
    }

    @Test func allZeroGUIDModuleIsSkippedByIdentity() async throws {
        let (svc, _, cleanup) = makeService()
        defer { cleanup() }

        // Build a module whose CV record carries an all-zero GUID.
        // SymbolicationService.identity rejects this because MSDL
        // would always 404 such a request.
        var cvBytes = Data()
        cvBytes.append(contentsOf: [0x52, 0x53, 0x44, 0x53])  // RSDS
        cvBytes.append(contentsOf: [UInt8](repeating: 0, count: 16))   // all-zero GUID
        cvBytes.append(contentsOf: [0x01, 0x00, 0x00, 0x00])           // age
        cvBytes.append(contentsOf: Array("zerg.pdb".utf8) + [0])
        let cv = CodeViewRecord(from: cvBytes, at: 0, size: cvBytes.count)!

        var module = makeModule(name: "zerg.dll", base: 0x7FF8_0000_0000)
        module.codeViewRecord = cv

        #expect(svc.identity(for: module) == nil,
                "all-zero GUID must be rejected — MSDL would always 404 it")
    }
}
