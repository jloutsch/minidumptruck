import Foundation
import Testing
@testable import MiniDumpTruckCore

@Suite("JSONExporter Tests")
struct JSONExporterTests {

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

    // MARK: - JSON Structure Tests

    @Test func jsonIsValidJSON() throws {
        let url = Self.testFile("test.dmp")
        try #require(FileManager.default.fileExists(atPath: url.path))

        let data = try Data(contentsOf: url)
        let dump = try MinidumpParser.parse(data: data)
        let json = JSONExporter.generateJSON(from: dump, analysis: nil)

        let parsed = try JSONSerialization.jsonObject(with: Data(json.utf8))
        #expect(parsed is [String: Any])
    }

    @Test func jsonContainsFileName() throws {
        let url = Self.testFile("test.dmp")
        try #require(FileManager.default.fileExists(atPath: url.path))

        let data = try Data(contentsOf: url)
        let dump = try MinidumpParser.parse(data: data)
        let json = JSONExporter.generateJSON(from: dump, analysis: nil, fileName: "mycrash.dmp")

        #expect(json.contains("mycrash.dmp"))
    }

    @Test func jsonContainsHeader() throws {
        let url = Self.testFile("test.dmp")
        try #require(FileManager.default.fileExists(atPath: url.path))

        let data = try Data(contentsOf: url)
        let dump = try MinidumpParser.parse(data: data)
        let json = JSONExporter.generateJSON(from: dump, analysis: nil)

        let parsed = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        #expect(parsed["header"] != nil)
    }

    @Test func jsonContainsSystemInfo() throws {
        let url = Self.testFile("test.dmp")
        try #require(FileManager.default.fileExists(atPath: url.path))

        let data = try Data(contentsOf: url)
        let dump = try MinidumpParser.parse(data: data)

        guard dump.systemInfo != nil else { return }

        let json = JSONExporter.generateJSON(from: dump, analysis: nil)
        let parsed = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        #expect(parsed["systemInfo"] != nil)
    }

    @Test func jsonContainsModules() throws {
        let url = Self.testFile("test.dmp")
        try #require(FileManager.default.fileExists(atPath: url.path))

        let data = try Data(contentsOf: url)
        let dump = try MinidumpParser.parse(data: data)

        guard dump.moduleList != nil else { return }

        let json = JSONExporter.generateJSON(from: dump, analysis: nil)
        let parsed = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        let modules = parsed["modules"] as? [[String: Any]]
        #expect(modules != nil)
        #expect(modules!.count > 0)
    }

    @Test func jsonContainsThreads() throws {
        let url = Self.testFile("test.dmp")
        try #require(FileManager.default.fileExists(atPath: url.path))

        let data = try Data(contentsOf: url)
        let dump = try MinidumpParser.parse(data: data)

        guard dump.threadList != nil else { return }

        let json = JSONExporter.generateJSON(from: dump, analysis: nil)
        let parsed = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        let threads = parsed["threads"] as? [[String: Any]]
        #expect(threads != nil)
        #expect(threads!.count > 0)
    }

    @Test func jsonContainsAnalysis() throws {
        let url = Self.testFile("test.dmp")
        try #require(FileManager.default.fileExists(atPath: url.path))

        let data = try Data(contentsOf: url)
        let dump = try MinidumpParser.parse(data: data)
        let analysis = CrashAnalyzer(dump: dump).analyze()

        let json = JSONExporter.generateJSON(from: dump, analysis: analysis)
        let parsed = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]

        if analysis != nil {
            #expect(parsed["analysis"] != nil)
        }
    }

    @Test func jsonExcludesRawData() throws {
        let url = Self.testFile("test.dmp")
        try #require(FileManager.default.fileExists(atPath: url.path))

        let data = try Data(contentsOf: url)
        let dump = try MinidumpParser.parse(data: data)
        let json = JSONExporter.generateJSON(from: dump, analysis: nil)

        // ExportableReport should not include a "data" key with raw binary
        let parsed = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        #expect(parsed["data"] == nil)
    }

    @Test func jsonPrettyPrintIsFormatted() throws {
        let url = Self.testFile("test.dmp")
        try #require(FileManager.default.fileExists(atPath: url.path))

        let data = try Data(contentsOf: url)
        let dump = try MinidumpParser.parse(data: data)

        let pretty = JSONExporter.generateJSON(from: dump, analysis: nil, prettyPrint: true)
        let compact = JSONExporter.generateJSON(from: dump, analysis: nil, prettyPrint: false)

        // Pretty print should be longer due to whitespace
        #expect(pretty.count > compact.count)
        // Pretty print should contain newlines
        #expect(pretty.contains("\n"))
    }

    @Test func jsonRoundTripsViaDecoder() throws {
        let url = Self.testFile("test.dmp")
        try #require(FileManager.default.fileExists(atPath: url.path))

        let data = try Data(contentsOf: url)
        let dump = try MinidumpParser.parse(data: data)
        let analysis = CrashAnalyzer(dump: dump).analyze()

        let json = JSONExporter.generateJSON(from: dump, analysis: analysis)

        // Should be decodable back to ExportableReport
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ExportableReport.self, from: Data(json.utf8))

        #expect(decoded.fileName == "Minidump")
        #expect(decoded.header.version == dump.header.version)
    }

    @Test func jsonWithMinimalDump() {
        let dump = createMinimalDump()
        let json = JSONExporter.generateJSON(from: dump, analysis: nil)

        #expect(!json.isEmpty)
        #expect(json != "{}")

        // Should be valid JSON
        let parsed = try? JSONSerialization.jsonObject(with: Data(json.utf8))
        #expect(parsed != nil)
    }

    @Test func jsonContainsParseWarnings() throws {
        let url = Self.testFile("test.dmp")
        try #require(FileManager.default.fileExists(atPath: url.path))

        let data = try Data(contentsOf: url)
        let dump = try MinidumpParser.parse(data: data)
        let json = JSONExporter.generateJSON(from: dump, analysis: nil)

        let parsed = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        // parseWarnings should always be present (may be empty array)
        #expect(parsed["parseWarnings"] != nil)
    }

    // MARK: - Helpers

    private func createMinimalDump() -> ParsedMinidump {
        var data = Data(repeating: 0, count: 32)
        data[0] = 0x4D; data[1] = 0x44; data[2] = 0x4D; data[3] = 0x50
        data[4] = 0x93; data[5] = 0xA7
        data[12] = 32
        let header = MinidumpHeader(from: data)!
        let streamDir = StreamDirectory(from: data, header: header)!
        return ParsedMinidump(header: header, streamDirectory: streamDir, data: data)
    }
}
