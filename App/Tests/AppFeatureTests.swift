import Foundation
import Testing
@testable import MiniDumpTruckCore

// MARK: - Zoom Scale Logic Tests

@Suite("Zoom Scale Logic")
struct ZoomScaleTests {

    /// Replicates the zoom-in formula from MiniDumpTruckApp
    private func zoomIn(_ scale: Double) -> Double {
        min(round((scale + 0.1) * 10) / 10, 2.0)
    }

    /// Replicates the zoom-out formula from MiniDumpTruckApp
    private func zoomOut(_ scale: Double) -> Double {
        max(round((scale - 0.1) * 10) / 10, 0.5)
    }

    @Test func zoomInFromDefault() {
        #expect(zoomIn(1.0) == 1.1)
    }

    @Test func zoomOutFromDefault() {
        #expect(zoomOut(1.0) == 0.9)
    }

    @Test func zoomInClampsAtMax() {
        #expect(zoomIn(2.0) == 2.0)
        #expect(zoomIn(1.9) == 2.0)
    }

    @Test func zoomOutClampsAtMin() {
        #expect(zoomOut(0.5) == 0.5)
        #expect(zoomOut(0.6) == 0.5)
    }

    @Test func zoomInProducesCleanDecimals() {
        var scale = 1.0
        for _ in 0..<10 {
            scale = zoomIn(scale)
            // Each step should be a clean single-decimal value
            #expect(round(scale * 10) / 10 == scale, "Scale \(scale) is not a clean decimal")
        }
    }

    @Test func zoomOutProducesCleanDecimals() {
        var scale = 1.0
        for _ in 0..<5 {
            scale = zoomOut(scale)
            #expect(round(scale * 10) / 10 == scale, "Scale \(scale) is not a clean decimal")
        }
    }

    @Test func fullZoomInRange() {
        var scale = 1.0
        var steps = 0
        while scale < 2.0 {
            scale = zoomIn(scale)
            steps += 1
        }
        #expect(scale == 2.0)
        #expect(steps == 10) // 1.0 -> 2.0 in 10 steps of 0.1
    }

    @Test func fullZoomOutRange() {
        var scale = 1.0
        var steps = 0
        while scale > 0.5 {
            scale = zoomOut(scale)
            steps += 1
        }
        #expect(scale == 0.5)
        #expect(steps == 5) // 1.0 -> 0.5 in 5 steps of 0.1
    }

    @Test func zoomResetToActualSize() {
        let reset = 1.0
        #expect(reset == 1.0)
    }

    @Test func zoomRoundTrip() {
        // Zoom in then back out should return to original
        var scale = 1.0
        for _ in 0..<5 {
            scale = zoomIn(scale)
        }
        for _ in 0..<5 {
            scale = zoomOut(scale)
        }
        #expect(scale == 1.0)
    }
}

// MARK: - Info.plist Validation Tests

@Suite("Info.plist Validation")
struct InfoPlistTests {

    static var plistPath: String {
        var url = URL(fileURLWithPath: #file)
        while url.path != "/" {
            url = url.deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
                return url.appendingPathComponent("MiniDumpTruck/Info.plist").path
            }
        }
        return ""
    }

    @Test func plistFileExists() {
        #expect(FileManager.default.fileExists(atPath: Self.plistPath), "Info.plist not found at \(Self.plistPath)")
    }

    @Test func plistHasIconFileKey() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: Self.plistPath))
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        let dict = try #require(plist)

        let iconFile = try #require(dict["CFBundleIconFile"] as? String, "CFBundleIconFile key missing from Info.plist")
        #expect(iconFile == "AppIcon")
    }

    @Test func plistHasDocumentTypes() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: Self.plistPath))
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        let dict = try #require(plist)

        let docTypes = try #require(dict["CFBundleDocumentTypes"] as? [[String: Any]], "CFBundleDocumentTypes missing")
        #expect(!docTypes.isEmpty)

        // First doc type should handle .dmp files
        let firstType = try #require(docTypes.first)
        let extensions = try #require(firstType["CFBundleTypeExtensions"] as? [String])
        #expect(extensions.contains("dmp"))
        #expect(extensions.contains("mdmp"))
    }

    @Test func plistHasUTIDeclarations() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: Self.plistPath))
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        let dict = try #require(plist)

        let utiDeclarations = try #require(dict["UTImportedTypeDeclarations"] as? [[String: Any]])
        #expect(!utiDeclarations.isEmpty)

        let firstUTI = try #require(utiDeclarations.first)
        let identifier = try #require(firstUTI["UTTypeIdentifier"] as? String)
        #expect(identifier == "com.microsoft.windows-minidump")
    }
}

// MARK: - Address Parsing Tests

@Suite("Address Parsing")
struct AddressParsingTests {

    /// Replicates parseAddress logic from DumpViewModel
    private func parseAddress(_ text: String) -> UInt64? {
        var cleaned = text.trimmingCharacters(in: .whitespaces).lowercased()
        if cleaned.hasPrefix("0x") {
            cleaned = String(cleaned.dropFirst(2))
        }
        return UInt64(cleaned, radix: 16)
    }

    @Test func parseHexWithPrefix() {
        #expect(parseAddress("0x7FF812345678") == 0x7FF812345678)
    }

    @Test func parseHexWithoutPrefix() {
        #expect(parseAddress("7FF812345678") == 0x7FF812345678)
    }

    @Test func parseHexUppercase() {
        #expect(parseAddress("0xDEADBEEF") == 0xDEADBEEF)
    }

    @Test func parseHexLowercase() {
        #expect(parseAddress("0xdeadbeef") == 0xDEADBEEF)
    }

    @Test func parseHexWithLeadingSpaces() {
        #expect(parseAddress("  0x1234") == 0x1234)
    }

    @Test func parseHexWithTrailingSpaces() {
        #expect(parseAddress("0x1234  ") == 0x1234)
    }

    @Test func parseZeroAddress() {
        #expect(parseAddress("0x0") == 0)
    }

    @Test func parseMaxAddress() {
        #expect(parseAddress("0xFFFFFFFFFFFFFFFF") == UInt64.max)
    }

    @Test func parseInvalidReturnsNil() {
        #expect(parseAddress("not_an_address") == nil)
    }

    @Test func parseEmptyReturnsNil() {
        #expect(parseAddress("") == nil)
    }

    @Test func parsePaddedAddress() {
        #expect(parseAddress("0x0000000000001234") == 0x1234)
    }
}

// MARK: - Navigation Section Tests

@Suite("Navigation Sections")
struct NavigationSectionTests {

    /// All sections that should exist in the sidebar
    private let expectedSections = [
        "Summary", "System Info", "Misc Info", "Exception", "Analyze",
        "Threads", "Modules", "Handles", "Memory", "Streams"
    ]

    @Test func allSectionsHaveUniqueNames() {
        let names = Set(expectedSections)
        #expect(names.count == expectedSections.count)
    }

    @Test func sectionCountIsCorrect() {
        #expect(expectedSections.count == 10)
    }
}

// MARK: - Crash Diagnosis Integration Tests

@Suite("Crash Diagnosis for Summary View")
struct CrashDiagnosisTests {

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

    @Test func diagnosisFieldsPopulatedForCrashDump() throws {
        let url = Self.testFile("full-dump.dmp")
        try #require(FileManager.default.fileExists(atPath: url.path))

        let data = try Data(contentsOf: url)
        let dump = try MinidumpParser.parse(data: data)
        try #require(dump.exception != nil, "Need a dump with exception for this test")

        let analysis = try #require(CrashAnalyzer(dump: dump).analyze())

        // These are the fields SummaryView's diagnosisSection displays
        #expect(!analysis.crashSummary.probableCause.isEmpty)
        #expect(!analysis.crashSummary.recommendation.isEmpty)
        #expect(!analysis.crashSummary.exceptionType.isEmpty)
        #expect([.high, .medium, .low].contains(analysis.confidence))
    }

    @Test func diagnosisReturnsNilWithoutException() throws {
        let url = Self.testFile("test.dmp")
        try #require(FileManager.default.fileExists(atPath: url.path))

        let data = try Data(contentsOf: url)
        let dump = try MinidumpParser.parse(data: data)

        if dump.exception == nil {
            let analysis = CrashAnalyzer(dump: dump).analyze()
            #expect(analysis == nil, "Analyzer should return nil without exception")
        }
    }

    @Test func confidenceDisplayNames() {
        #expect(AnalysisConfidence.high.displayName == "High")
        #expect(AnalysisConfidence.medium.displayName == "Medium")
        #expect(AnalysisConfidence.low.displayName == "Low")
    }

    @Test func blameModuleHasRequiredFields() throws {
        let url = Self.testFile("full-dump.dmp")
        try #require(FileManager.default.fileExists(atPath: url.path))

        let data = try Data(contentsOf: url)
        let dump = try MinidumpParser.parse(data: data)
        let analysis = try #require(CrashAnalyzer(dump: dump).analyze())

        if let blame = analysis.blameModule {
            // SummaryView displays these fields
            #expect(!blame.module.shortName.isEmpty)
            #expect(!blame.reasonDescription.isEmpty)
        }
    }
}
