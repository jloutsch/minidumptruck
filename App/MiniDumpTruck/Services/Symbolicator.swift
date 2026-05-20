import Foundation

/// Resolves code addresses to exported function names using per-module PE
/// export tables read from dump memory. Slice 1 of issue #2.
public struct Symbolicator: Sendable {
    /// Accuracy guard: if the nearest export is more than this many bytes
    /// below the address, the symbol is probably wrong (unexported/static
    /// code), so report nothing and let the caller fall back to module+offset.
    public static let maxFunctionSpan: UInt64 = 0x40000  // 256 KB

    private let moduleList: ModuleList?
    /// baseAddress -> parsed export table (only modules that produced one).
    private let tables: [UInt64: PEExportTable]

    public init(dump: ParsedMinidump) {
        self.moduleList = dump.moduleList
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
        guard let module = moduleList?.module(containing: address),
              let table = tables[module.baseAddress] else { return nil }
        let imageOffset = address - module.baseAddress
        guard let hit = table.symbol(forImageOffset: imageOffset) else { return nil }
        guard hit.delta <= Self.maxFunctionSpan else { return nil }
        return ResolvedSymbol(function: hit.name, offsetInFunction: hit.delta)
    }
}
