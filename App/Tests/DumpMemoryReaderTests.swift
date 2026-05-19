import Foundation
import Testing
@testable import MiniDumpTruckCore

private extension Data {
    mutating func writeUInt16(_ value: UInt16, at offset: Int) {
        self[offset] = UInt8(value & 0xFF)
        self[offset + 1] = UInt8((value >> 8) & 0xFF)
    }
    mutating func writeUInt32(_ value: UInt32, at offset: Int) {
        for i in 0..<4 { self[offset + i] = UInt8((value >> (i * 8)) & 0xFF) }
    }
    mutating func writeUInt64(_ value: UInt64, at offset: Int) {
        for i in 0..<8 { self[offset + i] = UInt8((value >> (i * 8)) & 0xFF) }
    }
}

/// Builds a minimal dump containing a single Memory64List region.
private func makeDumpWithRegion(start: UInt64, content: [UInt8]) throws -> ParsedMinidump {
    let headerSize = 32
    let dirSize = 12
    let m64Rva = UInt32(headerSize + dirSize)
    let m64HeaderSize = 16
    let m64DescSize = 16
    let dataStart = Int(m64Rva) + m64HeaderSize + m64DescSize

    var data = Data(repeating: 0, count: dataStart + content.count)
    data.writeUInt32(0x504D444D, at: 0)            // "MDMP"
    data.writeUInt16(0xA793, at: 4)
    data.writeUInt32(1, at: 8)                     // stream count
    data.writeUInt32(UInt32(headerSize), at: 12)   // stream dir rva
    data.writeUInt32(0, at: 16)
    data.writeUInt32(1700000000, at: 20)
    data.writeUInt64(0, at: 24)

    data.writeUInt32(9, at: headerSize)                                  // Memory64List
    data.writeUInt32(UInt32(m64HeaderSize + m64DescSize), at: headerSize + 4)
    data.writeUInt32(m64Rva, at: headerSize + 8)

    data.writeUInt64(1, at: Int(m64Rva))                                 // numberOfRanges
    data.writeUInt64(UInt64(dataStart), at: Int(m64Rva) + 8)             // baseRva
    data.writeUInt64(start, at: Int(m64Rva) + 16)                        // startAddress
    data.writeUInt64(UInt64(content.count), at: Int(m64Rva) + 24)        // dataSize
    for (i, b) in content.enumerated() { data[dataStart + i] = b }

    return try MinidumpParser.parse(data: data)
}

@Suite("DumpMemoryReader")
struct DumpMemoryReaderTests {
    @Test func readsBytesAndMatchesParserHelper() throws {
        let dump = try makeDumpWithRegion(start: 0x1000,
                                          content: [0xDE, 0xAD, 0xBE, 0xEF, 0x11, 0x22, 0x33, 0x44])
        let reader = DumpMemoryReader(dump: dump)

        #expect(Array(reader.read(at: 0x1000, size: 4) ?? Data()) == [0xDE, 0xAD, 0xBE, 0xEF])
        // Parity with the existing tested helper
        let viaParser = MinidumpParser.readMemory(from: dump, at: 0x1000, size: 4)
        #expect(reader.read(at: 0x1000, size: 4) == viaParser)
    }

    @Test func readsLittleEndianScalars() throws {
        let dump = try makeDumpWithRegion(start: 0x2000,
                                          content: [0x78, 0x56, 0x34, 0x12, 0xEF, 0xBE, 0xAD, 0xDE])
        let reader = DumpMemoryReader(dump: dump)
        #expect(reader.readUInt16(at: 0x2000) == 0x5678)
        #expect(reader.readUInt32(at: 0x2000) == 0x12345678)
        #expect(reader.readUInt64(at: 0x2000) == 0xDEADBEEF12345678)
    }

    @Test func returnsNilOutsideAnyRegion() throws {
        let dump = try makeDumpWithRegion(start: 0x1000, content: [0xAA, 0xBB])
        let reader = DumpMemoryReader(dump: dump)
        #expect(reader.read(at: 0x9000, size: 4) == nil)
        #expect(reader.readUInt32(at: 0x9000) == nil)
    }
}
