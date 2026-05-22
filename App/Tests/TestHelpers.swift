// Shared test fixtures. Closes the long-standing duplication tracked
// in #10. New tests should pull helpers from here rather than copy-
// pasting inline equivalents.

import Foundation
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

/// Return a `ParsedMinidump` skeleton parsed from `makeMinimalMinidumpBytes`.
/// Tests can mutate the var properties (moduleList, threadList, etc.)
/// before passing to exporters or the analyzer.
func makeMinimalDump() -> ParsedMinidump {
    var data = Data(repeating: 0, count: 32)
    data[0] = 0x4D; data[1] = 0x44; data[2] = 0x4D; data[3] = 0x50  // MDMP
    data[4] = 0x93; data[5] = 0xA7                                   // version
    data[12] = 32                                                    // streamDirectoryRva
    let header = MinidumpHeader(from: data)!
    let streamDir = StreamDirectory(from: data, header: header)!
    return ParsedMinidump(header: header, streamDirectory: streamDir, data: data)
}

// MARK: - Mock models

/// Build a `ModuleInfo` with the given name + base + size. Used by
/// exporter, symbolicator, and coverage-gap tests.
func mockModule(name: String, base: UInt64, size: UInt32 = 0x10000) -> ModuleInfo {
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
    return ThreadContext(from: buffer, at: 0)!
}
