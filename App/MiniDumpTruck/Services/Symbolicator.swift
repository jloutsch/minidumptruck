import Foundation

/// Resolves code addresses to function names.
///
/// Two-tier resolution:
/// 1. PE export tables read from dump memory (slice 1 of #2). Covers
///    exported (dllexport) names without any network access.
/// 2. PDB public symbol tables (slice 2). Covers a broader set
///    including internal-linkage functions and inlined entries,
///    populated by `SymbolicationService` fetching from a Microsoft
///    symbol server.
///
/// PDB tables are checked first because they're broader; export-table
/// fallback resolves the rare case where a PDB lookup misses but the
/// address is in an exported function.
public struct Symbolicator: Sendable {
    /// Accuracy guard: if the nearest export is more than this many bytes
    /// below the address, the symbol is probably wrong (unexported/static
    /// code), so report nothing and let the caller fall back to module+offset.
    public static let maxFunctionSpan: UInt64 = 0x40000  // 256 KB

    private let moduleList: ModuleList?
    /// baseAddress -> parsed export table (only modules that produced one).
    private let tables: [UInt64: PEExportTable]
    /// baseAddress -> server-fetched PDB symbols. Empty until populated
    /// by a `SymbolicationService` call after the dump is opened.
    private let pdbTables: [UInt64: PDBSymbolTable]

    public init(dump: ParsedMinidump, pdbTables: [UInt64: PDBSymbolTable] = [:]) {
        self.moduleList = dump.moduleList
        self.pdbTables = pdbTables
        let reader = DumpMemoryReader(dump: dump)
        var built: [UInt64: PEExportTable] = [:]
        for module in dump.moduleList?.modules ?? [] {
            if built[module.baseAddress] != nil { continue }
            if let table = PEExportTable(reader: reader,
                                         imageBase: module.baseAddress,
                                         imageSize: module.sizeOfImage) {
                built[module.baseAddress] = table
            }
        }
        self.tables = built
    }

    public func resolve(address: UInt64) -> ResolvedSymbol? {
        guard let module = moduleList?.module(containing: address) else { return nil }
        let imageOffset = address - module.baseAddress

        // PDB first — it's the broader source.
        if let pdb = pdbTables[module.baseAddress],
           let hit = pdb.symbol(forImageOffset: imageOffset),
           hit.delta <= Self.maxFunctionSpan {
            return ResolvedSymbol(function: hit.name, offsetInFunction: hit.delta)
        }

        // Fall back to PE export table.
        if let table = tables[module.baseAddress],
           let hit = table.symbol(forImageOffset: imageOffset),
           hit.delta <= Self.maxFunctionSpan {
            return ResolvedSymbol(function: hit.name, offsetInFunction: hit.delta)
        }

        return nil
    }
}
