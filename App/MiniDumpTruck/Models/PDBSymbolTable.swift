import Foundation

/// A queryable view over a PDB's public symbols. Sorted by RVA so a
/// binary search resolves the symbol containing a given address.
///
/// Lives alongside `PEExportTable` as a second symbol-resolution input
/// for `Symbolicator`. The PE export table covers exported (dllexport)
/// names; the PDB public table covers a much broader set including
/// internal-linkage functions and inlined entry points — which is the
/// main user-facing win of slice 2 over slice 1.
public struct PDBSymbolTable: Sendable {
    /// Maximum bytes between an address and the nearest preceding
    /// symbol before we give up and report no match. PDB public
    /// symbols don't carry size info, so we need a heuristic ceiling
    /// to avoid claiming `ntdll!some_huge_function` for an address
    /// that's actually in a different (unexported) function nearby.
    /// 256 KB matches the export-table guard.
    public static let maxFunctionSpan: UInt64 = 0x40000

    /// Sorted by `rva` ascending so `symbol(forImageOffset:)` can do a
    /// binary search.
    private let sorted: [PDBPublics.Symbol]

    public init(symbols: [PDBPublics.Symbol]) {
        self.sorted = symbols.sorted { $0.rva < $1.rva }
    }

    public var count: Int { sorted.count }

    /// Find the symbol whose RVA is the largest value ≤ `imageOffset`,
    /// then check that the gap is within `maxFunctionSpan`. Returns
    /// `(name, delta)` matching the `PEExportTable.symbol` shape so
    /// `Symbolicator` can consume either.
    public func symbol(forImageOffset imageOffset: UInt64) -> (name: String, delta: UInt64)? {
        guard !sorted.isEmpty,
              imageOffset <= UInt64(UInt32.max) else { return nil }
        let target = UInt32(imageOffset)

        // Binary search for the largest rva ≤ target.
        var lo = 0
        var hi = sorted.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if sorted[mid].rva <= target {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        let idx = lo - 1
        guard idx >= 0 else { return nil }

        let entry = sorted[idx]
        let delta = UInt64(target - entry.rva)
        guard delta <= Self.maxFunctionSpan else { return nil }
        return (entry.name, delta)
    }
}
