import Foundation
import Testing
@testable import MiniDumpTruckCore

/// Verify that CSV / Text / HTML exporters render ARM64-specific
/// register names (PC/SP/FP/X0-X3, CPSR) for ARM64 dumps. Regressions
/// here would silently print x64 register names regardless of dump
/// architecture.
@Suite("Exporters render ARM64 dumps correctly")
struct ARM64ExporterTests {

    @Test func csvHeaderUsesARM64ColumnNamesForARM64Dump() throws {
        let dump = try makeARM64SyntheticDump(pc: 0xAA, sp: 0xBB, fp: 0xCC)
        let csv = CSVExporter.generateCSV(from: dump)

        // ARM64 column names appear.
        #expect(csv.contains("PC,SP,FP,X0,X1,X2,X3"),
                "ARM64 dump must surface PC/SP/FP/X0-X3 column header — got: \(csv.prefix(2000))")
        // x64-only register names are absent from the thread header row.
        #expect(!csv.contains("RIP,RSP,RBP,RAX"),
                "ARM64 dump must NOT print x64 column names in the thread section")
    }

    @Test func textReporterVerboseUsesARM64RegisterNames() throws {
        let dump = try makeARM64SyntheticDump(pc: 0x1234, sp: 0x2222, fp: 0x3333)
        let report = TextReporter.generateReport(from: dump, analysis: nil, verbose: true)

        #expect(report.contains("PC=0x0000000000001234"),
                "verbose ARM64 report must print PC=, not RIP=")
        #expect(!report.contains("RIP="),
                "verbose ARM64 report must not print RIP=")
        // Each of X0–X3 must individually appear — a regression that
        // dropped any one would have passed the previous `||` form
        // because at least one sibling remained.
        #expect(report.contains("X0="),
                "verbose ARM64 report must include X0=")
        #expect(report.contains("X1="),
                "verbose ARM64 report must include X1=")
        #expect(report.contains("X2="),
                "verbose ARM64 report must include X2=")
        #expect(report.contains("X3="),
                "verbose ARM64 report must include X3=")
        #expect(!report.contains("RAX="),
                "verbose ARM64 report must not include x64 RAX= row")
    }

    @Test func htmlExporterUsesCPSRNotRFLAGS() throws {
        let dump = try makeARM64SyntheticDump(pc: 0, sp: 0, fp: 0, cpsr: 0x4000_0000)  // Z flag
        let html = HTMLExporter.generateReport(from: dump, analysis: nil)

        // CPSR row appears, RFLAGS does not.
        #expect(html.contains("CPSR"),
                "ARM64 HTML report must include CPSR row")
        #expect(!html.contains("RFLAGS"),
                "ARM64 HTML report must not include x64 RFLAGS row")
    }
}
