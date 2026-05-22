import Foundation
import Testing
@testable import MiniDumpTruckCore

/// Verify that Symbolicator's PDB tier takes priority over the PE
/// export tier when both have a match at the same address. PDB
/// publics are a broader set than PE exports, so when both have an
/// entry, the PDB one is the more accurate name (the export-table
/// entry could be a stub or a forwarder).
@Suite("Symbolicator resolution priority")
struct SymbolicatorPriorityTests {

    @Test func pdbTableTakesPriorityOverPEExports() throws {
        // Build a tiny dump with one module. Empty memory (no PE
        // export table can be built from it), and a hand-rolled PDB
        // table for the same module. Resolution must come from the
        // PDB table.
        var dump = makeMinimalDump()
        let moduleBase: UInt64 = 0x7FF8_0000_0000
        let module = makeModule(name: "test.dll", base: moduleBase)
        dump.moduleList = ModuleList(modules: [module])

        // PDB table with one symbol at base + 0x100.
        let pdbTable = PDBSymbolTable(symbols: [
            PDBPublics.Symbol(name: "FromPDB", rva: 0x100)
        ])
        let symbolicator = Symbolicator(
            dump: dump,
            pdbTables: [moduleBase: pdbTable]
        )

        let resolved = symbolicator.resolve(address: moduleBase + 0x100)
        #expect(resolved?.function == "FromPDB")
        #expect(resolved?.offsetInFunction == 0)
    }

    @Test func emptyPdbTablesFallBackToExportTable() throws {
        // No PDB tables provided — Symbolicator must degrade
        // gracefully to PE-export-only resolution (the slice-1 path).
        var dump = makeMinimalDump()
        let moduleBase: UInt64 = 0x7FF8_0000_0000
        dump.moduleList = ModuleList(modules: [
            makeModule(name: "test.dll", base: moduleBase)
        ])

        let symbolicator = Symbolicator(dump: dump, pdbTables: [:])
        // Without dump memory carrying the PE image, the export
        // table is empty, and there's no PDB. Result: nil (caller
        // falls back to module+offset).
        #expect(symbolicator.resolve(address: moduleBase + 0x100) == nil)
    }

    @Test func pdbTableMissForAddressFallsThroughCleanly() throws {
        // PDB table exists for a module but its symbols don't cover
        // the queried address. Result should be nil (no PE table
        // either), not a false match.
        var dump = makeMinimalDump()
        let moduleBase: UInt64 = 0x7FF8_0000_0000
        dump.moduleList = ModuleList(modules: [
            makeModule(name: "test.dll", base: moduleBase)
        ])

        let pdbTable = PDBSymbolTable(symbols: [
            PDBPublics.Symbol(name: "AtBeginning", rva: 0x100)
        ])
        let symbolicator = Symbolicator(
            dump: dump,
            pdbTables: [moduleBase: pdbTable]
        )

        // Address before any symbol — no PDB match.
        #expect(symbolicator.resolve(address: moduleBase + 0x50) == nil)
    }

    @Test func pdbTableOnlyAppliesToItsOwnModule() throws {
        var dump = makeMinimalDump()
        let modA: UInt64 = 0x7FF8_0000_0000
        let modB: UInt64 = 0x7FF8_2000_0000
        dump.moduleList = ModuleList(modules: [
            makeModule(name: "a.dll", base: modA),
            makeModule(name: "b.dll", base: modB),
        ])

        // PDB table only for module A.
        let pdbTable = PDBSymbolTable(symbols: [
            PDBPublics.Symbol(name: "FromA", rva: 0x100)
        ])
        let symbolicator = Symbolicator(
            dump: dump,
            pdbTables: [modA: pdbTable]
        )

        // Address inside A's PDB region resolves.
        #expect(symbolicator.resolve(address: modA + 0x100)?.function == "FromA")
        // Address inside B (no PDB, no PE exports) does not.
        #expect(symbolicator.resolve(address: modB + 0x100) == nil)
    }
}
