// Shared test fixtures for the MiniDumpTruck test target. Helpers are
// file-scope so any test file in the target can use them without
// imports. Each helper is value-type-safe — concurrent tests get
// independent instances.

import Foundation
import Testing
@testable import MiniDumpTruckCore

// MARK: - Little-endian byte writers for synthetic binary fixtures
//
// Tests across the suite build synthetic minidump bytes by writing
// fields at known offsets. Multiple files used to define near-identical
// private extensions for this — consolidated here to a single internal
// surface that any test file in the target can use without import.

extension Data {
    mutating func writeLEUInt16(_ value: UInt16, at offset: Int) {
        self[offset]     = UInt8(value & 0xFF)
        self[offset + 1] = UInt8((value >> 8) & 0xFF)
    }
    mutating func writeLEUInt32(_ value: UInt32, at offset: Int) {
        for i in 0..<4 { self[offset + i] = UInt8((value >> (i * 8)) & 0xFF) }
    }
    mutating func writeLEUInt64(_ value: UInt64, at offset: Int) {
        for i in 0..<8 { self[offset + i] = UInt8((value >> (i * 8)) & 0xFF) }
    }
}

// MARK: - Raw dump bytes

/// Smallest valid minidump byte buffer: 32-byte header with MDMP
/// signature, 0 streams, empty stream directory at offset 32.
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

/// `ParsedMinidump` skeleton parsed from `makeMinimalMinidumpBytes`.
/// Tests can mutate the var properties (moduleList, threadList, etc.)
/// before passing to exporters or the analyzer. `ParsedMinidump` is a
/// value type, so each call returns a fresh instance.
func makeMinimalDump() -> ParsedMinidump {
    let data = makeMinimalMinidumpBytes()
    guard let header = MinidumpHeader(from: data) else {
        fatalError("makeMinimalDump: MinidumpHeader.init regressed against the minimal-header layout in makeMinimalMinidumpBytes; update one or the other.")
    }
    guard let streamDir = StreamDirectory(from: data, header: header) else {
        fatalError("makeMinimalDump: StreamDirectory.init regressed against the minimal-header layout; update one or the other.")
    }
    return ParsedMinidump(header: header, streamDirectory: streamDir, data: data)
}

// MARK: - Mock models

/// Build a `ModuleInfo` with the given name + base + size.
///
/// Default 64 KB size is arbitrary but non-zero; override for tests
/// asserting module-range coverage.
func makeModule(name: String, base: UInt64, size: UInt32 = 0x10000) -> ModuleInfo {
    var bytes = Data()
    bytes.append(contentsOf: withUnsafeBytes(of: base.littleEndian) { Array($0) })
    bytes.append(contentsOf: withUnsafeBytes(of: size.littleEndian) { Array($0) })
    bytes.append(contentsOf: [UInt8](repeating: 0, count: ModuleInfo.size - 12))
    guard var m = ModuleInfo(from: bytes, at: 0) else {
        fatalError("makeModule: ModuleInfo.init regressed against the minimal byte layout; update the helper.")
    }
    m.setName(name)
    return m
}

/// Zero-filled but structurally valid `ThreadContext` (x64 / AMD64) —
/// all registers and flags zero. Tests asserting context-shape can use
/// this without round-tripping through a real dump.
///
/// Wraps the underlying `AMD64Context` in the multi-architecture enum
/// so it can be passed wherever `ThreadContext` is expected.
func makeZeroContext() -> ThreadContext {
    let buffer = Data(repeating: 0, count: AMD64Context.size)
    guard let amd = AMD64Context(from: buffer, at: 0) else {
        fatalError("makeZeroContext: zero-buffer init regressed — AMD64Context.init likely tightened validation; update the helper.")
    }
    return .amd64(amd)
}

/// Zero-filled `ARM64Context` for tests that need to exercise the
/// architecture-branching paths (UI labels, stack walking) without
/// constructing a synthetic ARM64 dump.
func makeZeroARM64Context() -> ThreadContext {
    let buffer = Data(repeating: 0, count: ARM64Context.size)
    guard let arm = ARM64Context(from: buffer, at: 0) else {
        fatalError("makeZeroARM64Context: zero-buffer init regressed — ARM64Context.init likely tightened validation; update the helper.")
    }
    return .arm64(arm)
}

// MARK: - Self-validation

/// Pin the contract of the byte-layout helpers. If parser-side
/// validation tightens (e.g., a new required field), this suite fails
/// first with one clear diagnostic — instead of every consumer of the
/// helpers failing simultaneously with cryptic downstream errors.
@Suite("TestHelpers self-validation")
struct TestHelpersSelfValidation {
    @Test func minimalBytesParseSuccessfully() throws {
        let bytes = makeMinimalMinidumpBytes()
        let dump = try MinidumpParser.parse(data: bytes)
        #expect(dump.streamDirectory.entries.isEmpty)
    }

    @Test func minimalDumpHeaderShape() {
        // Exercises the two force-unwraps inside makeMinimalDump. If
        // MinidumpHeader or StreamDirectory init regresses against the
        // 32-byte layout, this test catches it before downstream
        // consumers crash with opaque "Unexpectedly found nil."
        let dump = makeMinimalDump()
        #expect(dump.header.version == MinidumpHeader.formatVersion)
        #expect(dump.header.streamDirectoryRva == 32)
        #expect(dump.header.numberOfStreams == 0)
        #expect(dump.streamDirectory.entries.isEmpty)
        #expect(dump.moduleList == nil)
        #expect(dump.threadList == nil)
    }

    @Test func makeModuleSetsNameAndBase() {
        let m = makeModule(name: "test.dll", base: 0x40000000)
        // setName assigns directly; assert both surfaces explicitly so
        // a regression that broke either field is pinned.
        #expect(m.name == "test.dll")
        #expect(m.shortName == "test.dll")
        #expect(m.baseAddress == 0x40000000)
    }

    @Test func makeZeroContextHasZeroRegisters() {
        let ctx = makeZeroContext()
        // Architecture-neutral accessors hide the AMD64 vs ARM64 split.
        #expect(ctx.instructionPointer == 0)
        #expect(ctx.stackPointer == 0)
        #expect(ctx.framePointer == 0)
        #expect(ctx.architectureName == "x64")
    }

    @Test func makeZeroARM64ContextHasZeroRegistersAndArchitecture() {
        let ctx = makeZeroARM64Context()
        #expect(ctx.instructionPointer == 0)
        #expect(ctx.stackPointer == 0)
        #expect(ctx.framePointer == 0)
        #expect(ctx.architectureName == "ARM64")
    }
}
