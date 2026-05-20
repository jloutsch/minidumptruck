import Foundation
import Testing
@testable import MiniDumpTruckCore

/// In-memory MemoryReading for tests: one contiguous image at `base`.
struct BufferMemoryReader: MemoryReading {
    let base: UInt64
    let bytes: [UInt8]
    func read(at address: UInt64, size: Int) -> Data? {
        guard size > 0, address >= base else { return nil }
        let start = Int(address - base)
        guard start < bytes.count else { return nil }
        let end = min(start + size, bytes.count)
        return Data(bytes[start..<end])
    }
}

/// Builds a minimal PE32+ image with an export directory.
/// `exports` are (name, functionRVA). Layout (all little-endian):
///   0x000 DOS header (e_magic 'MZ', e_lfanew at 0x3C -> 0x80)
///   0x080 NT: "PE\0\0", file header, PE32+ optional header
///   0x200 IMAGE_EXPORT_DIRECTORY
///   0x240 AddressOfFunctions[] (u32 each)
///   0x300 AddressOfNames[] (u32 each)
///   0x380 AddressOfNameOrdinals[] (u16 each)
///   0x400 name strings (NUL-terminated)
func makePE64(exports: [(name: String, rva: UInt32)],
              imageSize: Int = 0x2000) -> [UInt8] {
    var img = [UInt8](repeating: 0, count: imageSize)
    func w16(_ v: UInt16, _ o: Int) { img[o] = UInt8(v & 0xFF); img[o+1] = UInt8(v >> 8 & 0xFF) }
    func w32(_ v: UInt32, _ o: Int) { for i in 0..<4 { img[o+i] = UInt8(v >> (i*8) & 0xFF) } }

    let eLfanew = 0x80
    w16(0x5A4D, 0x00)                 // 'MZ'
    w32(UInt32(eLfanew), 0x3C)        // e_lfanew

    w32(0x00004550, eLfanew)          // "PE\0\0"
    // IMAGE_FILE_HEADER at eLfanew+4 (20 bytes); SizeOfOptionalHeader at +16
    let optStart = eLfanew + 4 + 20
    w16(0xF0, eLfanew + 4 + 16)       // SizeOfOptionalHeader (any plausible value)
    w16(0x020B, optStart)             // Magic = PE32+
    // PE32+ DataDirectory starts at optStart + 112; NumberOfRvaAndSizes at optStart + 108
    w32(16, optStart + 108)
    let dirArray = optStart + 112
    let exportDirRVA: UInt32 = 0x200
    let exportDirSize: UInt32 = 0x40
    w32(exportDirRVA, dirArray + 0)   // DataDirectory[0].VirtualAddress
    w32(exportDirSize, dirArray + 4)  // DataDirectory[0].Size

    // IMAGE_EXPORT_DIRECTORY at 0x200
    let ed = 0x200
    let funcs: UInt32 = 0x240
    let names: UInt32 = 0x300
    let ords:  UInt32 = 0x380
    let strs = 0x400
    w32(0, ed + 0)                          // Characteristics
    w32(0, ed + 4)                          // TimeDateStamp
    w16(0, ed + 8); w16(0, ed + 10)         // Major/Minor
    w32(0x400, ed + 12)                     // Name (rva, unused by parser)
    w32(1, ed + 16)                         // Base (ordinal base)
    w32(UInt32(exports.count), ed + 20)     // NumberOfFunctions
    w32(UInt32(exports.count), ed + 24)     // NumberOfNames
    w32(funcs, ed + 28)                     // AddressOfFunctions
    w32(names, ed + 32)                     // AddressOfNames
    w32(ords,  ed + 36)                     // AddressOfNameOrdinals

    var strOff = strs
    for (i, e) in exports.enumerated() {
        w32(e.rva, Int(funcs) + i * 4)              // function rva
        w32(UInt32(strOff), Int(names) + i * 4)     // name rva
        w16(UInt16(i), Int(ords) + i * 2)           // ordinal index into funcs[]
        for b in Array(e.name.utf8) { img[strOff] = b; strOff += 1 }
        img[strOff] = 0; strOff += 1
    }
    return img
}

@Suite("PEExportTable PE32+")
struct PEExportTablePE64Tests {
    @Test func resolvesExactEntry() throws {
        let img = makePE64(exports: [("Foo", 0x1000), ("Bar", 0x1800)])
        let reader = BufferMemoryReader(base: 0x140000000, bytes: img)
        let table = try #require(PEExportTable(reader: reader, imageBase: 0x140000000,
                                               imageSize: UInt32(img.count)))
        let hit = table.symbol(forImageOffset: 0x1000)
        #expect(hit?.name == "Foo")
        #expect(hit?.delta == 0)
    }

    @Test func resolvesMidFunction() {
        let img = makePE64(exports: [("Foo", 0x1000), ("Bar", 0x1800)])
        let reader = BufferMemoryReader(base: 0x140000000, bytes: img)
        let table = PEExportTable(reader: reader, imageBase: 0x140000000,
                                  imageSize: UInt32(img.count))!
        let hit = table.symbol(forImageOffset: 0x1810)
        #expect(hit?.name == "Bar")
        #expect(hit?.delta == 0x10)
    }

    @Test func returnsNilBelowFirstExport() {
        let img = makePE64(exports: [("Foo", 0x1000)])
        let reader = BufferMemoryReader(base: 0x140000000, bytes: img)
        let table = PEExportTable(reader: reader, imageBase: 0x140000000,
                                  imageSize: UInt32(img.count))!
        #expect(table.symbol(forImageOffset: 0x0800) == nil)
    }
}

/// PE32 variant of makePE64 (32-bit optional header: data directory at optStart+96).
func makePE32(exports: [(name: String, rva: UInt32)],
              imageSize: Int = 0x2000) -> [UInt8] {
    var img = [UInt8](repeating: 0, count: imageSize)
    func w16(_ v: UInt16, _ o: Int) { img[o] = UInt8(v & 0xFF); img[o+1] = UInt8(v >> 8 & 0xFF) }
    func w32(_ v: UInt32, _ o: Int) { for i in 0..<4 { img[o+i] = UInt8(v >> (i*8) & 0xFF) } }

    let eLfanew = 0x80
    w16(0x5A4D, 0x00)
    w32(UInt32(eLfanew), 0x3C)
    w32(0x00004550, eLfanew)
    let optStart = eLfanew + 4 + 20
    w16(0xE0, eLfanew + 4 + 16)
    w16(0x010B, optStart)              // Magic = PE32
    w32(16, optStart + 92)             // NumberOfRvaAndSizes
    let dirArray = optStart + 96
    w32(0x200, dirArray + 0)
    w32(0x40, dirArray + 4)

    let ed = 0x200
    let funcs: UInt32 = 0x240, names: UInt32 = 0x300, ords: UInt32 = 0x380
    let strs = 0x400
    w32(1, ed + 16)
    w32(UInt32(exports.count), ed + 20)
    w32(UInt32(exports.count), ed + 24)
    w32(funcs, ed + 28); w32(names, ed + 32); w32(ords, ed + 36)
    var strOff = strs
    for (i, e) in exports.enumerated() {
        w32(e.rva, Int(funcs) + i*4)
        w32(UInt32(strOff), Int(names) + i*4)
        w16(UInt16(i), Int(ords) + i*2)
        for b in Array(e.name.utf8) { img[strOff] = b; strOff += 1 }
        img[strOff] = 0; strOff += 1
    }
    return img
}

@Suite("PEExportTable Edge Cases")
struct PEExportTableEdgeTests {
    @Test func parsesPE32() {
        let img = makePE32(exports: [("Alpha", 0x1000), ("Beta", 0x2000)])
        let reader = BufferMemoryReader(base: 0x400000, bytes: img)
        let table = PEExportTable(reader: reader, imageBase: 0x400000,
                                  imageSize: UInt32(img.count))!
        #expect(table.symbol(forImageOffset: 0x2004)?.name == "Beta")
        #expect(table.symbol(forImageOffset: 0x2004)?.delta == 4)
    }

    @Test func skipsForwarders() {
        // A forwarder's function RVA points inside the export dir range
        // (0x200 ..< 0x240). Foo is a forwarder; Bar is real code.
        let img = makePE64(exports: [("Foo", 0x210), ("Bar", 0x1000)])
        let reader = BufferMemoryReader(base: 0x140000000, bytes: img)
        let table = PEExportTable(reader: reader, imageBase: 0x140000000,
                                  imageSize: UInt32(img.count))!
        // Foo skipped entirely; an address near 0x210 must not resolve to Foo.
        #expect(table.symbol(forImageOffset: 0x1000)?.name == "Bar")
        #expect(table.symbol(forImageOffset: 0x0800) == nil)
        #expect(table.symbol(forImageOffset: 0x0210) == nil)  // Foo was a forwarder; its RVA must not resolve
    }

    @Test func nilWhenImageMemoryAbsent() {
        // Reader has no bytes for the image (dump didn't capture headers).
        let reader = BufferMemoryReader(base: 0x140000000, bytes: [])
        #expect(PEExportTable(reader: reader, imageBase: 0x140000000,
                              imageSize: 0x2000) == nil)
    }

    @Test func nilOnBadDosSignature() {
        var img = makePE64(exports: [("Foo", 0x1000)])
        img[0] = 0x00; img[1] = 0x00     // clobber 'MZ'
        let reader = BufferMemoryReader(base: 0x140000000, bytes: img)
        #expect(PEExportTable(reader: reader, imageBase: 0x140000000,
                              imageSize: UInt32(img.count)) == nil)
    }

    @Test func rejectsExcessiveNameCount() {
        var img = makePE64(exports: [("Foo", 0x1000)])
        // Overwrite NumberOfNames at export dir (0x200 + 24) with a huge value.
        let o = 0x200 + 24
        let huge = UInt32(PEExportTable.maxExports) + 1
        for i in 0..<4 { img[o+i] = UInt8(huge >> (i*8) & 0xFF) }
        let reader = BufferMemoryReader(base: 0x140000000, bytes: img)
        #expect(PEExportTable(reader: reader, imageBase: 0x140000000,
                              imageSize: UInt32(img.count)) == nil)
    }
}
