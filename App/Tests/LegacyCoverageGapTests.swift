import Foundation
import Testing
@testable import MiniDumpTruckCore

/// Coverage-gap tests for legacy code paths surfaced by /review
/// Testing specialist (issue #29). Each test is synthetic (no
/// dependency on App/TestData/*.dmp) so CI cannot silently skip it.
@Suite("Legacy coverage gaps (#29)")
struct LegacyCoverageGapTests {

    // MARK: - 1. TextReporter verbose path

    @Test func textReporterVerbosePathRendersRegistersAndMemory() {
        // Without a .dmp fixture available on CI, the existing verbose
        // test silently skipped via `try #require`. Build a synthetic
        // dump that exercises the register-print + memory-regions
        // branches of TextReporter.generateReport(verbose: true).
        var dump = makeMinimalDump()

        let context = makeZeroContext()
        var thread = ThreadInfo(
            id: 1,
            stack: MinidumpMemoryDescriptor(startOfMemoryRange: 0, dataSize: 0, rva: 0),
            contextLocation: MinidumpLocationDescriptor(dataSize: 0, rva: 0)
        )
        thread.setContext(context)
        dump.threadList = ThreadList(threads: [thread])

        let memRegion = MemoryInfo(
            baseAddress: 0x7FF000000000,
            regionSize: 0x10000,
            state: .commit
        )
        dump.memoryInfoList = MemoryInfoList(entries: [memRegion])

        let report = TextReporter.generateReport(from: dump, analysis: nil, verbose: true)

        // Verbose branch: register dump for thread context. Match the
        // full row pattern (label=hex16 × 3) so a regression that
        // truncated values or split the row across lines fails.
        let regRow = try? NSRegularExpression(
            pattern: #"RIP=0x[0-9A-Fa-f]{16}\s+RSP=0x[0-9A-Fa-f]{16}\s+RBP=0x[0-9A-Fa-f]{16}"#
        )
        let range = NSRange(report.startIndex..., in: report)
        #expect(regRow?.firstMatch(in: report, range: range) != nil,
                "verbose report must include full RIP/RSP/RBP row with hex values; got: \(report)")

        // Verbose branch: memory regions table includes the synthetic
        // base address (0x7FF000000000), not just the section header.
        #expect(report.contains("MEMORY REGIONS"))
        #expect(report.contains("0x00007FF000000000"),
                "verbose report must render the synthetic memory region's base address")
    }

    // MARK: - 2. CSV comma escape

    @Test func csvCommaEscapeQuotesFieldsContainingCommas() throws {
        // Existing csvEscapesCommasInFields was tautological — it ran
        // against a dump with no modules, so escapeCSV's comma path
        // never fired. Inject a module whose name contains a comma
        // and verify RFC-4180 quoting wraps the field.
        var dump = makeMinimalDump()
        dump.moduleList = ModuleList(modules: [
            makeModule(name: "foo, bar.dll", base: 0x40000000)
        ])

        let csv = CSVExporter.generateCSV(from: dump)

        // Find the module row and verify "foo, bar.dll" is a properly
        // delimited CSV cell — surrounded by commas or row boundaries
        // — not just any substring of the output. A buggy exporter
        // wrapping the entire row in one quoted field would pass a
        // raw `contains` check but fail this one.
        let lines = csv.components(separatedBy: "\n")
        let moduleRow = lines.first { $0.contains("foo, bar.dll") }
        let row = try #require(moduleRow, "module name not present in any CSV row")
        // The quoted-comma field must appear with a CSV delimiter on
        // both sides (comma or row start/end).
        let delimited = row.contains(",\"foo, bar.dll\",") ||
                        row.hasPrefix("\"foo, bar.dll\",") ||
                        row.hasSuffix(",\"foo, bar.dll\"") ||
                        row == "\"foo, bar.dll\""
        #expect(delimited,
                "field must be a properly delimited CSV cell, not just a substring; row: \(row)")
    }

    // MARK: - 3. HTMLExporter XSS regression test

    @Test func htmlExporterEscapesHTMLMetacharsInModuleNames() {
        // No prior test fed HTML metacharacters through a synthesized
        // dump's module name. A regression that removed an
        // escapeHTML(...) call from any of the ~80 module-rendering
        // sites would not have been caught. Cover three sinks:
        // body content (<script>), attribute context (" breakout),
        // and standalone & (must not double-encode).
        var dump = makeMinimalDump()
        dump.moduleList = ModuleList(modules: [
            makeModule(
                name: "<script>alert(1)</script>\" onerror=\"alert(2)\" & raw",
                base: 0x50000000
            )
        ])

        let html = HTMLExporter.generateReport(from: dump, analysis: nil)

        // Body context: raw tag must not appear; entities must.
        #expect(!html.contains("<script>alert(1)</script>"),
                "raw <script> tag must not appear in HTML output")
        #expect(html.contains("&lt;script&gt;"))
        // Attribute context: " must be entity-encoded so it cannot
        // close a title=\"...\" attribute and inject onerror=.
        #expect(!html.contains("\" onerror=\"alert(2)\""),
                "raw \"-breakout in attribute context must not appear")
        #expect(html.contains("&quot;"))
        // Standalone & must be single-encoded to &amp;, never double.
        #expect(html.contains("&amp; raw"),
                "raw & must be entity-encoded once")
        #expect(!html.contains("&amp;amp;"),
                "& must not be double-encoded")
    }

    // MARK: - 4. CrashAnalyzer mismatched threadId

    @Test func crashAnalyzerReturnsNilForMismatchedFaultingThreadId() {
        // Real edge case in malformed dumps and kernel-mode exceptions
        // where the exception names a thread ID absent from the
        // ThreadList. CrashAnalyzer.analyze() guards on
        // `MinidumpParser.faultingThread(in: dump) != nil` and returns
        // nil otherwise — assert that exact contract.
        var dump = makeMinimalDump()

        dump.exception = ExceptionInfo(
            threadId: 99,                      // not in ThreadList
            exceptionCode: 0xC0000005,
            exceptionAddress: 0xDEADBEEF
        )
        dump.threadList = ThreadList(threads: [
            ThreadInfo(
                id: 1,
                stack: MinidumpMemoryDescriptor(startOfMemoryRange: 0, dataSize: 0, rva: 0),
                contextLocation: MinidumpLocationDescriptor(dataSize: 0, rva: 0)
            )
        ])

        let analyzer = CrashAnalyzer(dump: dump)
        #expect(analyzer.analyze() == nil,
                "analyze() must return nil when exception.threadId is absent from ThreadList")
    }
}
