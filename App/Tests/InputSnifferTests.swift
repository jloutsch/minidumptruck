import Foundation
import Testing
@testable import MiniDumpTruckCore

@Suite("InputSniffer")
struct InputSnifferTests {
    @Test func detectsMinidumpFromData() {
        // "MDMP" in little-endian byte order
        let data = Data([0x4D, 0x44, 0x4D, 0x50, 0xAA, 0xBB])
        #expect(InputSniffer.detect(from: data) == .minidump)
    }

    @Test func detectsZipFromData() {
        // PK\x03\x04 (local file header signature)
        let data = Data([0x50, 0x4B, 0x03, 0x04, 0x14, 0x00])
        #expect(InputSniffer.detect(from: data) == .zip)
    }

    @Test func emptyDataIsUnsupported() {
        let result = InputSniffer.detect(from: Data())
        if case .unsupported(let bytes) = result {
            #expect(bytes.isEmpty)
        } else {
            Issue.record("Expected .unsupported, got \(result)")
        }
    }

    @Test func shortDataIsUnsupported() {
        let result = InputSniffer.detect(from: Data([0x4D, 0x44]))
        if case .unsupported(let bytes) = result {
            #expect(bytes == [0x4D, 0x44])
        } else {
            Issue.record("Expected .unsupported, got \(result)")
        }
    }

    @Test func arbitraryBytesAreUnsupported() {
        let data = Data([0x7F, 0x45, 0x4C, 0x46])  // ELF magic
        let result = InputSniffer.detect(from: data)
        if case .unsupported(let bytes) = result {
            #expect(bytes == [0x7F, 0x45, 0x4C, 0x46])
        } else {
            Issue.record("Expected .unsupported, got \(result)")
        }
    }

    @Test func detectAtUrlReadsOnlyFourBytes() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sniffer-test-\(UUID().uuidString).bin")
        // 10 MB file with MDMP prefix + garbage
        var data = Data([0x4D, 0x44, 0x4D, 0x50])
        data.append(Data(repeating: 0xCC, count: 10_000_000))
        try data.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let kind = try InputSniffer.detect(at: tmp)
        #expect(kind == .minidump)
    }

    @Test func detectAtUrlReturnsUnsupportedForTinyFile() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sniffer-tiny-\(UUID().uuidString).bin")
        try Data([0x00, 0x01]).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let kind = try InputSniffer.detect(at: tmp)
        if case .unsupported(let bytes) = kind {
            #expect(bytes == [0x00, 0x01])
        } else {
            Issue.record("Expected .unsupported, got \(kind)")
        }
    }

    @Test func detectAtUrlReturnsUnsupportedForEmptyFile() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sniffer-empty-\(UUID().uuidString).bin")
        try Data().write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let kind = try InputSniffer.detect(at: tmp)
        if case .unsupported(let bytes) = kind {
            #expect(bytes.isEmpty)
        } else {
            Issue.record("Expected .unsupported, got \(kind)")
        }
    }
}
