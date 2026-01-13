import Foundation
import Testing
@testable import MiniDumpTruckCore

@Suite("BinaryReader Tests")
struct BinaryReaderTests {

    // MARK: - Data Extension Tests

    @Test func readUInt8() {
        let data = Data([0x42])
        #expect(data.readUInt8(at: 0) == 0x42)
    }

    @Test func readUInt8OutOfBounds() {
        let data = Data([0x42])
        #expect(data.readUInt8(at: 1) == nil)
        #expect(data.readUInt8(at: -1) == nil)
    }

    @Test func readUInt16LittleEndian() {
        // Little-endian: 0x0102 is stored as [0x02, 0x01]
        let data = Data([0x02, 0x01])
        #expect(data.readUInt16(at: 0) == 0x0102)
    }

    @Test func readUInt16OutOfBounds() {
        let data = Data([0x42])
        #expect(data.readUInt16(at: 0) == nil)
    }

    @Test func readUInt32LittleEndian() {
        // Little-endian: 0x01020304 is stored as [0x04, 0x03, 0x02, 0x01]
        let data = Data([0x04, 0x03, 0x02, 0x01])
        #expect(data.readUInt32(at: 0) == 0x01020304)
    }

    @Test func readUInt32AtOffset() {
        let data = Data([0xFF, 0xFF, 0x04, 0x03, 0x02, 0x01])
        #expect(data.readUInt32(at: 2) == 0x01020304)
    }

    @Test func readUInt32OutOfBounds() {
        let data = Data([0x01, 0x02, 0x03])
        #expect(data.readUInt32(at: 0) == nil)
    }

    @Test func readUInt64LittleEndian() {
        // Little-endian: bytes are reversed
        let data = Data([0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01])
        #expect(data.readUInt64(at: 0) == 0x0102030405060708)
    }

    @Test func readUInt64OutOfBounds() {
        let data = Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07])
        #expect(data.readUInt64(at: 0) == nil)
    }

    @Test func readMinidumpSignature() {
        // "MDMP" in little-endian is 0x504D444D
        let data = Data([0x4D, 0x44, 0x4D, 0x50])  // "MDMP"
        #expect(data.readUInt32(at: 0) == 0x504D444D)
    }

    @Test func subdata() {
        let data = Data([0x01, 0x02, 0x03, 0x04, 0x05])
        let sub = data.subdata(at: 1, count: 3)
        #expect(sub == Data([0x02, 0x03, 0x04]))
    }

    @Test func subdataOutOfBounds() {
        let data = Data([0x01, 0x02, 0x03])
        #expect(data.subdata(at: 2, count: 3) == nil)
        #expect(data.subdata(at: -1, count: 1) == nil)
    }

    @Test func readBytes() {
        let data = Data([0x01, 0x02, 0x03, 0x04, 0x05])
        let bytes = data.readBytes(at: 1, count: 3)
        #expect(bytes == [0x02, 0x03, 0x04])
    }

    @Test func readBytesOutOfBounds() {
        let data = Data([0x01, 0x02])
        #expect(data.readBytes(at: 0, count: 5) == nil)
    }

    // MARK: - UTF-16 String Tests

    @Test func readUTF16String() {
        // Length (4 bytes) + "Hi" in UTF-16LE
        var data = Data()
        data.append(contentsOf: [0x04, 0x00, 0x00, 0x00])  // Length = 4 bytes
        data.append(contentsOf: [0x48, 0x00, 0x69, 0x00])  // "Hi" in UTF-16LE

        #expect(data.readUTF16String(at: 0) == "Hi")
    }

    @Test func readUTF16StringEmpty() {
        var data = Data()
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x00])  // Length = 0

        #expect(data.readUTF16String(at: 0) == "")
    }

    @Test func readFixedUTF16String() {
        // "Test" in UTF-16LE with null terminator
        let data = Data([0x54, 0x00, 0x65, 0x00, 0x73, 0x00, 0x74, 0x00, 0x00, 0x00])
        #expect(data.readFixedUTF16String(at: 0, maxBytes: 10) == "Test")
    }

    // MARK: - BinaryDataReader Tests

    @Test func binaryDataReaderPosition() {
        let data = Data([0x01, 0x02, 0x03, 0x04])
        let reader = BinaryDataReader(data: data)

        #expect(reader.position == 0)
        #expect(reader.remaining == 4)
        #expect(reader.isAtEnd == false)
    }

    @Test func binaryDataReaderReadAdvancesPosition() {
        let data = Data([0x01, 0x02, 0x03, 0x04])
        var reader = BinaryDataReader(data: data)

        let value = reader.readUInt16()
        #expect(value == 0x0201)
        #expect(reader.position == 2)
    }

    @Test func binaryDataReaderSeek() {
        let data = Data([0x01, 0x02, 0x03, 0x04])
        var reader = BinaryDataReader(data: data)

        reader.seek(to: 2)
        #expect(reader.position == 2)
        #expect(reader.readUInt8() == 0x03)
    }

    @Test func binaryDataReaderSeekClampsBounds() {
        let data = Data([0x01, 0x02, 0x03, 0x04])
        var reader = BinaryDataReader(data: data)

        reader.seek(to: 100)
        #expect(reader.position == 4)

        reader.seek(to: -10)
        #expect(reader.position == 0)
    }

    @Test func binaryDataReaderSkip() {
        let data = Data([0x01, 0x02, 0x03, 0x04])
        var reader = BinaryDataReader(data: data)

        reader.skip(2)
        #expect(reader.position == 2)
    }

    @Test func binaryDataReaderIsAtEnd() {
        let data = Data([0x01, 0x02])
        var reader = BinaryDataReader(data: data)

        _ = reader.readUInt16()
        #expect(reader.isAtEnd == true)
        #expect(reader.remaining == 0)
    }

    // MARK: - Edge Cases

    @Test func emptyData() {
        let data = Data()
        #expect(data.readUInt8(at: 0) == nil)
        #expect(data.readUInt16(at: 0) == nil)
        #expect(data.readUInt32(at: 0) == nil)
        #expect(data.readUInt64(at: 0) == nil)
    }

    @Test func negativeOffset() {
        let data = Data([0x01, 0x02, 0x03, 0x04])
        #expect(data.readUInt32(at: -1) == nil)
        #expect(data.subdata(at: -5, count: 2) == nil)
    }

    @Test func maxValues() {
        let data = Data([0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
        #expect(data.readUInt8(at: 0) == UInt8.max)
        #expect(data.readUInt16(at: 0) == UInt16.max)
        #expect(data.readUInt32(at: 0) == UInt32.max)
        #expect(data.readUInt64(at: 0) == UInt64.max)
    }

    @Test func zeroValues() {
        let data = Data([0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        #expect(data.readUInt8(at: 0) == 0)
        #expect(data.readUInt16(at: 0) == 0)
        #expect(data.readUInt32(at: 0) == 0)
        #expect(data.readUInt64(at: 0) == 0)
    }
}
