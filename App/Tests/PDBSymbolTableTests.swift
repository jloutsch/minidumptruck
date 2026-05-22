import Foundation
import Testing
@testable import MiniDumpTruckCore

@Suite("PDBSymbolTable lookup")
struct PDBSymbolTableTests {

    private func table(_ entries: [(name: String, rva: UInt32)]) -> PDBSymbolTable {
        PDBSymbolTable(symbols: entries.map { PDBPublics.Symbol(name: $0.name, rva: $0.rva) })
    }

    @Test func emptyTableReturnsNil() {
        let t = table([])
        #expect(t.symbol(forImageOffset: 0x1000) == nil)
    }

    @Test func exactMatchReturnsZeroDelta() {
        let t = table([("Foo", 0x1000)])
        let hit = t.symbol(forImageOffset: 0x1000)
        #expect(hit?.name == "Foo")
        #expect(hit?.delta == 0)
    }

    @Test func returnsClosestPrecedingSymbol() {
        let t = table([
            ("Alpha", 0x1000),
            ("Beta",  0x2000),
            ("Gamma", 0x3000),
        ])
        let hit = t.symbol(forImageOffset: 0x2050)
        #expect(hit?.name == "Beta")
        #expect(hit?.delta == 0x50)
    }

    @Test func addressBeforeFirstSymbolReturnsNil() {
        let t = table([("Foo", 0x2000)])
        #expect(t.symbol(forImageOffset: 0x1000) == nil,
                "no symbol precedes the address — must not match the first entry")
    }

    @Test func addressFarPastLastSymbolReturnsNilByMaxFunctionSpan() {
        let t = table([("Foo", 0x1000)])
        // 0x1000 + 0x40000 (maxFunctionSpan) + 1 = 0x41001
        #expect(t.symbol(forImageOffset: 0x41001) == nil,
                "delta exceeds maxFunctionSpan — must not match")
    }

    @Test func addressAtMaxFunctionSpanBoundaryStillMatches() {
        let t = table([("Foo", 0x1000)])
        let boundary = UInt64(0x1000) + PDBSymbolTable.maxFunctionSpan
        let hit = t.symbol(forImageOffset: boundary)
        #expect(hit?.name == "Foo")
        #expect(hit?.delta == PDBSymbolTable.maxFunctionSpan)
    }

    @Test func unsortedInputIsSortedInternally() {
        let t = table([
            ("Gamma", 0x3000),
            ("Alpha", 0x1000),
            ("Beta",  0x2000),
        ])
        #expect(t.symbol(forImageOffset: 0x1020)?.name == "Alpha")
        #expect(t.symbol(forImageOffset: 0x2020)?.name == "Beta")
        #expect(t.symbol(forImageOffset: 0x3020)?.name == "Gamma")
    }

    @Test func binarySearchHandlesLargeTable() {
        // 10k symbols at 16-byte intervals — exercises the binary
        // search path that linear lookup would handle, but slowly.
        var entries: [(String, UInt32)] = []
        for i in 0..<10_000 {
            entries.append(("sym_\(i)", UInt32(0x1000 + i * 16)))
        }
        let t = table(entries)
        // Pick a random-ish address inside the table.
        let hit = t.symbol(forImageOffset: 0x1000 + UInt64(7234 * 16) + 4)
        #expect(hit?.name == "sym_7234")
        #expect(hit?.delta == 4)
    }

    @Test func addressBeyondUInt32MaxReturnsNil() {
        // PDB symbols are encoded with u32 RVAs; an address whose
        // image offset can't fit in u32 can't possibly belong to
        // a public symbol from this PDB.
        let t = table([("Foo", 0x1000)])
        #expect(t.symbol(forImageOffset: UInt64(UInt32.max) + 1) == nil)
    }
}
