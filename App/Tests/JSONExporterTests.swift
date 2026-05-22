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
        let dump = makeMinimalDump()
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

    // MARK: - Error fallback

    @Test func errorFallbackProducesValidJsonWithQuotesInMessage() throws {
        // Adversarial error description: contains both a double-quote
        // and a backslash. The old string-interpolation fallback would
        // emit malformed JSON that breaks downstream parsers.
        struct WeirdError: LocalizedError {
            var errorDescription: String? { "broke at \"path\\to\\file\" with \"\\n\" tab" }
        }
        let json = JSONExporter.encodeErrorFallback(WeirdError())

        // Must round-trip through JSONSerialization — proves it's valid.
        let parsed = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        let message = try #require(parsed["error"] as? String)
        #expect(message.contains("path"))
        #expect(message.contains("file"))
    }

    @Test func errorFallbackHandlesControlChars() throws {
        struct CtrlError: LocalizedError {
            var errorDescription: String? { "tab:\there\nnewline:\u{0001}" }
        }
        let json = JSONExporter.encodeErrorFallback(CtrlError())
        // JSONEncoder escapes control chars correctly — round-trip succeeds.
        let parsed = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        #expect(parsed["error"] != nil)
    }

}
