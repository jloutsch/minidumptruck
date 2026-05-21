import Foundation
import Testing
@testable import MiniDumpTruckCore

@Suite("BatchAnalyzer Tests")
struct BatchAnalyzerTests {

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

    private static func isSuccess(_ result: BatchResult) -> Bool {
        if case .success = result.outcome { return true }
        return false
    }

    private static func isFailure(_ result: BatchResult) -> Bool {
        if case .failure = result.outcome { return true }
        return false
    }

    // MARK: - Single File Tests

    @Test func analyzeSingleFile() async throws {
        let url = Self.testFile("test.dmp")
        try #require(FileManager.default.fileExists(atPath: url.path))

        let (results, summary) = await BatchAnalyzer.analyze(files: [url])

        #expect(results.count == 1)
        #expect(summary.totalFiles == 1)
        #expect(summary.successfulParses == 1)
        #expect(summary.failedParses == 0)
    }

    @Test func resultContainsFileName() async throws {
        let url = Self.testFile("test.dmp")
        try #require(FileManager.default.fileExists(atPath: url.path))

        let (results, _) = await BatchAnalyzer.analyze(files: [url])

        #expect(results.first?.fileName == "test.dmp")
    }

    @Test func resultContainsParsedDump() async throws {
        let url = Self.testFile("test.dmp")
        try #require(FileManager.default.fileExists(atPath: url.path))

        let (results, _) = await BatchAnalyzer.analyze(files: [url])

        let result = try #require(results.first)
        guard case .success(let dump, _) = result.outcome else {
            Issue.record("expected success outcome")
            return
        }
        #expect(dump.streamDirectory.entries.count > 0)
    }

    @Test func resultContainsAnalysis() async throws {
        let url = Self.testFile("test.dmp")
        try #require(FileManager.default.fileExists(atPath: url.path))

        let (results, _) = await BatchAnalyzer.analyze(files: [url])

        let result = try #require(results.first)
        guard case .success(let dump, let analysis) = result.outcome else {
            Issue.record("expected success outcome")
            return
        }
        // Analysis may be nil if no exception is present
        if dump.exception != nil {
            #expect(analysis != nil)
        }
    }

    // MARK: - Multiple Files

    @Test func analyzeMultipleFiles() async throws {
        let testDir = URL(fileURLWithPath: Self.testDataPath)
        try #require(FileManager.default.fileExists(atPath: testDir.path))

        let contents = try FileManager.default.contentsOfDirectory(at: testDir, includingPropertiesForKeys: nil)
        let dmpFiles = contents.filter { $0.pathExtension.lowercased() == "dmp" }
        try #require(!dmpFiles.isEmpty)

        let (results, summary) = await BatchAnalyzer.analyze(files: dmpFiles)

        #expect(results.count == dmpFiles.count)
        #expect(summary.totalFiles == dmpFiles.count)
        let parsed = results.filter(Self.isSuccess).count
        #expect(parsed > 0, "expected at least one fixture .dmp to parse successfully")
        #expect(summary.successfulParses == parsed)
        #expect(summary.failedParses == dmpFiles.count - parsed)
    }

    // MARK: - Invalid Files

    @Test func invalidFileProducesErrorResult() async throws {
        let fakeFile = URL(fileURLWithPath: "/tmp/nonexistent_minidump_test_\(UUID().uuidString).dmp")
        let (results, summary) = await BatchAnalyzer.analyze(files: [fakeFile])

        #expect(results.count == 1)
        let result = try #require(results.first)
        #expect(result.fileName == fakeFile.lastPathComponent)
        guard case .failure(let reason) = result.outcome else {
            Issue.record("expected failure outcome")
            return
        }
        #expect(!reason.isEmpty)
        #expect(summary.totalFiles == 1)
        #expect(summary.failedParses == 1)
        #expect(summary.successfulParses == 0)
    }

    @Test func mixedBatchPreservesBothSuccessAndFailure() async throws {
        let good = Self.testFile("test.dmp")
        try #require(FileManager.default.fileExists(atPath: good.path))
        let bad = URL(fileURLWithPath: "/tmp/nonexistent_minidump_test_\(UUID().uuidString).dmp")

        let (results, summary) = await BatchAnalyzer.analyze(files: [good, bad])

        #expect(results.count == 2)
        #expect(summary.totalFiles == 2)
        #expect(summary.successfulParses == 1)
        #expect(summary.failedParses == 1)

        let badResult = try #require(results.first { $0.fileName == bad.lastPathComponent })
        guard case .failure(let reason) = badResult.outcome else {
            Issue.record("expected failure outcome for bad file")
            return
        }
        #expect(!reason.isEmpty)

        let goodResult = try #require(results.first { $0.fileName == good.lastPathComponent })
        #expect(Self.isSuccess(goodResult))
    }

    @Test func corruptFileProducesErrorResult() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("batch-corrupt-\(UUID().uuidString).dmp")
        try Data(repeating: 0x41, count: 64).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let (results, summary) = await BatchAnalyzer.analyze(files: [tmp])

        #expect(results.count == 1)
        let result = try #require(results.first)
        guard case .failure(let reason) = result.outcome else {
            Issue.record("expected failure outcome for corrupt file")
            return
        }
        #expect(!reason.isEmpty)
        #expect(summary.failedParses == 1)
        #expect(summary.successfulParses == 0)
    }

    @Test func concurrencyThrottlingWithMixedOutcomes() async throws {
        let good = Self.testFile("test.dmp")
        try #require(FileManager.default.fileExists(atPath: good.path))
        let bad1 = URL(fileURLWithPath: "/tmp/missing-a-\(UUID().uuidString).dmp")
        let bad2 = URL(fileURLWithPath: "/tmp/missing-b-\(UUID().uuidString).dmp")

        // 5 files, maxConcurrency=2: exercises the seed-then-drain refill path
        // with failures arriving while other tasks are still running.
        let files = [good, bad1, good, bad2, good]
        let (results, summary) = await BatchAnalyzer.analyze(files: files, maxConcurrency: 2)

        #expect(results.count == 5)
        #expect(summary.successfulParses == 3)
        #expect(summary.failedParses == 2)
    }

    // MARK: - Summary Tests

    @Test func summaryCountsCrashes() async throws {
        let url = Self.testFile("test.dmp")
        try #require(FileManager.default.fileExists(atPath: url.path))

        let (results, summary) = await BatchAnalyzer.analyze(files: [url])

        let first = try #require(results.first)
        var hasCrash = false
        if case .success(let dump, _) = first.outcome, dump.exception != nil {
            hasCrash = true
        }
        if hasCrash {
            #expect(summary.crashesDetected > 0)
        } else {
            #expect(summary.crashesDetected == 0)
        }
    }

    @Test func summaryDescription() async throws {
        let url = Self.testFile("test.dmp")
        try #require(FileManager.default.fileExists(atPath: url.path))

        let (_, summary) = await BatchAnalyzer.analyze(files: [url])

        let desc = summary.description
        #expect(desc.contains("Batch Analysis Summary"))
        #expect(desc.contains("Total files:"))
        #expect(desc.contains("Successfully parsed:"))
        #expect(desc.contains("Failed to parse:"))
        #expect(desc.contains("Crashes detected:"))
    }

    @Test func summaryTracksExceptionCodes() async throws {
        let url = Self.testFile("test.dmp")
        try #require(FileManager.default.fileExists(atPath: url.path))

        let data = try Data(contentsOf: url)
        let dump = try MinidumpParser.parse(data: data)

        guard dump.exception != nil else { return }

        let (_, summary) = await BatchAnalyzer.analyze(files: [url])
        #expect(!summary.topExceptionCodes.isEmpty)
    }

    // MARK: - Concurrency Tests

    @Test func respectsMaxConcurrency() async throws {
        let url = Self.testFile("test.dmp")
        try #require(FileManager.default.fileExists(atPath: url.path))

        // Run with concurrency of 1
        let (results, summary) = await BatchAnalyzer.analyze(files: [url, url, url], maxConcurrency: 1)

        #expect(results.count == 3)
        #expect(summary.totalFiles == 3)
    }

    // MARK: - Progress Callback

    @Test func progressCallbackIsCalled() async throws {
        let url = Self.testFile("test.dmp")
        try #require(FileManager.default.fileExists(atPath: url.path))

        final class ProgressTracker: Sendable {
            private let lock = NSLock()
            private let _values: UnsafeMutablePointer<[(Int, Int)]>

            init() {
                _values = .allocate(capacity: 1)
                _values.initialize(to: [])
            }

            deinit { _values.deallocate() }

            func record(_ completed: Int, _ total: Int) {
                lock.lock()
                _values.pointee.append((completed, total))
                lock.unlock()
            }

            var values: [(Int, Int)] {
                lock.lock()
                defer { lock.unlock() }
                return _values.pointee
            }
        }

        let tracker = ProgressTracker()

        let (_, _) = await BatchAnalyzer.analyze(files: [url, url]) { completed, total in
            tracker.record(completed, total)
        }

        #expect(tracker.values.count == 2)
        // All callbacks should report total = 2
        for (_, total) in tracker.values {
            #expect(total == 2)
        }
    }

    // MARK: - Empty Input

    @Test func emptyFileList() async {
        let (results, summary) = await BatchAnalyzer.analyze(files: [])

        #expect(results.isEmpty)
        #expect(summary.totalFiles == 0)
        #expect(summary.successfulParses == 0)
        #expect(summary.failedParses == 0)
        #expect(summary.crashesDetected == 0)
    }
}
