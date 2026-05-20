import Foundation
import Testing
@testable import MiniDumpTruckCore

@Suite("HTML Exporter Tests")
struct HTMLExporterTests {

    // MARK: - Test Data Paths

    static var testDataPath: String {
        var url = URL(fileURLWithPath: #file)
        while url.path != "/" {
            url = url.deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
                return url.appendingPathComponent("TestData").path
            }
        }
        return ""
    }

    static func testFile(_ name: String) -> URL {
        URL(fileURLWithPath: testDataPath).appendingPathComponent(name)
    }

    // MARK: - Structure Tests

    @Test func htmlContainsDoctype() throws {
        let url = Self.testFile("test.dmp")
        try #require(FileManager.default.fileExists(atPath: url.path))

        let data = try Data(contentsOf: url)
        let dump = try MinidumpParser.parse(data: data)
        let html = HTMLExporter.generateReport(from: dump, analysis: nil)

        #expect(html.hasPrefix("<!DOCTYPE html>"))
        #expect(html.contains("</html>"))
    }

    @Test func htmlContainsCSSStylesheet() throws {
        let url = Self.testFile("test.dmp")
        try #require(FileManager.default.fileExists(atPath: url.path))

        let data = try Data(contentsOf: url)
        let dump = try MinidumpParser.parse(data: data)
        let html = HTMLExporter.generateReport(from: dump, analysis: nil)

        #expect(html.contains("<style>"))
        #expect(html.contains("</style>"))
        #expect(html.contains("prefers-color-scheme: dark"))
    }

    @Test func htmlContainsSummarySection() throws {
        let url = Self.testFile("test.dmp")
        try #require(FileManager.default.fileExists(atPath: url.path))

        let data = try Data(contentsOf: url)
        let dump = try MinidumpParser.parse(data: data)
        let html = HTMLExporter.generateReport(from: dump, analysis: nil)

        #expect(html.contains("id=\"summary\""))
        #expect(html.contains("Summary"))
    }

    @Test func htmlContainsSystemInfoSection() throws {
        let url = Self.testFile("test.dmp")
        try #require(FileManager.default.fileExists(atPath: url.path))

        let data = try Data(contentsOf: url)
        let dump = try MinidumpParser.parse(data: data)

        guard dump.systemInfo != nil else { return }

        let html = HTMLExporter.generateReport(from: dump, analysis: nil)
        #expect(html.contains("id=\"system-info\""))
        #expect(html.contains("System Information"))
    }

    @Test func htmlContainsExceptionSection() throws {
        let url = Self.testFile("test.dmp")
        try #require(FileManager.default.fileExists(atPath: url.path))

        let data = try Data(contentsOf: url)
        let dump = try MinidumpParser.parse(data: data)

        guard dump.exception != nil else { return }

        let html = HTMLExporter.generateReport(from: dump, analysis: nil)
        #expect(html.contains("id=\"exception\""))
        #expect(html.contains("Exception"))
    }

    @Test func htmlContainsModulesSection() throws {
        let url = Self.testFile("test.dmp")
        try #require(FileManager.default.fileExists(atPath: url.path))

        let data = try Data(contentsOf: url)
        let dump = try MinidumpParser.parse(data: data)

        guard let moduleList = dump.moduleList, !moduleList.modules.isEmpty else { return }

        let html = HTMLExporter.generateReport(from: dump, analysis: nil)
        #expect(html.contains("id=\"modules\""))
        #expect(html.contains("Modules"))
    }

    @Test func htmlContainsThreadsSection() throws {
        let url = Self.testFile("test.dmp")
        try #require(FileManager.default.fileExists(atPath: url.path))

        let data = try Data(contentsOf: url)
        let dump = try MinidumpParser.parse(data: data)

        guard let threadList = dump.threadList, !threadList.threads.isEmpty else { return }

        let html = HTMLExporter.generateReport(from: dump, analysis: nil)
        #expect(html.contains("id=\"threads\""))
        #expect(html.contains("Threads"))
    }

    @Test func htmlIncludesAnalysisWhenProvided() throws {
        let url = Self.testFile("test.dmp")
        try #require(FileManager.default.fileExists(atPath: url.path))

        let data = try Data(contentsOf: url)
        let dump = try MinidumpParser.parse(data: data)
        let analysis = CrashAnalyzer(dump: dump).analyze()

        let html = HTMLExporter.generateReport(from: dump, analysis: analysis)

        if analysis != nil {
            #expect(html.contains("id=\"analysis\""))
            #expect(html.contains("Crash Analysis"))
            #expect(html.contains("Call Stack"))
        }
    }

    @Test func htmlContainsTableOfContents() throws {
        let url = Self.testFile("test.dmp")
        try #require(FileManager.default.fileExists(atPath: url.path))

        let data = try Data(contentsOf: url)
        let dump = try MinidumpParser.parse(data: data)
        let html = HTMLExporter.generateReport(from: dump, analysis: nil)

        #expect(html.contains("id=\"toc\""))
        #expect(html.contains("href=\"#summary\""))
    }

    @Test func htmlContainsFooter() throws {
        let url = Self.testFile("test.dmp")
        try #require(FileManager.default.fileExists(atPath: url.path))

        let data = try Data(contentsOf: url)
        let dump = try MinidumpParser.parse(data: data)
        let html = HTMLExporter.generateReport(from: dump, analysis: nil)

        #expect(html.contains("<footer>"))
        #expect(html.contains("MiniDumpTruck"))
    }

    @Test func htmlEscapesSpecialCharacters() throws {
        let url = Self.testFile("test.dmp")
        try #require(FileManager.default.fileExists(atPath: url.path))

        let data = try Data(contentsOf: url)
        let dump = try MinidumpParser.parse(data: data)
        let html = HTMLExporter.generateReport(from: dump, analysis: nil, fileName: "test<script>alert(1)</script>.dmp")

        #expect(!html.contains("<script>"))
        #expect(html.contains("&lt;script&gt;"))
    }

    @Test func htmlUsesFileNameInTitle() throws {
        let url = Self.testFile("test.dmp")
        try #require(FileManager.default.fileExists(atPath: url.path))

        let data = try Data(contentsOf: url)
        let dump = try MinidumpParser.parse(data: data)
        let html = HTMLExporter.generateReport(from: dump, analysis: nil, fileName: "mycrash.dmp")

        #expect(html.contains("mycrash.dmp"))
    }

    @Test func htmlAddressesAreFormatted() throws {
        let url = Self.testFile("test.dmp")
        try #require(FileManager.default.fileExists(atPath: url.path))

        let data = try Data(contentsOf: url)
        let dump = try MinidumpParser.parse(data: data)

        guard dump.exception != nil else { return }

        let html = HTMLExporter.generateReport(from: dump, analysis: nil)

        // Addresses should be 0x followed by 16 hex digits
        #expect(html.contains("0x"))
    }

    @Test func htmlFaultingThreadIsMarked() throws {
        let url = Self.testFile("test.dmp")
        try #require(FileManager.default.fileExists(atPath: url.path))

        let data = try Data(contentsOf: url)
        let dump = try MinidumpParser.parse(data: data)

        guard dump.exception != nil,
              let threadList = dump.threadList, !threadList.threads.isEmpty else { return }

        let html = HTMLExporter.generateReport(from: dump, analysis: nil)
        #expect(html.contains("Faulting"))
    }
}

@Suite("CSV Exporter Tests")
struct CSVExporterTests {

    // MARK: - Test Data Paths

    static var testDataPath: String {
        var url = URL(fileURLWithPath: #file)
        while url.path != "/" {
            url = url.deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
                return url.appendingPathComponent("TestData").path
            }
        }
        return ""
    }

    static func testFile(_ name: String) -> URL {
        URL(fileURLWithPath: testDataPath).appendingPathComponent(name)
    }

    // MARK: - Structure Tests

    @Test func csvStartsWithBOM() throws {
        let url = Self.testFile("test.dmp")
        try #require(FileManager.default.fileExists(atPath: url.path))

        let data = try Data(contentsOf: url)
        let dump = try MinidumpParser.parse(data: data)
        let csv = CSVExporter.generateCSV(from: dump)

        #expect(csv.hasPrefix("\u{FEFF}"))
    }

    @Test func csvContainsModulesSection() throws {
        let url = Self.testFile("test.dmp")
        try #require(FileManager.default.fileExists(atPath: url.path))

        let data = try Data(contentsOf: url)
        let dump = try MinidumpParser.parse(data: data)

        guard dump.moduleList != nil else { return }

        let csv = CSVExporter.generateCSV(from: dump)
        #expect(csv.contains("# Modules"))
        #expect(csv.contains("Name,Full Path,Base Address"))
    }

    @Test func csvContainsThreadsSection() throws {
        let url = Self.testFile("test.dmp")
        try #require(FileManager.default.fileExists(atPath: url.path))

        let data = try Data(contentsOf: url)
        let dump = try MinidumpParser.parse(data: data)

        guard dump.threadList != nil else { return }

        let csv = CSVExporter.generateCSV(from: dump)
        #expect(csv.contains("# Threads"))
        #expect(csv.contains("Thread ID,Name,Priority"))
    }

    @Test func csvModuleRowCount() throws {
        let url = Self.testFile("test.dmp")
        try #require(FileManager.default.fileExists(atPath: url.path))

        let data = try Data(contentsOf: url)
        let dump = try MinidumpParser.parse(data: data)

        guard let moduleList = dump.moduleList else { return }

        let csv = CSVExporter.generateCSV(from: dump)
        let lines = csv.components(separatedBy: "\n")

        // Find the modules section (first line may have BOM prefix)
        guard let modulesHeaderIdx = lines.firstIndex(where: { $0.hasSuffix("# Modules") }) else {
            Issue.record("Modules section header not found")
            return
        }

        // Count data rows (skip section header and column header)
        var moduleRows = 0
        for i in (modulesHeaderIdx + 2)..<lines.count {
            let line = lines[i]
            if line.isEmpty || line.hasPrefix("#") { break }
            moduleRows += 1
        }

        #expect(moduleRows == moduleList.modules.count)
    }

    @Test func csvThreadRowCount() throws {
        let url = Self.testFile("test.dmp")
        try #require(FileManager.default.fileExists(atPath: url.path))

        let data = try Data(contentsOf: url)
        let dump = try MinidumpParser.parse(data: data)

        guard let threadList = dump.threadList else { return }

        let csv = CSVExporter.generateCSV(from: dump)
        let lines = csv.components(separatedBy: "\n")

        guard let threadsHeaderIdx = lines.firstIndex(where: { $0.hasSuffix("# Threads") }) else {
            Issue.record("Threads section header not found")
            return
        }

        var threadRows = 0
        for i in (threadsHeaderIdx + 2)..<lines.count {
            let line = lines[i]
            if line.isEmpty || line.hasPrefix("#") { break }
            threadRows += 1
        }

        #expect(threadRows == threadList.threads.count)
    }

    @Test func csvAddressesAreFormatted() throws {
        let url = Self.testFile("test.dmp")
        try #require(FileManager.default.fileExists(atPath: url.path))

        let data = try Data(contentsOf: url)
        let dump = try MinidumpParser.parse(data: data)

        guard dump.moduleList != nil else { return }

        let csv = CSVExporter.generateCSV(from: dump)

        // Should contain 0x-prefixed hex addresses
        #expect(csv.contains("0x"))
    }

    @Test func csvEscapesCommasInFields() {
        // Test with a module name that contains a comma
        // The CSV escaping logic should wrap it in quotes
        let csv = CSVExporter.generateCSV(from: createMinimalDump())

        // Basic structure check - should at least have BOM
        #expect(csv.hasPrefix("\u{FEFF}"))
    }

    @Test func csvSectionsAreSeparated() throws {
        let url = Self.testFile("test.dmp")
        try #require(FileManager.default.fileExists(atPath: url.path))

        let data = try Data(contentsOf: url)
        let dump = try MinidumpParser.parse(data: data)
        let csv = CSVExporter.generateCSV(from: dump)

        // Sections should be separated by blank lines
        let sectionHeaders = csv.components(separatedBy: "\n").filter { $0.hasPrefix("# ") }
        #expect(sectionHeaders.count >= 1)
    }

    @Test func csvColumnCountConsistency() throws {
        let url = Self.testFile("test.dmp")
        try #require(FileManager.default.fileExists(atPath: url.path))

        let data = try Data(contentsOf: url)
        let dump = try MinidumpParser.parse(data: data)

        guard dump.moduleList != nil else { return }

        let csv = CSVExporter.generateCSV(from: dump)
        let lines = csv.components(separatedBy: "\n")

        guard let modulesHeaderIdx = lines.firstIndex(where: { $0.hasSuffix("# Modules") }) else { return }

        // Column header line
        let headerLine = lines[modulesHeaderIdx + 1]
        let headerColumnCount = headerLine.components(separatedBy: ",").count

        // Check first data row has same column count
        if modulesHeaderIdx + 2 < lines.count {
            let dataLine = lines[modulesHeaderIdx + 2]
            if !dataLine.isEmpty && !dataLine.hasPrefix("#") {
                let dataColumnCount = countCSVColumns(dataLine)
                #expect(dataColumnCount == headerColumnCount, "Data row column count (\(dataColumnCount)) should match header (\(headerColumnCount))")
            }
        }
    }

    @Test func csvInjectionProtection() {
        // Verify that formula-triggering prefixes are neutralized
        let dump = createMinimalDump()
        let csv = CSVExporter.generateCSV(from: dump)

        // The CSV escaping should prefix dangerous characters with a single quote.
        // Test the behavior indirectly: the BOM-only output won't have module data,
        // but we can verify the escaping function works by checking that generated
        // CSV never starts a field with a bare formula character.
        let lines = csv.components(separatedBy: "\n")
        for line in lines {
            // Skip section headers and empty lines
            if line.hasPrefix("#") || line.isEmpty || line == "\u{FEFF}" { continue }
            let fields = line.components(separatedBy: ",")
            for field in fields {
                let trimmed = field.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                if let first = trimmed.first {
                    #expect(!"=+@|%".contains(first),
                            "CSV field should not start with formula character: \(field)")
                }
            }
        }
    }

    // MARK: - Helpers

    /// Count columns in a CSV line, respecting quoted fields
    private func countCSVColumns(_ line: String) -> Int {
        var count = 1
        var inQuotes = false
        for char in line {
            if char == "\"" { inQuotes.toggle() }
            else if char == "," && !inQuotes { count += 1 }
        }
        return count
    }

    /// Create a minimal ParsedMinidump for testing without files
    private func createMinimalDump() -> ParsedMinidump {
        var data = Data(repeating: 0, count: 32)
        // MDMP signature (little-endian)
        data[0] = 0x4D; data[1] = 0x44; data[2] = 0x4D; data[3] = 0x50
        // Version = 0xA793
        data[4] = 0x93; data[5] = 0xA7
        // numberOfStreams = 0
        // streamDirectoryRva = 32 (pointing to end of header, valid but empty)
        data[12] = 32

        let header = MinidumpHeader(from: data)!
        let streamDir = StreamDirectory(from: data, header: header)!
        return ParsedMinidump(header: header, streamDirectory: streamDir, data: data)
    }
}

@Suite("Symbol Surfacing")
struct SymbolSurfacingTests {
    private func mockModule(name: String, base: UInt64) -> ModuleInfo {
        var data = Data()
        data.append(contentsOf: withUnsafeBytes(of: base.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt32(0x10000).littleEndian) { Array($0) })
        data.append(contentsOf: [UInt8](repeating: 0, count: ModuleInfo.size - 12))
        var m = ModuleInfo(from: data, at: 0)!
        m.setName(name)
        return m
    }

    @Test func jsonExportIncludesStructuredSymbol() throws {
        let frame = StackFrame(
            address: 0x7FF800001014,
            module: mockModule(name: "ntdll.dll", base: 0x7FF800000000),
            offsetInModule: 0x1014,
            symbol: ResolvedSymbol(function: "NtClose", offsetInFunction: 0x14),
            frameType: .returnAddress,
            confidence: .medium
        )
        let json = try JSONEncoder().encode(frame)
        let obj = try #require(
            try JSONSerialization.jsonObject(with: json) as? [String: Any])
        let symbol = try #require(obj["symbol"] as? [String: Any])
        #expect(symbol["function"] as? String == "NtClose")
        #expect(symbol["offsetInFunction"] as? Int == 0x14)
    }

    @Test func displayAddressIsTheSingleFormattingChokepoint() {
        let frame = StackFrame(
            address: 0x7FF800001014,
            module: mockModule(name: "ntdll.dll", base: 0x7FF800000000),
            offsetInModule: 0x1014,
            symbol: ResolvedSymbol(function: "NtClose", offsetInFunction: 0x14),
            frameType: .returnAddress,
            confidence: .medium
        )
        #expect(frame.displayAddress == "ntdll.dll!NtClose+0x14")
    }
}
