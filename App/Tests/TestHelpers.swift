// Shared test fixtures. Closes the long-standing duplication tracked
// in #10. New tests should pull helpers from here rather than copy-
// pasting inline equivalents. Helpers are file-scope so every file in
// the test target can use them without import gymnastics.

import Foundation
import Testing
@testable import MiniDumpTruckCore

// MARK: - Raw dump bytes

/// Return the smallest valid minidump byte buffer (32-byte header with
/// MDMP signature, 0 streams, empty stream directory at offset 32).
/// Useful for tests that need to exercise the parser entry point.
func makeMinimalMinidumpBytes() -> Data {
    var d = Data(repeating: 0, count: 32)
    func w32(_ v: UInt32, _ o: Int) { for i in 0..<4 { d[o+i] = UInt8((v >> (i*8)) & 0xFF) } }
    func w16(_ v: UInt16, _ o: Int) { d[o] = UInt8(v & 0xFF); d[o+1] = UInt8((v >> 8) & 0xFF) }
    w32(0x504D444D, 0)        // MDMP signature
    w16(0xA793, 4)            // version
    w32(0, 8)                  // numberOfStreams
    w32(32, 12)                // streamDirectoryRva (end of header)
    w32(0, 16)                 // checksum
    w32(1700000000, 20)        // timestamp
    return d
}

// MARK: - Parsed-dump skeleton

/// Return a `ParsedMinidump` skeleton parsed from
/// `makeMinimalMinidumpBytes`. Tests can mutate the var properties
/// (moduleList, threadList, etc.) before passing to exporters or the
/// analyzer. `ParsedMinidump` is a value type, so each call returns a
/// fresh instance — safe to mutate without cross-test contamination.
func makeMinimalDump() -> ParsedMinidump {
    let data = makeMinimalMinidumpBytes()
    let header = MinidumpHeader(from: data)!
    let streamDir = StreamDirectory(from: data, header: header)!
    return ParsedMinidump(header: header, streamDirectory: streamDir, data: data)
}

// MARK: - Mock models

/// Build a `ModuleInfo` with the given name + base + size. Used by
/// exporter, symbolicator, and coverage-gap tests.
///
/// `size: 0x10000` (64 KB) is the default the prior duplicates used —
/// non-zero, arbitrary, and small enough to fit any test setup. Tests
/// asserting module-range coverage should override explicitly.
func makeModule(name: String, base: UInt64, size: UInt32 = 0x10000) -> ModuleInfo {
    var bytes = Data()
    bytes.append(contentsOf: withUnsafeBytes(of: base.littleEndian) { Array($0) })
    bytes.append(contentsOf: withUnsafeBytes(of: size.littleEndian) { Array($0) })
    bytes.append(contentsOf: [UInt8](repeating: 0, count: ModuleInfo.size - 12))
    var m = ModuleInfo(from: bytes, at: 0)!
    m.setName(name)
    return m
}

/// Return a zero-filled but structurally valid `ThreadContext` (RIP,
/// registers, flags all zero). Tests asserting context-shape can use
/// this without round-tripping through a real dump.
func makeZeroContext() -> ThreadContext {
    let buffer = Data(repeating: 0, count: ThreadContext.size)
    guard let ctx = ThreadContext(from: buffer, at: 0) else {
        fatalError("makeZeroContext: zero-buffer init regressed — ThreadContext.init likely tightened validation; update the helper.")
    }
    return ctx
}

// MARK: - Self-validation

/// Pin the contract of the byte-layout helpers. If parser-side
/// validation tightens (e.g., a new required field), this test fails
/// first with one clear diagnostic — instead of every consumer of the
/// helpers failing simultaneously with cryptic downstream errors.
@Suite("TestHelpers self-validation")
struct TestHelpersSelfValidation {
    @Test func minimalBytesParseSuccessfully() throws {
        let bytes = makeMinimalMinidumpBytes()
        let dump = try MinidumpParser.parse(data: bytes)
        #expect(dump.streamDirectory.entries.isEmpty)
    }

    @Test func minimalDumpSkeletonShape() {
        let dump = makeMinimalDump()
        #expect(dump.streamDirectory.entries.isEmpty)
        #expect(dump.moduleList == nil)
        #expect(dump.threadList == nil)
    }

    @Test func makeModuleSetsName() {
        let m = makeModule(name: "test.dll", base: 0x40000000)
        #expect(m.name.hasSuffix("test.dll") || m.shortName == "test.dll")
        #expect(m.baseAddress == 0x40000000)
    }

    @Test func makeZeroContextHasZeroRIP() {
        let ctx = makeZeroContext()
        #expect(ctx.rip == 0)
        #expect(ctx.rsp == 0)
        #expect(ctx.rbp == 0)
    }
}
