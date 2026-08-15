import Foundation

/// Orchestrates "fetch PDBs for every module in a parsed dump, parse
/// them, and hand back a `[baseAddress: PDBSymbolTable]` map" — the
/// async glue between a freshly-parsed minidump and a `Symbolicator`
/// that resolves real function names.
///
/// Workflow:
///   1. Walk the dump's module list.
///   2. For each module with a CodeView CV_INFO_PDB70 record, derive
///      its `PDBIdentity` (pdbName + guid + age).
///   3. Try the on-disk cache; on miss, fetch from the symbol server
///      and store. Either path may fail — failures are silent and the
///      module just gets no PDB.
///   4. Parse each PDB for its public symbols and build a
///      `PDBSymbolTable` keyed by the module's base address.
///
/// All network and disk work happens here so `Symbolicator` itself
/// remains synchronous and `Sendable` — the analyzer pipeline doesn't
/// need to know how the tables were built.
public actor SymbolicationService {
    private let cache: SymbolCache
    private let server: SymbolServer

    public init(cache: SymbolCache, server: SymbolServer) {
        self.cache = cache
        self.server = server
    }

    /// Build a `[baseAddress: PDBSymbolTable]` map for every module in
    /// `dump` whose CodeView record yields a usable `PDBIdentity`.
    /// Modules without a CV record, with malformed records, or that
    /// fail to fetch/parse are simply absent from the result — the
    /// `Symbolicator` then falls back to its PE-export tier.
    /// Per-session counters for observability — incremented as modules
    /// resolve. Snapshotted via `stats()` for a debug UI / log line.
    public struct Stats: Sendable, Equatable {
        public var attempted: Int = 0
        public var cacheHits: Int = 0
        public var serverFetches: Int = 0
        public var parseSuccesses: Int = 0
        public var corruptionEvictions: Int = 0
        public var failures: Int = 0  // any path that produced no symbols
    }
    private var counters = Stats()

    /// Current session statistics. Useful for "Why are no symbols
    /// showing?" debugging — the Console log carries detail, this
    /// gives an at-a-glance summary.
    public func stats() -> Stats { counters }

    public func loadSymbols(for dump: ParsedMinidump) async -> [UInt64: PDBSymbolTable] {
        let modules = dump.moduleList?.modules ?? []
        var result: [UInt64: PDBSymbolTable] = [:]

        SymbolLog.shared.info("symbolicating \(modules.count) modules")

        // Fetch concurrently up to `maxConcurrent`. Microsoft's symbol
        // server is fast and tolerant of parallel requests, but a
        // 100-module dump shouldn't open 100 sockets.
        let maxConcurrent = 8
        await withTaskGroup(of: (UInt64, PDBSymbolTable?)?.self) { group in
            var inFlight = 0
            var queue = modules.makeIterator()

            // Prime the pipeline.
            while inFlight < maxConcurrent, let module = queue.next() {
                if scheduleIfFetchable(module, into: &group) {
                    inFlight += 1
                }
            }

            // Drain + refill until done.
            while let outcome = await group.next() {
                inFlight -= 1
                if let outcome, let table = outcome.1 {
                    result[outcome.0] = table
                }
                if let module = queue.next(),
                   scheduleIfFetchable(module, into: &group) {
                    inFlight += 1
                }
            }
        }

        SymbolLog.shared.info("symbolication complete: \(result.count) of \(modules.count) modules resolved (stats: attempted=\(self.counters.attempted) cacheHits=\(self.counters.cacheHits) serverFetches=\(self.counters.serverFetches) failures=\(self.counters.failures) evicted=\(self.counters.corruptionEvictions))")
        return result
    }

    /// Schedule a fetch+parse subtask if the module has a usable PDB
    /// identity. Returns true if a subtask was added to the group.
    ///
    /// Implements **cache corruption recovery**: if a cache hit parses
    /// successfully, return it. If it FAILS to parse (partial write
    /// from an older build, user tampering, MSDL serving HTML during
    /// outage on a previous run), evict the entry and re-fetch once
    /// from the server. This makes the cache self-healing without
    /// requiring the user to know about `clear()`.
    private func scheduleIfFetchable(
        _ module: ModuleInfo,
        into group: inout TaskGroup<(UInt64, PDBSymbolTable?)?>
    ) -> Bool {
        guard let key = identity(for: module) else { return false }
        let baseAddress = module.baseAddress
        let cache = self.cache
        let server = self.server
        counters.attempted += 1
        // `await withTaskGroup` blocks until every subtask finishes,
        // so `self` outlives every addTask body. No [weak self]
        // ceremony needed.
        group.addTask {
            // Try cache first.
            if let cachedData = await cache.data(for: key) {
                await self.record(.cacheHit)
                if let symbols = try? PDBPublics.parse(cachedData), !symbols.isEmpty {
                    await self.record(.parseSuccess)
                    return (baseAddress, PDBSymbolTable(symbols: symbols))
                }
                // Cached bytes failed to parse — corruption recovery.
                SymbolLog.shared.notice("cached PDB for \(key.pdbName) failed to parse; evicting and re-fetching")
                await cache.evict(key)
                await self.record(.eviction)
            }
            // Either cache miss or post-eviction refetch.
            do {
                let freshData = try await server.fetch(key)
                try? await cache.store(freshData, for: key)
                await self.record(.serverFetch)
                if let symbols = try? PDBPublics.parse(freshData), !symbols.isEmpty {
                    await self.record(.parseSuccess)
                    return (baseAddress, PDBSymbolTable(symbols: symbols))
                }
                // Fresh bytes also failed to parse — server-side
                // problem. Log + drop, don't loop.
                SymbolLog.shared.error("freshly-fetched PDB for \(key.pdbName) failed to parse")
                await self.record(.failure)
                return (baseAddress, nil)
            } catch {
                await self.record(.failure)
                return (baseAddress, nil)
            }
        }
        return true
    }

    /// Counter increments — collapsed from five `record*` methods into
    /// one enum-driven update so the call sites read like events
    /// rather than method calls.
    private enum CounterEvent { case cacheHit, serverFetch, parseSuccess, eviction, failure }
    private func record(_ event: CounterEvent) {
        switch event {
        case .cacheHit:      counters.cacheHits += 1
        case .serverFetch:   counters.serverFetches += 1
        case .parseSuccess:  counters.parseSuccesses += 1
        case .eviction:      counters.corruptionEvictions += 1
        case .failure:       counters.failures += 1
        }
    }

    /// Derive a `PDBIdentity` from a module's CodeView record. Returns
    /// nil when the record is missing, malformed, or doesn't carry a
    /// PDB filename.
    public nonisolated func identity(for module: ModuleInfo) -> PDBIdentity? {
        guard let cv = module.codeViewRecord,
              let guid = cv.guidString,
              let pdbName = Self.basename(cv.pdbName),
              !pdbName.isEmpty
        else { return nil }
        // Reject all-zero GUIDs — they correspond to PDBs that were
        // never built or stripped of debug info, and MSDL will always
        // 404 the request. Skipping saves a network round-trip per
        // such module.
        guard guid.contains(where: { $0 != "0" }) else { return nil }
        // PDBIdentity.init? rejects malformed pdbName / guid that
        // could otherwise traverse the cache root or redirect URLs.
        return PDBIdentity(pdbName: pdbName, guid: guid, age: cv.age)
    }

    /// Strip any Windows directory prefix from a CodeView-recorded PDB
    /// path. Microsoft typically records the absolute build path here
    /// (`d:\\src\\build\\ntdll\\ntdll.pdb`); we only want the filename.
    private static func basename(_ path: String) -> String? {
        if let last = path.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last {
            return String(last)
        }
        return path.isEmpty ? nil : path
    }
}
