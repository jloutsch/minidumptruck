import Foundation
import Testing
@testable import MiniDumpTruckCore

@Suite("VerdictState")
struct VerdictStateTests {

    // MARK: - Test data helpers

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

    static func loadDump(_ name: String) throws -> ParsedMinidump {
        let url = URL(fileURLWithPath: testDataPath).appendingPathComponent(name)
        try #require(FileManager.default.fileExists(atPath: url.path))
        let data = try Data(contentsOf: url)
        return try MinidumpParser.parse(data: data)
    }

    // MARK: - Precedence tests (no payload needed — use kind)

    @Test func analyzingTakesPrecedenceOverEverything() throws {
        let dump = try Self.loadDump("test.dmp")
        let analysis = try #require(CrashAnalyzer(dump: dump).analyze())

        let state = VerdictState.from(
            isAnalyzing: true,
            analysis: analysis,
            exception: dump.exception,
            hasParseWarnings: true
        )
        #expect(state.kind == .analyzing)
    }

    @Test func analyzedWhenAnalysisAvailable() throws {
        let dump = try Self.loadDump("test.dmp")
        let analysis = try #require(CrashAnalyzer(dump: dump).analyze())

        let state = VerdictState.from(
            isAnalyzing: false,
            analysis: analysis,
            exception: dump.exception,
            // Warnings ignored once we have a real verdict.
            hasParseWarnings: true
        )
        #expect(state.kind == .analyzed)
        guard case .analyzed(let payload) = state else {
            Issue.record("expected .analyzed, got \(state)")
            return
        }
        #expect(payload.confidence == analysis.confidence)
    }

    @Test func exceptionPendingWhenExceptionButNoAnalysis() throws {
        let dump = try Self.loadDump("test.dmp")
        let exception = try #require(dump.exception)

        let state = VerdictState.from(
            isAnalyzing: false,
            analysis: nil,
            exception: exception,
            hasParseWarnings: false
        )
        #expect(state.kind == .exceptionPending)
        guard case .exceptionPending(let payload) = state else {
            Issue.record("expected .exceptionPending, got \(state)")
            return
        }
        #expect(payload.exceptionCode == exception.exceptionCode)
    }

    @Test func noExceptionWhenCleanDump() {
        let state = VerdictState.from(
            isAnalyzing: false,
            analysis: nil,
            exception: nil,
            hasParseWarnings: false
        )
        #expect(state.kind == .noException)
    }

    @Test func indeterminateWhenNoExceptionButWarningsPresent() {
        // The confidence-trap fix: parse warnings mean we can't safely
        // claim "no exception" — surface uncertainty instead.
        let state = VerdictState.from(
            isAnalyzing: false,
            analysis: nil,
            exception: nil,
            hasParseWarnings: true
        )
        #expect(state.kind == .indeterminate)
    }
}
