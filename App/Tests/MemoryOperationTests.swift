import Foundation
import Testing
@testable import MiniDumpTruckCore

// MARK: - Binary Helpers

private extension Data {
    mutating func writeUInt16(_ value: UInt16, at offset: Int) {
        self[offset] = UInt8(value & 0xFF)
        self[offset + 1] = UInt8((value >> 8) & 0xFF)
    }

    mutating func writeUInt32(_ value: UInt32, at offset: Int) {
        for i in 0..<4 {
            self[offset + i] = UInt8((value >> (i * 8)) & 0xFF)
        }
    }

    mutating func writeUInt64(_ value: UInt64, at offset: Int) {
        for i in 0..<8 {
            self[offset + i] = UInt8((value >> (i * 8)) & 0xFF)
        }
    }
}

// MARK: - Memory64List Tests

@Suite("Memory64List")
struct Memory64ListTests {
    /// Build a Memory64List with given regions
    /// Layout: numberOfRanges(8) + baseRva(8) + [startAddr(8) + dataSize(8)] * N + [data bytes]
    private func makeMemory64ListData(
        regions: [(start: UInt64, size: UInt64, content: [UInt8])]
    ) -> (data: Data, rva: UInt32) {
        let headerSize = 16  // numberOfRanges(8) + baseRva(8)
        let descriptorSize = 16  // startAddr(8) + dataSize(8)
        let descriptorsTotal = regions.count * descriptorSize
        let dataStart = headerSize + descriptorsTotal
        var totalDataSize = 0
        for r in regions { totalDataSize += r.content.count }

        var data = Data(repeating: 0, count: dataStart + totalDataSize)
        data.writeUInt64(UInt64(regions.count), at: 0)
        data.writeUInt64(UInt64(dataStart), at: 8)

        var offset = headerSize
        for r in regions {
            data.writeUInt64(r.start, at: offset)
            data.writeUInt64(r.size, at: offset + 8)
            offset += descriptorSize
        }

        // Write actual content
        var contentOffset = dataStart
        for r in regions {
            for (i, byte) in r.content.enumerated() {
                data[contentOffset + i] = byte
            }
            contentOffset += r.content.count
        }

        return (data, 0)
    }

    @Test func parsesEmptyList() {
        var data = Data(repeating: 0, count: 16)
        data.writeUInt64(0, at: 0)   // numberOfRanges
        data.writeUInt64(16, at: 8)  // baseRva

        let list = Memory64List(from: data, at: 0)
        #expect(list != nil)
        #expect(list?.regions.isEmpty == true)
    }

    @Test func parsesSingleRegion() {
        let content: [UInt8] = [0xAA, 0xBB, 0xCC, 0xDD]
        let (data, rva) = makeMemory64ListData(regions: [
            (start: 0x1000, size: 4, content: content)
        ])

        let list = Memory64List(from: data, at: rva)
        #expect(list != nil)
        #expect(list?.regions.count == 1)
        #expect(list?.regions[0].baseAddress == 0x1000)
        #expect(list?.regions[0].regionSize == 4)
    }

    @Test func parsesMultipleRegions() {
        let (data, rva) = makeMemory64ListData(regions: [
            (start: 0x1000, size: 4, content: [0xAA, 0xBB, 0xCC, 0xDD]),
            (start: 0x5000, size: 2, content: [0x11, 0x22])
        ])

        let list = Memory64List(from: data, at: rva)
        #expect(list != nil)
        #expect(list?.regions.count == 2)
        #expect(list?.regions[0].baseAddress == 0x1000)
        #expect(list?.regions[1].baseAddress == 0x5000)
    }

    @Test func regionContainingAddress() {
        let (data, rva) = makeMemory64ListData(regions: [
            (start: 0x1000, size: 0x100, content: Array(repeating: 0, count: 0x100)),
            (start: 0x5000, size: 0x200, content: Array(repeating: 0, count: 0x200))
        ])

        let list = Memory64List(from: data, at: rva)!
        #expect(list.region(containing: 0x1050)?.baseAddress == 0x1000)
        #expect(list.region(containing: 0x5100)?.baseAddress == 0x5000)
        #expect(list.region(containing: 0x9000) == nil)
        #expect(list.region(containing: 0x0FFF) == nil)
    }

    @Test func readMemoryFromRegion() {
        let content: [UInt8] = [0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE, 0xBA, 0xBE]
        let (data, rva) = makeMemory64ListData(regions: [
            (start: 0x1000, size: UInt64(content.count), content: content)
        ])

        let list = Memory64List(from: data, at: rva)!
        let read = list.readMemory(at: 0x1000, size: 4, from: data)
        #expect(read != nil)
        #expect(read?.count == 4)
        #expect(Array(read!) == [0xDE, 0xAD, 0xBE, 0xEF])
    }

    @Test func readMemoryWithOffset() {
        let content: [UInt8] = [0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77]
        let (data, rva) = makeMemory64ListData(regions: [
            (start: 0x1000, size: UInt64(content.count), content: content)
        ])

        let list = Memory64List(from: data, at: rva)!
        let read = list.readMemory(at: 0x1004, size: 3, from: data)
        #expect(read != nil)
        #expect(Array(read!) == [0x44, 0x55, 0x66])
    }

    @Test func readMemoryClampedToAvailable() {
        let content: [UInt8] = [0xAA, 0xBB, 0xCC, 0xDD]
        let (data, rva) = makeMemory64ListData(regions: [
            (start: 0x1000, size: UInt64(content.count), content: content)
        ])

        let list = Memory64List(from: data, at: rva)!
        // Request more than available
        let read = list.readMemory(at: 0x1002, size: 100, from: data)
        #expect(read != nil)
        #expect(read?.count == 2)  // Only 2 bytes remaining
        #expect(Array(read!) == [0xCC, 0xDD])
    }

    @Test func readMemoryFromNonexistentRegion() {
        let (data, rva) = makeMemory64ListData(regions: [
            (start: 0x1000, size: 4, content: [0xAA, 0xBB, 0xCC, 0xDD])
        ])

        let list = Memory64List(from: data, at: rva)!
        #expect(list.readMemory(at: 0x9000, size: 4, from: data) == nil)
    }

    @Test func readMemoryAtRegionStart() {
        let content: [UInt8] = [0x41, 0x42, 0x43, 0x44]
        let (data, rva) = makeMemory64ListData(regions: [
            (start: 0x1000, size: UInt64(content.count), content: content)
        ])

        let list = Memory64List(from: data, at: rva)!
        let read = list.readMemory(at: 0x1000, size: 1, from: data)
        #expect(read?.first == 0x41)
    }

    @Test func readMemoryAtRegionEnd() {
        let content: [UInt8] = [0x41, 0x42, 0x43, 0x44]
        let (data, rva) = makeMemory64ListData(regions: [
            (start: 0x1000, size: UInt64(content.count), content: content)
        ])

        let list = Memory64List(from: data, at: rva)!
        let read = list.readMemory(at: 0x1003, size: 1, from: data)
        #expect(read?.first == 0x44)
    }

    @Test func rejectsExceedingMaxRegions() {
        var data = Data(repeating: 0, count: 16)
        data.writeUInt64(Memory64List.maxRegions + 1, at: 0)
        data.writeUInt64(16, at: 8)
        #expect(Memory64List(from: data, at: 0) == nil)
    }

    @Test func rejectsTruncatedDescriptors() {
        var data = Data(repeating: 0, count: 16)
        data.writeUInt64(100, at: 0)  // Claims 100 regions
        data.writeUInt64(16, at: 8)   // But data is only 16 bytes
        #expect(Memory64List(from: data, at: 0) == nil)
    }
}

// MARK: - MemoryList Tests

@Suite("MemoryList")
struct MemoryListTests {
    @Test func parsesEmptyList() {
        var data = Data(repeating: 0, count: 4)
        data.writeUInt32(0, at: 0)

        let list = MemoryList(from: data, at: 0)
        #expect(list != nil)
        #expect(list?.regions.isEmpty == true)
    }

    @Test func parsesSingleRegion() {
        // Header(4) + descriptor(16) + memory(4) = 24
        var data = Data(repeating: 0, count: 24)
        data.writeUInt32(1, at: 0)          // count
        data.writeUInt64(0x2000, at: 4)     // startOfMemoryRange
        data.writeUInt32(4, at: 12)         // dataSize
        data.writeUInt32(20, at: 16)        // rva to data
        // Memory content at offset 20
        data[20] = 0xAA
        data[21] = 0xBB
        data[22] = 0xCC
        data[23] = 0xDD

        let list = MemoryList(from: data, at: 0)
        #expect(list != nil)
        #expect(list?.regions.count == 1)
        #expect(list?.regions[0].baseAddress == 0x2000)
        #expect(list?.regions[0].regionSize == 4)
    }

    @Test func regionLookup() {
        var data = Data(repeating: 0, count: 40)
        data.writeUInt32(2, at: 0)
        // Region 1
        data.writeUInt64(0x1000, at: 4)
        data.writeUInt32(0x100, at: 12)
        data.writeUInt32(36, at: 16)
        // Region 2
        data.writeUInt64(0x5000, at: 20)
        data.writeUInt32(0x200, at: 28)
        data.writeUInt32(36, at: 32)

        let list = MemoryList(from: data, at: 0)!
        #expect(list.region(containing: 0x1050)?.baseAddress == 0x1000)
        #expect(list.region(containing: 0x5100)?.baseAddress == 0x5000)
        #expect(list.region(containing: 0x9000) == nil)
    }

    @Test func readMemory() {
        // Build a simple list with 1 region containing readable data
        var data = Data(repeating: 0, count: 30)
        data.writeUInt32(1, at: 0)
        data.writeUInt64(0x1000, at: 4)
        data.writeUInt32(8, at: 12)
        data.writeUInt32(20, at: 16)  // RVA to content
        // Content at 20
        data[20] = 0xDE; data[21] = 0xAD; data[22] = 0xBE; data[23] = 0xEF
        data[24] = 0xCA; data[25] = 0xFE; data[26] = 0xBA; data[27] = 0xBE

        let list = MemoryList(from: data, at: 0)!
        let read = list.readMemory(at: 0x1000, size: 4, from: data)
        #expect(read != nil)
        #expect(Array(read!) == [0xDE, 0xAD, 0xBE, 0xEF])
    }

    @Test func readMemoryWithOffset() {
        var data = Data(repeating: 0, count: 30)
        data.writeUInt32(1, at: 0)
        data.writeUInt64(0x1000, at: 4)
        data.writeUInt32(8, at: 12)
        data.writeUInt32(20, at: 16)
        data[20] = 0x00; data[21] = 0x11; data[22] = 0x22; data[23] = 0x33
        data[24] = 0x44; data[25] = 0x55; data[26] = 0x66; data[27] = 0x77

        let list = MemoryList(from: data, at: 0)!
        let read = list.readMemory(at: 0x1003, size: 2, from: data)
        #expect(Array(read!) == [0x33, 0x44])
    }

    @Test func readMemoryNilForUnknownAddress() {
        var data = Data(repeating: 0, count: 20)
        data.writeUInt32(1, at: 0)
        data.writeUInt64(0x1000, at: 4)
        data.writeUInt32(4, at: 12)
        data.writeUInt32(20, at: 16)

        let list = MemoryList(from: data, at: 0)!
        #expect(list.readMemory(at: 0x9000, size: 4, from: data) == nil)
    }

    @Test func rejectsExceedingMaxRegions() {
        var data = Data(repeating: 0, count: 4)
        data.writeUInt32(MemoryList.maxRegions + 1, at: 0)
        #expect(MemoryList(from: data, at: 0) == nil)
    }

    @Test func descriptorSize() {
        #expect(MemoryList.descriptorSize == 16)
    }
}

// MARK: - MemoryInfoList Tests

@Suite("MemoryInfoList")
struct MemoryInfoListTests {
    @Test func parsesValidList() {
        // Header(16) + 1 entry(48) = 64
        var data = Data(repeating: 0, count: 64)
        data.writeUInt32(16, at: 0)   // sizeOfHeader
        data.writeUInt32(48, at: 4)   // sizeOfEntry
        data.writeUInt64(1, at: 8)    // numberOfEntries

        // Entry at offset 16
        data.writeUInt64(0x7FF800000000, at: 16)  // baseAddress
        data.writeUInt64(0x7FF800000000, at: 24)  // allocationBase
        data.writeUInt32(0x04, at: 32)             // allocationProtect
        data.writeUInt64(0x10000, at: 40)          // regionSize
        data.writeUInt32(0x1000, at: 48)           // state = commit
        data.writeUInt32(0x20, at: 52)             // protect
        data.writeUInt32(0x1000000, at: 56)        // type = image

        let list = MemoryInfoList(from: data, at: 0)
        #expect(list != nil)
        #expect(list?.entries.count == 1)
        #expect(list?.entries[0].baseAddress == 0x7FF800000000)
        #expect(list?.entries[0].state == .commit)
    }

    @Test func parsesListWithCustomEntrySize() {
        // Header(16) + 1 entry(64 instead of 48) = 80
        var data = Data(repeating: 0, count: 80)
        data.writeUInt32(16, at: 0)
        data.writeUInt32(64, at: 4)  // Larger entry size (some implementations have extra fields)
        data.writeUInt64(1, at: 8)

        data.writeUInt64(0x1000, at: 16)
        data.writeUInt64(0x1000, at: 24)
        data.writeUInt32(0x04, at: 32)
        data.writeUInt64(0x1000, at: 40)
        data.writeUInt32(0x1000, at: 48)
        data.writeUInt32(0x02, at: 52)
        data.writeUInt32(0x20000, at: 56)

        let list = MemoryInfoList(from: data, at: 0)
        #expect(list != nil)
        #expect(list?.entries.count == 1)
    }

    @Test func rejectsExceedingMaxEntries() {
        var data = Data(repeating: 0, count: 16)
        data.writeUInt32(16, at: 0)
        data.writeUInt32(48, at: 4)
        data.writeUInt64(MemoryInfoList.maxEntries + 1, at: 8)

        #expect(MemoryInfoList(from: data, at: 0) == nil)
    }

    @Test func entrySize() {
        #expect(MemoryInfoList.entrySize == 48)
    }
}

// MARK: - MinidumpParser readMemory Tests

@Suite("MinidumpParser readMemory")
struct MinidumpParserReadMemoryTests {
    @Test func triesMemory64ListFirst() throws {
        // Build a minimal dump with a Memory64List
        let headerSize = 32
        let dirSize = 12
        let m64Rva = UInt32(headerSize + dirSize)
        let m64HeaderSize = 16
        let m64DescSize = 16
        let dataStart = Int(m64Rva) + m64HeaderSize + m64DescSize

        var data = Data(repeating: 0, count: dataStart + 8)

        // Header
        data.writeUInt32(0x504D444D, at: 0)
        data.writeUInt16(0xA793, at: 4)
        data.writeUInt32(1, at: 8)
        data.writeUInt32(UInt32(headerSize), at: 12)
        data.writeUInt32(0, at: 16)
        data.writeUInt32(1700000000, at: 20)
        data.writeUInt64(0, at: 24)

        // Dir: Memory64List
        data.writeUInt32(9, at: headerSize)
        data.writeUInt32(UInt32(m64HeaderSize + m64DescSize), at: headerSize + 4)
        data.writeUInt32(m64Rva, at: headerSize + 8)

        // Memory64List
        data.writeUInt64(1, at: Int(m64Rva))                    // numberOfRanges
        data.writeUInt64(UInt64(dataStart), at: Int(m64Rva) + 8) // baseRva
        data.writeUInt64(0x1000, at: Int(m64Rva) + 16)          // startAddress
        data.writeUInt64(8, at: Int(m64Rva) + 24)               // dataSize

        // Memory content at dataStart
        data[dataStart] = 0xDE
        data[dataStart + 1] = 0xAD
        data[dataStart + 2] = 0xBE
        data[dataStart + 3] = 0xEF

        let dump = try MinidumpParser.parse(data: data)
        let read = MinidumpParser.readMemory(from: dump, at: 0x1000, size: 4)
        #expect(read != nil)
        #expect(Array(read!) == [0xDE, 0xAD, 0xBE, 0xEF])
    }

    @Test func returnsNilForUnknownAddress() throws {
        // Minimal dump with no memory streams
        var data = Data(repeating: 0, count: 32)
        data.writeUInt32(0x504D444D, at: 0)
        data.writeUInt16(0xA793, at: 4)
        data.writeUInt32(0, at: 8)
        data.writeUInt32(32, at: 12)
        data.writeUInt32(0, at: 16)
        data.writeUInt32(1700000000, at: 20)
        data.writeUInt64(0, at: 24)

        let dump = try MinidumpParser.parse(data: data)
        #expect(MinidumpParser.readMemory(from: dump, at: 0x1000, size: 4) == nil)
    }
}

// MARK: - BinaryReader Memory Read Tests

@Suite("BinaryReader Memory Operations")
struct BinaryReaderMemoryTests {
    @Test func readUInt8() {
        var data = Data(count: 1)
        data[0] = 0xAB
        #expect(data.readUInt8(at: 0) == 0xAB)
    }

    @Test func readUInt16LittleEndian() {
        var data = Data(repeating: 0, count: 2)
        data[0] = 0x34
        data[1] = 0x12
        #expect(data.readUInt16(at: 0) == 0x1234)
    }

    @Test func readUInt32LittleEndian() {
        var data = Data(repeating: 0, count: 4)
        data[0] = 0x78; data[1] = 0x56; data[2] = 0x34; data[3] = 0x12
        #expect(data.readUInt32(at: 0) == 0x12345678)
    }

    @Test func readUInt64LittleEndian() {
        var data = Data(repeating: 0, count: 8)
        data[0] = 0xEF; data[1] = 0xCD; data[2] = 0xAB; data[3] = 0x90
        data[4] = 0x78; data[5] = 0x56; data[6] = 0x34; data[7] = 0x12
        #expect(data.readUInt64(at: 0) == 0x1234567890ABCDEF)
    }

    @Test func readOutOfBoundsReturnsNil() {
        let data = Data(repeating: 0, count: 2)
        #expect(data.readUInt32(at: 0) == nil)
        #expect(data.readUInt64(at: 0) == nil)
        #expect(data.readUInt16(at: 1) == nil)
    }

    @Test func readAtNegativeOffsetReturnsNil() {
        let data = Data(repeating: 0, count: 4)
        #expect(data.readUInt32(at: -1) == nil)
    }

    @Test func subdataValid() {
        let data = Data([0, 1, 2, 3, 4, 5])
        let sub = data.subdata(at: 2, count: 3)
        #expect(sub != nil)
        #expect(Array(sub!) == [2, 3, 4])
    }

    @Test func subdataOutOfBounds() {
        let data = Data([0, 1, 2])
        #expect(data.subdata(at: 1, count: 10) == nil)
        #expect(data.subdata(at: -1, count: 1) == nil)
    }

    @Test func readBytesValid() {
        let data = Data([0xAA, 0xBB, 0xCC])
        let bytes = data.readBytes(at: 0, count: 3)
        #expect(bytes == [0xAA, 0xBB, 0xCC])
    }

    @Test func readBytesOutOfBounds() {
        let data = Data([0xAA])
        #expect(data.readBytes(at: 0, count: 5) == nil)
    }

    @Test func readUTF16String() {
        // MINIDUMP_STRING: length(4) + UTF-16LE data
        var data = Data(repeating: 0, count: 14)
        let text = "Hello"
        let utf16 = Array(text.utf16)
        data.writeUInt32(UInt32(utf16.count * 2), at: 0)
        for (i, u) in utf16.enumerated() {
            data.writeUInt16(u, at: 4 + i * 2)
        }

        let result = data.readUTF16String(at: 0)
        #expect(result == "Hello")
    }

    @Test func readUTF16StringTruncated() {
        let data = Data(repeating: 0, count: 2) // Too small
        #expect(data.readUTF16String(at: 0) == nil)
    }

    @Test func readFixedUTF16String() {
        // "AB" in UTF-16LE: 0x41 0x00 0x42 0x00 0x00 0x00
        var data = Data(repeating: 0, count: 8)
        data[0] = 0x41; data[1] = 0x00  // 'A'
        data[2] = 0x42; data[3] = 0x00  // 'B'
        // Rest is null (terminator)

        let result = data.readFixedUTF16String(at: 0, maxBytes: 8)
        #expect(result == "AB")
    }

    @Test func readFixedUTF16StringOutOfBounds() {
        let data = Data(repeating: 0, count: 4)
        #expect(data.readFixedUTF16String(at: 0, maxBytes: 100) == nil)
    }
}

// MARK: - Memory Region Boundary Tests

@Suite("Memory Region Boundaries")
struct MemoryRegionBoundaryTests {
    @Test func regionStartBoundary() {
        let region = MemoryRegion(baseAddress: 0x1000, regionSize: 0x100, dataRva: 0)
        #expect(region.contains(address: 0x1000))
        #expect(!region.contains(address: 0x0FFF))
    }

    @Test func regionEndBoundary() {
        let region = MemoryRegion(baseAddress: 0x1000, regionSize: 0x100, dataRva: 0)
        #expect(region.contains(address: 0x10FF))
        #expect(!region.contains(address: 0x1100))
    }

    @Test func zeroSizeRegion() {
        let region = MemoryRegion(baseAddress: 0x1000, regionSize: 0, dataRva: 0)
        #expect(!region.contains(address: 0x1000))
    }

    @Test func maxAddressRegion() {
        let region = MemoryRegion(baseAddress: UInt64.max - 1, regionSize: 2, dataRva: 0)
        #expect(region.contains(address: UInt64.max - 1))
        // endAddress should be UInt64.max due to overflow protection
        #expect(region.endAddress == UInt64.max)
    }

    @Test func largeRegion() {
        let region = MemoryRegion(baseAddress: 0, regionSize: UInt64.max, dataRva: 0)
        #expect(region.contains(address: 0))
        #expect(region.contains(address: UInt64.max / 2))
        #expect(region.endAddress == UInt64.max)
    }
}

// MARK: - Memory64List Data Offset Tracking Tests

@Suite("Memory64List Data Offsets")
struct Memory64ListDataOffsetTests {
    @Test func consecutiveRegionsHaveCorrectDataRvas() {
        // 2 regions: first=100 bytes, second=200 bytes
        // Data starts at offset: header(16) + 2*descriptor(32) = 48
        var data = Data(repeating: 0, count: 48 + 300)
        data.writeUInt64(2, at: 0)       // numberOfRanges
        data.writeUInt64(48, at: 8)      // baseRva
        data.writeUInt64(0x1000, at: 16) // region 1 start
        data.writeUInt64(100, at: 24)    // region 1 size
        data.writeUInt64(0x5000, at: 32) // region 2 start
        data.writeUInt64(200, at: 40)    // region 2 size

        let list = Memory64List(from: data, at: 0)!
        #expect(list.regions[0].dataRva == 48)        // First region starts at baseRva
        #expect(list.regions[1].dataRva == 48 + 100)  // Second region after first
    }
}
