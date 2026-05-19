import Foundation
import Testing
@testable import MiniDumpTruckCore

private extension Data {
    mutating func w16(_ v: UInt16, _ o: Int) { self[o] = UInt8(v & 0xFF); self[o+1] = UInt8(v >> 8 & 0xFF) }
    mutating func w32(_ v: UInt32, _ o: Int) { for i in 0..<4 { self[o+i] = UInt8(v >> (i*8) & 0xFF) } }
    mutating func w64(_ v: UInt64, _ o: Int) { for i in 0..<8 { self[o+i] = UInt8(v >> (i*8) & 0xFF) } }
}

/// Builds a dump with: 1 ModuleList module (name "test.dll", base, size) and a
/// Memory64List region [base, base+image.count) containing `image`.
private func makeDumpWithModuleImage(base: UInt64, image: [UInt8]) throws -> ParsedMinidump {
    // Layout: header(32) + streamDir(2 entries * 12) then payloads.
    let headerSize = 32
    let dirEntries = 2
    let dirSize = dirEntries * 12
    let modRva = headerSize + dirSize

    // ModuleList: count(4) + one MINIDUMP_MODULE(108) + name (MINIDUMP_STRING).
    let nameUTF16 = Array("test.dll".utf16)
    let nameRva = modRva + 4 + ModuleInfo.size
    let nameFieldLen = 4 + nameUTF16.count * 2
    let m64Rva = nameRva + nameFieldLen
    let m64HeaderSize = 16
    let m64DescSize = 16
    let imgStart = m64Rva + m64HeaderSize + m64DescSize

    var data = Data(repeating: 0, count: imgStart + image.count)
    data.w32(0x504D444D, 0)
    data.w16(0xA793, 4)
    data.w32(UInt32(dirEntries), 8)
    data.w32(UInt32(headerSize), 12)
    data.w32(0, 16)
    data.w32(1700000000, 20)
    data.w64(0, 24)

    // Stream dir entry 0: ModuleList (type 4)
    data.w32(4, headerSize + 0)
    data.w32(UInt32(4 + ModuleInfo.size), headerSize + 4)
    data.w32(UInt32(modRva), headerSize + 8)
    // Stream dir entry 1: Memory64List (type 9)
    data.w32(9, headerSize + 12)
    data.w32(UInt32(m64HeaderSize + m64DescSize), headerSize + 16)
    data.w32(UInt32(m64Rva), headerSize + 20)

    // ModuleList
    data.w32(1, modRva)                                    // module count
    let mod = modRva + 4
    data.w64(base, mod + 0)                                 // baseAddress
    data.w32(UInt32(image.count), mod + 8)                  // sizeOfImage
    data.w32(0, mod + 12)                                   // checksum
    data.w32(0, mod + 16)                                   // timeDateStamp
    data.w32(UInt32(nameRva), mod + 20)                     // moduleNameRva
    // MINIDUMP_STRING at nameRva: length(4) + UTF-16LE
    data.w32(UInt32(nameUTF16.count * 2), nameRva)
    for (i, u) in nameUTF16.enumerated() { data.w16(u, nameRva + 4 + i*2) }

    // Memory64List
    data.w64(1, m64Rva)                                     // numberOfRanges
    data.w64(UInt64(imgStart), m64Rva + 8)                  // baseRva
    data.w64(base, m64Rva + 16)                             // region start
    data.w64(UInt64(image.count), m64Rva + 24)              // region size
    for (i, b) in image.enumerated() { data[imgStart + i] = b }

    return try MinidumpParser.parse(data: data)
}

@Suite("Symbolicator")
struct SymbolicatorTests {
    @Test func resolvesExportedFunction() throws {
        let base: UInt64 = 0x180000000
        let image = makePE64(exports: [("DoWork", 0x1000), ("DoMore", 0x1800)])
        let dump = try makeDumpWithModuleImage(base: base, image: image)
        let sym = Symbolicator(dump: dump)

        let r = sym.resolve(address: base + 0x1804)
        #expect(r?.function == "DoMore")
        #expect(r?.offsetInFunction == 4)
    }

    @Test func returnsNilOutsideAnyModule() throws {
        let base: UInt64 = 0x180000000
        let image = makePE64(exports: [("DoWork", 0x1000)])
        let dump = try makeDumpWithModuleImage(base: base, image: image)
        let sym = Symbolicator(dump: dump)
        #expect(sym.resolve(address: 0x999_000_000) == nil)
    }

    @Test func maxDeltaGuardSuppressesDistantGuess() throws {
        // Only export at rva 0x1000 in an image large enough that we can query
        // exactly at the maxFunctionSpan boundary and one byte past it.
        let base: UInt64 = 0x180000000
        let image = makePE64(exports: [("OnlyExport", 0x1000)], imageSize: 0x80000)
        let dump = try makeDumpWithModuleImage(base: base, image: image)
        let sym = Symbolicator(dump: dump)

        // Inclusive boundary: delta == maxFunctionSpan (0x40000) must resolve.
        let exact = base + 0x1000 + Symbolicator.maxFunctionSpan
        let exactHit = sym.resolve(address: exact)
        #expect(exactHit?.function == "OnlyExport")
        #expect(exactHit?.offsetInFunction == Symbolicator.maxFunctionSpan)

        // One byte past the boundary must NOT resolve.
        let far = exact &+ 1
        #expect(sym.resolve(address: far) == nil)
    }
}

@Suite("CrashAnalyzer Symbolication")
struct CrashAnalyzerSymbolicationTests {
    @Test func createFrameAttachesSymbol() throws {
        // Build a dump with a module image; resolve a frame address directly
        // through the same path createFrame uses (Symbolicator + StackFrame).
        let base: UInt64 = 0x180000000
        let image = makePE64(exports: [("CrashHere", 0x1000)])
        let dump = try makeDumpWithModuleImage(base: base, image: image)

        let sym = Symbolicator(dump: dump)
        let resolved = try #require(sym.resolve(address: base + 0x1020))

        let module = try #require(dump.moduleList?.module(containing: base + 0x1020))
        let frame = StackFrame(
            address: base + 0x1020,
            module: module,
            offsetInModule: module.offset(for: base + 0x1020),
            symbol: resolved,
            frameType: .returnAddress,
            confidence: .medium
        )
        #expect(frame.displayAddress == "test.dll!CrashHere+0x20")
    }
}
