import Foundation
import Testing
@testable import MiniDumpTruckCore

@Suite("Integration Tests")
struct IntegrationTests {

    // MARK: - Test Data Paths

    /// Get path to TestData directory
    static var testDataPath: String {
        // Find the package root by looking for Package.swift
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

    // MARK: - Basic Parsing Tests

    @Test func parseTestDmp() throws {
        let url = Self.testFile("test.dmp")
        guard FileManager.default.fileExists(atPath: url.path) else {
            Issue.record("Test file not found: \(url.path)")
            return
        }

        let data = try Data(contentsOf: url)
        let dump = try MinidumpParser.parse(data: data)

        // If parsing succeeded, signature was valid
        #expect(dump.streamDirectory.entries.count > 0)
    }

    @Test func parseFullDump() throws {
        let url = Self.testFile("full-dump.dmp")
        guard FileManager.default.fileExists(atPath: url.path) else {
            Issue.record("Test file not found: \(url.path)")
            return
        }

        let data = try Data(contentsOf: url)
        let dump = try MinidumpParser.parse(data: data)

        // Full dumps should have memory data
        #expect(dump.memory64List != nil || dump.streamDirectory.entries.contains { $0.type == .memoryList })
    }

    @Test func parseLinuxMini() throws {
        let url = Self.testFile("linux-mini.dmp")
        guard FileManager.default.fileExists(atPath: url.path) else {
            Issue.record("Test file not found: \(url.path)")
            return
        }

        let data = try Data(contentsOf: url)
        let dump = try MinidumpParser.parse(data: data)

        // Linux minidumps should have system info
        #expect(dump.systemInfo != nil)
    }

    @Test func parseSimpleCrashpad() throws {
        let url = Self.testFile("simple-crashpad.dmp")
        guard FileManager.default.fileExists(atPath: url.path) else {
            Issue.record("Test file not found: \(url.path)")
            return
        }

        let data = try Data(contentsOf: url)
        let dump = try MinidumpParser.parse(data: data)

        #expect(dump.streamDirectory.entries.count > 0)
    }

    @Test func parseMacosSegv() throws {
        let url = Self.testFile("pipeline-inlines-macos-segv.dmp")
        guard FileManager.default.fileExists(atPath: url.path) else {
            Issue.record("Test file not found: \(url.path)")
            return
        }

        let data = try Data(contentsOf: url)
        let dump = try MinidumpParser.parse(data: data)

        // macOS SEGV should have exception info
        #expect(dump.exception != nil)
    }

    // MARK: - Invalid File Tests

    @Test func parseInvalidParameter() throws {
        let url = Self.testFile("invalid-parameter.dmp")
        guard FileManager.default.fileExists(atPath: url.path) else {
            Issue.record("Test file not found: \(url.path)")
            return
        }

        let data = try Data(contentsOf: url)
        // This file has valid header but may have issues in streams
        // Just verify it doesn't crash during parsing
        _ = try? MinidumpParser.parse(data: data)
    }

    @Test func parseInvalidRange() throws {
        let url = Self.testFile("invalid-range.dmp")
        guard FileManager.default.fileExists(atPath: url.path) else {
            Issue.record("Test file not found: \(url.path)")
            return
        }

        let data = try Data(contentsOf: url)
        // This file has invalid range data - should handle gracefully
        _ = try? MinidumpParser.parse(data: data)
    }

    @Test func parseInvalidRecordCount() throws {
        let url = Self.testFile("invalid-record-count.dmp")
        guard FileManager.default.fileExists(atPath: url.path) else {
            Issue.record("Test file not found: \(url.path)")
            return
        }

        let data = try Data(contentsOf: url)
        // This file has invalid record count - should handle gracefully
        _ = try? MinidumpParser.parse(data: data)
    }

    // MARK: - Stream Content Tests

    @Test func testDumpHasThreads() throws {
        let url = Self.testFile("test.dmp")
        guard FileManager.default.fileExists(atPath: url.path) else {
            Issue.record("Test file not found: \(url.path)")
            return
        }

        let data = try Data(contentsOf: url)
        let dump = try MinidumpParser.parse(data: data)

        #expect(dump.threadList != nil)
        if let threads = dump.threadList {
            #expect(threads.threads.count > 0)
        }
    }

    @Test func testDumpHasModules() throws {
        let url = Self.testFile("test.dmp")
        guard FileManager.default.fileExists(atPath: url.path) else {
            Issue.record("Test file not found: \(url.path)")
            return
        }

        let data = try Data(contentsOf: url)
        let dump = try MinidumpParser.parse(data: data)

        #expect(dump.moduleList != nil)
        if let modules = dump.moduleList {
            #expect(modules.modules.count > 0)
        }
    }

    @Test func testDumpSystemInfo() throws {
        let url = Self.testFile("test.dmp")
        guard FileManager.default.fileExists(atPath: url.path) else {
            Issue.record("Test file not found: \(url.path)")
            return
        }

        let data = try Data(contentsOf: url)
        let dump = try MinidumpParser.parse(data: data)

        #expect(dump.systemInfo != nil)
    }

    // MARK: - Memory Reading Tests

    @Test func testMemoryReading() throws {
        let url = Self.testFile("full-dump.dmp")
        guard FileManager.default.fileExists(atPath: url.path) else {
            Issue.record("Test file not found: \(url.path)")
            return
        }

        let data = try Data(contentsOf: url)
        let dump = try MinidumpParser.parse(data: data)

        guard let memory64 = dump.memory64List,
              let firstRegion = memory64.regions.first else {
            Issue.record("No memory regions in dump")
            return
        }

        // Try to read from the first memory region
        let readData = memory64.readMemory(
            at: firstRegion.baseAddress,
            size: min(64, Int(firstRegion.regionSize)),
            from: dump.data
        )
        #expect(readData != nil)
        #expect(readData?.count ?? 0 > 0)
    }

    // MARK: - Address Resolution Tests

    @Test func testAddressResolution() throws {
        let url = Self.testFile("test.dmp")
        guard FileManager.default.fileExists(atPath: url.path) else {
            Issue.record("Test file not found: \(url.path)")
            return
        }

        let data = try Data(contentsOf: url)
        let dump = try MinidumpParser.parse(data: data)

        guard let modules = dump.moduleList,
              let firstModule = modules.modules.first else {
            Issue.record("No modules in dump")
            return
        }

        // Address in the middle of first module should resolve
        let midAddress = firstModule.baseAddress + UInt64(firstModule.sizeOfImage / 2)
        let resolved = MinidumpParser.resolveAddress(midAddress, in: dump)
        #expect(!resolved.hasPrefix("0x"))  // Should have module name, not just hex
    }

    // MARK: - Full Dump Analysis

    @Test func testFullDumpAnalysis() throws {
        let url = Self.testFile("full-dump.dmp")
        guard FileManager.default.fileExists(atPath: url.path) else {
            Issue.record("Test file not found: \(url.path)")
            return
        }

        let data = try Data(contentsOf: url)
        let dump = try MinidumpParser.parse(data: data)

        // Full dump should have rich information
        #expect(dump.systemInfo != nil)
        #expect(dump.threadList != nil)
        #expect(dump.moduleList != nil)

        // Check we have memory data
        let hasMemory = dump.memory64List != nil ||
                        dump.streamDirectory.entries.contains { $0.type == .memoryList }
        #expect(hasMemory)
    }

    // MARK: - Exception Analysis

    @Test func testExceptionParsing() throws {
        let url = Self.testFile("pipeline-inlines-macos-segv.dmp")
        guard FileManager.default.fileExists(atPath: url.path) else {
            Issue.record("Test file not found: \(url.path)")
            return
        }

        let data = try Data(contentsOf: url)
        let dump = try MinidumpParser.parse(data: data)

        guard let exception = dump.exception else {
            Issue.record("No exception in dump")
            return
        }

        // Exception should have valid thread ID
        #expect(exception.threadId != 0)

        // Should have exception code
        #expect(exception.exceptionCode != 0)
    }
}
