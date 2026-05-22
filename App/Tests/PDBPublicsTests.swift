import Foundation
import Testing
@testable import MiniDumpTruckCore

@Suite("PDB public symbol extraction")
struct PDBPublicsTests {

    @Test func extractsSinglePublicSymbol() throws {
        let pdb = SyntheticPDB.build(
            sections: [
                SyntheticPDB.Section(virtualAddress: 0x1000, virtualSize: 0x10000)
            ],
            symbols: [
                SyntheticPDB.Symbol(name: "FuncAlpha", segment: 1, offset: 0x100)
            ]
        )
        let symbols = try PDBPublics.parse(pdb)
        #expect(symbols.count == 1)
        #expect(symbols[0].name == "FuncAlpha")
        // RVA = section[0].VA (0x1000) + offset (0x100) = 0x1100
        #expect(symbols[0].rva == 0x1100)
    }

    @Test func extractsMultiplePublicSymbols() throws {
        let pdb = SyntheticPDB.build(
            sections: [
                SyntheticPDB.Section(virtualAddress: 0x1000, virtualSize: 0x10000)
            ],
            symbols: [
                SyntheticPDB.Symbol(name: "FuncAlpha", segment: 1, offset: 0x100),
                SyntheticPDB.Symbol(name: "FuncBeta",  segment: 1, offset: 0x500),
                SyntheticPDB.Symbol(name: "FuncGamma", segment: 1, offset: 0x900),
            ]
        )
        let symbols = try PDBPublics.parse(pdb)
        #expect(symbols.count == 3)
        let byName = Dictionary(uniqueKeysWithValues: symbols.map { ($0.name, $0.rva) })
        #expect(byName["FuncAlpha"] == 0x1100)
        #expect(byName["FuncBeta"]  == 0x1500)
        #expect(byName["FuncGamma"] == 0x1900)
    }

    @Test func mapsSegmentToCorrectSection() throws {
        // Two sections — the parser must pick the right one based on
        // the symbol's segment index.
        let pdb = SyntheticPDB.build(
            sections: [
                SyntheticPDB.Section(virtualAddress: 0x1000, virtualSize: 0x10000),    // segment 1 -> .text
                SyntheticPDB.Section(virtualAddress: 0x20000, virtualSize: 0x1000),    // segment 2 -> .data
            ],
            symbols: [
                SyntheticPDB.Symbol(name: "InText", segment: 1, offset: 0x50),
                SyntheticPDB.Symbol(name: "InData", segment: 2, offset: 0x10),
            ]
        )
        let symbols = try PDBPublics.parse(pdb)
        let byName = Dictionary(uniqueKeysWithValues: symbols.map { ($0.name, $0.rva) })
        #expect(byName["InText"] == UInt32(0x1000 + 0x50))
        #expect(byName["InData"] == UInt32(0x20000 + 0x10))
    }

    @Test func unicodeSafeNamesParseAsAscii() throws {
        // PDBs encode names as ASCII (modern PDBs may use UTF-8 but
        // we don't rely on that). Standard C symbol names are
        // ASCII-only, so this is a sanity check that our null-
        // terminated string parsing handles typical names.
        let pdb = SyntheticPDB.build(
            sections: [SyntheticPDB.Section(virtualAddress: 0x1000, virtualSize: 0x1000)],
            symbols: [
                SyntheticPDB.Symbol(
                    name: "_ZN4test3FooEv",  // typical mangled C++ name
                    segment: 1, offset: 0x0
                )
            ]
        )
        let symbols = try PDBPublics.parse(pdb)
        #expect(symbols.first?.name == "_ZN4test3FooEv")
    }

    @Test func emptySymbolStreamYieldsNoSymbols() throws {
        let pdb = SyntheticPDB.build(
            sections: [SyntheticPDB.Section(virtualAddress: 0x1000, virtualSize: 0x1000)],
            symbols: []
        )
        let symbols = try PDBPublics.parse(pdb)
        #expect(symbols.isEmpty)
    }

    @Test func segmentZeroRecordIsSilentlyDropped() throws {
        // Segment 0 in CodeView means "absolute" symbol — not
        // section-relative. The parser must drop it because there's
        // no RVA to compute.
        let pdb = SyntheticPDB.build(
            sections: [SyntheticPDB.Section(virtualAddress: 0x1000, virtualSize: 0x1000)],
            symbols: [
                SyntheticPDB.Symbol(name: "Absolute", segment: 0, offset: 0x0),
                SyntheticPDB.Symbol(name: "Relative", segment: 1, offset: 0x100),
            ]
        )
        let symbols = try PDBPublics.parse(pdb)
        #expect(symbols.map(\.name) == ["Relative"],
                "absolute symbols (segment=0) must be dropped; only Relative should remain")
    }

    @Test func oversizedSegmentRecordIsDropped() throws {
        // Segment index beyond the section table must be dropped (not
        // crash, not return garbage RVA).
        let pdb = SyntheticPDB.build(
            sections: [SyntheticPDB.Section(virtualAddress: 0x1000, virtualSize: 0x1000)],
            symbols: [
                SyntheticPDB.Symbol(name: "BadSeg", segment: 99, offset: 0x100),
            ]
        )
        let symbols = try PDBPublics.parse(pdb)
        #expect(symbols.isEmpty)
    }

    @Test func integratesWithPDBSymbolTable() throws {
        // End-to-end: parsed symbols feed a PDBSymbolTable lookup.
        let pdb = SyntheticPDB.build(
            sections: [SyntheticPDB.Section(virtualAddress: 0x1000, virtualSize: 0x10000)],
            symbols: [
                SyntheticPDB.Symbol(name: "FuncA", segment: 1, offset: 0x100),
                SyntheticPDB.Symbol(name: "FuncB", segment: 1, offset: 0x500),
            ]
        )
        let symbols = try PDBPublics.parse(pdb)
        let table = PDBSymbolTable(symbols: symbols)
        let hit = table.symbol(forImageOffset: 0x1100 + 0x42)
        #expect(hit?.name == "FuncA")
        #expect(hit?.delta == 0x42)
    }
}
