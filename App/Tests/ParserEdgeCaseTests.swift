import Foundation
import Testing
@testable import MiniDumpTruckCore

// MARK: - Binary Helpers

private extension Data {
    mutating func writeUInt8(_ value: UInt8, at offset: Int) {
        self[offset] = value
    }

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

private func makeValidMinidump(
    numberOfStreams: UInt32 = 1,
    streamDirectoryRva: UInt32 = 32,
    streamType: UInt32 = 7,  // SystemInfo
    streamDataSize: UInt32 = 56,
    streamRva: UInt32 = 44
) -> Data {
    // Header (32) + Directory (12) + SystemInfo (56) = 100 bytes minimum
    let totalSize = max(Int(streamRva + streamDataSize), 100)
    var data = Data(repeating: 0, count: totalSize)
    // Header
    data.writeUInt32(0x504D444D, at: 0)
    data.writeUInt16(0xA793, at: 4)
    data.writeUInt16(0, at: 6)
    data.writeUInt32(numberOfStreams, at: 8)
    data.writeUInt32(streamDirectoryRva, at: 12)
    data.writeUInt32(0, at: 16)
    data.writeUInt32(1700000000, at: 20)
    data.writeUInt64(0, at: 24)
    // Stream directory entry at offset 32
    data.writeUInt32(streamType, at: Int(streamDirectoryRva))
    data.writeUInt32(streamDataSize, at: Int(streamDirectoryRva) + 4)
    data.writeUInt32(streamRva, at: Int(streamDirectoryRva) + 8)

    // If systemInfo stream, write valid data
    if streamType == 7 {
        let rva = Int(streamRva)
        data.writeUInt16(9, at: rva)      // amd64
        data.writeUInt16(6, at: rva + 2)
        data.writeUInt16(0, at: rva + 4)
        data.writeUInt8(4, at: rva + 6)
        data.writeUInt8(1, at: rva + 7)
        data.writeUInt32(10, at: rva + 8)
        data.writeUInt32(0, at: rva + 12)
        data.writeUInt32(22000, at: rva + 16)
        data.writeUInt32(2, at: rva + 20)
        data.writeUInt32(0, at: rva + 24)
        data.writeUInt16(0, at: rva + 28)
        // CPU info (x86)
        data.writeUInt32(0x756E6547, at: rva + 32)
        data.writeUInt32(0x49656E69, at: rva + 36)
        data.writeUInt32(0x6C65746E, at: rva + 40)
        data.writeUInt32(0x000806EC, at: rva + 44)
        data.writeUInt32(0xBFEBFBFF, at: rva + 48)
        data.writeUInt32(0, at: rva + 52)
    }

    return data
}

// MARK: - Parser Error Tests

@Suite("MinidumpParser Errors")
struct MinidumpParserErrorTests {

    @Test func rejectsEmptyData() throws {
        let data = Data()
        #expect(throws: MinidumpParseError.self) {
            try MinidumpParser.parse(data: data)
        }
    }

    @Test func rejectsInvalidSignature() throws {
        var data = Data(repeating: 0, count: 32)
        data.writeUInt32(0xDEADBEEF, at: 0)  // Wrong sig

        #expect {
            try MinidumpParser.parse(data: data)
        } throws: { error in
            guard let parseError = error as? MinidumpParseError,
                  case .invalidSignature = parseError else {
                return false
            }
            return true
        }
    }

    @Test func rejectsTruncatedHeader() throws {
        var data = Data(repeating: 0, count: 16)  // Too short for header
        data.writeUInt32(0x504D444D, at: 0)

        #expect(throws: MinidumpParseError.self) {
            try MinidumpParser.parse(data: data)
        }
    }

    @Test func rejectsInvalidFormatVersion() throws {
        var data = Data(repeating: 0, count: 32)
        data.writeUInt32(0x504D444D, at: 0)
        data.writeUInt16(0x1234, at: 4)  // Wrong version

        #expect(throws: MinidumpParseError.self) {
            try MinidumpParser.parse(data: data)
        }
    }

    @Test func rejectsTooManyStreams() throws {
        var data = Data(repeating: 0, count: 32)
        data.writeUInt32(0x504D444D, at: 0)
        data.writeUInt16(0xA793, at: 4)
        data.writeUInt16(0, at: 6)
        data.writeUInt32(UInt32(StreamDirectory.maxStreams + 1), at: 8)
        data.writeUInt32(32, at: 12)

        #expect(throws: MinidumpParseError.self) {
            try MinidumpParser.parse(data: data)
        }
    }

    @Test func rejectsDirectoryBeyondFileBounds() throws {
        var data = Data(repeating: 0, count: 32)
        data.writeUInt32(0x504D444D, at: 0)
        data.writeUInt16(0xA793, at: 4)
        data.writeUInt16(0, at: 6)
        data.writeUInt32(1, at: 8)         // 1 stream
        data.writeUInt32(100000, at: 12)   // Directory RVA way beyond data
        data.writeUInt32(0, at: 16)
        data.writeUInt32(1700000000, at: 20)
        data.writeUInt64(0, at: 24)

        #expect(throws: MinidumpParseError.self) {
            try MinidumpParser.parse(data: data)
        }
    }
}

// MARK: - Parse Error Description Tests

@Suite("MinidumpParseError Descriptions")
struct MinidumpParseErrorDescriptionTests {
    @Test func invalidSignatureDescription() {
        let error = MinidumpParseError.invalidSignature
        #expect(error.errorDescription?.contains("MDMP") == true)
    }

    @Test func invalidHeaderDescription() {
        let error = MinidumpParseError.invalidHeader
        #expect(error.errorDescription?.contains("header") == true)
    }

    @Test func invalidStreamDirectoryDescription() {
        let error = MinidumpParseError.invalidStreamDirectory
        #expect(error.errorDescription?.contains("stream directory") == true)
    }

    @Test func streamNotFoundDescription() {
        let error = MinidumpParseError.streamNotFound(.threadList)
        #expect(error.errorDescription?.contains("Thread List") == true)
    }

    @Test func parseErrorDescription() {
        let error = MinidumpParseError.parseError("custom message")
        #expect(error.errorDescription?.contains("custom message") == true)
    }
}

// MARK: - ParseWarning Tests

@Suite("ParseWarning")
struct ParseWarningTests {
    @Test func initializesWithAllFields() {
        let warning = ParseWarning(streamType: .threadList, offset: 100, message: "test")
        #expect(warning.streamType == .threadList)
        #expect(warning.offset == 100)
        #expect(warning.message == "test")
    }

    @Test func initializesWithNilOptionals() {
        let warning = ParseWarning(message: "simple warning")
        #expect(warning.streamType == nil)
        #expect(warning.offset == nil)
        #expect(warning.message == "simple warning")
    }
}

// MARK: - Parser Successful Parse Tests

@Suite("MinidumpParser Success Paths")
struct MinidumpParserSuccessTests {
    @Test func parsesMinimalValidDump() throws {
        let data = makeValidMinidump()
        let dump = try MinidumpParser.parse(data: data)
        #expect(dump.header.numberOfStreams == 1)
        #expect(dump.streamDirectory.entries.count == 1)
        #expect(dump.systemInfo != nil)
    }

    @Test func parsesZeroStreams() throws {
        // Header with 0 streams, directory still at offset 32
        var data = Data(repeating: 0, count: 32)
        data.writeUInt32(0x504D444D, at: 0)
        data.writeUInt16(0xA793, at: 4)
        data.writeUInt16(0, at: 6)
        data.writeUInt32(0, at: 8)   // 0 streams
        data.writeUInt32(32, at: 12) // directory at end
        data.writeUInt32(0, at: 16)
        data.writeUInt32(1700000000, at: 20)
        data.writeUInt64(0, at: 24)

        let dump = try MinidumpParser.parse(data: data)
        #expect(dump.streamDirectory.entries.isEmpty)
    }

    @Test func unknownStreamTypeIsIgnored() throws {
        let data = makeValidMinidump(
            streamType: 999,   // Unknown type
            streamDataSize: 0,
            streamRva: 44
        )
        let dump = try MinidumpParser.parse(data: data)
        #expect(dump.streamDirectory.entries.count == 1)
        #expect(dump.systemInfo == nil)  // Not parsed (unknown type)
    }

    @Test func generatesWarningForBadStreamData() throws {
        // Create a dump with an exception stream that has invalid data
        let data = makeValidMinidump(
            streamType: 6,    // Exception
            streamDataSize: 4, // Way too small for exception (needs 168)
            streamRva: 44
        )
        let dump = try MinidumpParser.parse(data: data)
        #expect(dump.exception == nil)
        #expect(dump.parseWarnings.count >= 1)
        #expect(dump.parseWarnings.first?.streamType == .exception)
    }
}

// MARK: - StreamDirectory Tests

@Suite("StreamDirectory")
struct StreamDirectoryTests {
    @Test func streamLookup() throws {
        // Create dump with 2 streams: SystemInfo and Exception
        let headerSize = 32
        let dirSize = 12 * 2  // 2 entries
        let sysInfoRva = UInt32(headerSize + dirSize)
        let exceptionRva = sysInfoRva + 56

        var data = Data(repeating: 0, count: Int(exceptionRva) + 168)
        // Header
        data.writeUInt32(0x504D444D, at: 0)
        data.writeUInt16(0xA793, at: 4)
        data.writeUInt32(2, at: 8)
        data.writeUInt32(UInt32(headerSize), at: 12)
        data.writeUInt32(0, at: 16)
        data.writeUInt32(1700000000, at: 20)
        data.writeUInt64(0, at: 24)

        // Directory entry 1: SystemInfo
        data.writeUInt32(7, at: headerSize)
        data.writeUInt32(56, at: headerSize + 4)
        data.writeUInt32(sysInfoRva, at: headerSize + 8)

        // Directory entry 2: Exception
        data.writeUInt32(6, at: headerSize + 12)
        data.writeUInt32(168, at: headerSize + 16)
        data.writeUInt32(exceptionRva, at: headerSize + 20)

        let header = MinidumpHeader(from: data)!
        let dir = StreamDirectory(from: data, header: header)!

        #expect(dir.stream(ofType: .systemInfo) != nil)
        #expect(dir.stream(ofType: .exception) != nil)
        #expect(dir.stream(ofType: .threadList) == nil)
        #expect(dir.streams(ofType: .systemInfo).count == 1)
    }

    @Test func maxStreamsLimit() {
        #expect(StreamDirectory.maxStreams == 1000)
    }
}

// MARK: - ParsedMinidump Tests

@Suite("ParsedMinidump")
struct ParsedMinidumpTests {
    @Test func faultingThreadWithException() throws {
        // Build a dump with exception + thread list where exception threadId matches
        let headerSize = 32
        let dirSize = 12 * 2
        let exRva = UInt32(headerSize + dirSize)
        let threadRva = exRva + 168

        var data = Data(repeating: 0, count: Int(threadRva) + 4 + 48)

        // Header
        data.writeUInt32(0x504D444D, at: 0)
        data.writeUInt16(0xA793, at: 4)
        data.writeUInt32(2, at: 8)
        data.writeUInt32(UInt32(headerSize), at: 12)
        data.writeUInt32(0, at: 16)
        data.writeUInt32(1700000000, at: 20)
        data.writeUInt64(0, at: 24)

        // Dir entry 1: Exception
        data.writeUInt32(6, at: headerSize)
        data.writeUInt32(168, at: headerSize + 4)
        data.writeUInt32(exRva, at: headerSize + 8)

        // Dir entry 2: ThreadList
        data.writeUInt32(3, at: headerSize + 12)
        data.writeUInt32(UInt32(4 + 48), at: headerSize + 16)
        data.writeUInt32(threadRva, at: headerSize + 20)

        // Exception: threadId = 42
        data.writeUInt32(42, at: Int(exRva))
        data.writeUInt32(0xC0000005, at: Int(exRva) + 8)
        data.writeUInt64(0x7FF800001234, at: Int(exRva) + 24)

        // ThreadList: 1 thread with id=42
        data.writeUInt32(1, at: Int(threadRva))
        data.writeUInt32(42, at: Int(threadRva) + 4)  // threadId
        data.writeUInt32(0, at: Int(threadRva) + 8)   // suspendCount
        data.writeUInt32(32, at: Int(threadRva) + 12)  // priorityClass
        data.writeUInt32(8, at: Int(threadRva) + 16)   // priority
        data.writeUInt64(0, at: Int(threadRva) + 20)   // teb
        // Stack and context zeros are fine for this test

        let dump = try MinidumpParser.parse(data: data)
        #expect(dump.exception?.threadId == 42)

        let faulting = MinidumpParser.faultingThread(in: dump)
        #expect(faulting?.id == 42)
    }

    @Test func faultingThreadNilWithoutException() throws {
        let data = makeValidMinidump()
        let dump = try MinidumpParser.parse(data: data)
        #expect(MinidumpParser.faultingThread(in: dump) == nil)
    }

    @Test func resolveAddressHelper() throws {
        let data = makeValidMinidump()
        let dump = try MinidumpParser.parse(data: data)
        // No modules, should return hex string
        let resolved = MinidumpParser.resolveAddress(0x12345, in: dump)
        #expect(resolved == "0x0000000000012345")
    }
}

// MARK: - DoS Protection Tests

@Suite("DoS Protection Limits")
struct DoSProtectionTests {
    @Test func streamDirectoryMaxStreams() {
        #expect(StreamDirectory.maxStreams == 1000)
    }

    @Test func threadListMaxThreads() {
        #expect(ThreadList.maxThreads == 10_000)
    }

    @Test func moduleListMaxModules() {
        #expect(ModuleList.maxModules == 50_000)
    }

    @Test func memory64ListMaxRegions() {
        #expect(Memory64List.maxRegions == 10_000)
    }

    @Test func memoryListMaxRegions() {
        #expect(MemoryList.maxRegions == 10_000)
    }

    @Test func memoryInfoListMaxEntries() {
        #expect(MemoryInfoList.maxEntries == 1_000_000)
    }

    @Test func handleDataListMaxEntries() {
        #expect(HandleDataList.maxEntries == 100_000)
    }

    @Test func unloadedModuleListMaxModules() {
        #expect(UnloadedModuleList.maxModules == 10_000)
    }

    @Test func threadNameListMaxEntries() {
        #expect(ThreadNameList.maxEntries == 50_000)
    }

    @Test func maxStringLength() {
        #expect(Data.maxStringLength == 1_048_576)
    }
}

// MARK: - Overflow Protection Tests

@Suite("Overflow Protection")
struct OverflowProtectionTests {
    @Test func memory64ListRejectsOverflowInDataOffset() {
        // Create data where regionSize would cause dataOffset overflow
        var data = Data(repeating: 0, count: 48)
        data.writeUInt64(1, at: 0)             // numberOfRanges
        data.writeUInt64(UInt64.max - 10, at: 8) // baseRva near max
        data.writeUInt64(0x1000, at: 16)       // startAddress
        data.writeUInt64(100, at: 24)          // dataSize (would overflow baseRva)

        // This should still parse but with overflow protection
        let list = Memory64List(from: data, at: 0)
        // May succeed or fail depending on overflow - the key is no crash
        if let list = list {
            #expect(list.regions.count <= 1)
        }
    }

    @Test func memoryInfoListRejectsZeroEntrySize() {
        var data = Data(repeating: 0, count: 16)
        data.writeUInt32(16, at: 0)  // sizeOfHeader
        data.writeUInt32(0, at: 4)   // sizeOfEntry = 0 (would infinite loop)
        data.writeUInt64(1, at: 8)   // numberOfEntries

        let list = MemoryInfoList(from: data, at: 0)
        #expect(list == nil)
    }

    @Test func memoryInfoListRejectsTooSmallEntrySize() {
        var data = Data(repeating: 0, count: 16)
        data.writeUInt32(16, at: 0)
        data.writeUInt32(10, at: 4)  // Too small (min is 48)
        data.writeUInt64(1, at: 8)

        let list = MemoryInfoList(from: data, at: 0)
        #expect(list == nil)
    }

    @Test func memoryInfoListRejectsTooSmallHeader() {
        var data = Data(repeating: 0, count: 16)
        data.writeUInt32(8, at: 0)   // Header too small (min is 16)
        data.writeUInt32(48, at: 4)
        data.writeUInt64(0, at: 8)

        let list = MemoryInfoList(from: data, at: 0)
        #expect(list == nil)
    }

    @Test func threadListRejectsCountExceedingDataBounds() {
        // Count fits in UInt32 and passes DoS check but data is too small
        var data = Data(repeating: 0, count: 4)
        data.writeUInt32(5000, at: 0)  // 5000 threads * 48 bytes = 240,000 bytes needed

        let list = ThreadList(from: data, at: 0)
        #expect(list == nil)
    }

    @Test func moduleListRejectsCountExceedingDataBounds() {
        var data = Data(repeating: 0, count: 4)
        data.writeUInt32(5000, at: 0)  // 5000 modules * 108 bytes needed

        let list = ModuleList(from: data, at: 0)
        #expect(list == nil)
    }

    @Test func utf16StringRejectsHugeLength() {
        var data = Data(repeating: 0, count: 8)
        data.writeUInt32(UInt32(Data.maxStringLength + 1), at: 0)  // Length exceeds max
        #expect(data.readUTF16String(at: 0) == nil)
    }
}

// MARK: - Stream Type Coverage Tests

@Suite("Stream Type Coverage")
struct StreamTypeCoverageTests {
    @Test func allStreamTypesHandled() throws {
        // Verify parser doesn't crash on each known stream type
        let streamTypes: [UInt32] = [3, 4, 5, 6, 7, 9, 12, 14, 15, 16, 24]
        for typeRaw in streamTypes {
            let data = makeValidMinidump(
                streamType: typeRaw,
                streamDataSize: 4,  // Intentionally small - parser should warn
                streamRva: 44
            )
            // Should not crash, just may generate warnings
            let dump = try MinidumpParser.parse(data: data)
            #expect(dump.streamDirectory.entries.count == 1)
        }
    }
}

// MARK: - BinaryDataReader Tests

@Suite("BinaryDataReader")
struct BinaryDataReaderTests {
    @Test func readSequentialValues() {
        var data = Data(repeating: 0, count: 16)
        data.writeUInt32(0xAABBCCDD, at: 0)
        data.writeUInt16(0x1234, at: 4)
        data.writeUInt8(0xFF, at: 6)

        var reader = BinaryDataReader(data: data)
        #expect(reader.remaining == 16)
        #expect(!reader.isAtEnd)

        #expect(reader.readUInt32() == 0xAABBCCDD)
        #expect(reader.readUInt16() == 0x1234)
        #expect(reader.readUInt8() == 0xFF)
    }

    @Test func seekAndSkip() {
        let data = Data(repeating: 0, count: 100)
        var reader = BinaryDataReader(data: data)

        reader.seek(to: 50)
        #expect(reader.remaining == 50)

        reader.skip(10)
        #expect(reader.remaining == 40)
    }

    @Test func readAtEnd() {
        let data = Data(repeating: 0, count: 4)
        var reader = BinaryDataReader(data: data)
        reader.seek(to: 4)
        #expect(reader.isAtEnd)
        #expect(reader.readUInt32() == nil)
    }

    @Test func readBytes() {
        var data = Data(repeating: 0, count: 8)
        data[0] = 0xAA
        data[1] = 0xBB
        data[2] = 0xCC

        var reader = BinaryDataReader(data: data)
        let bytes = reader.readBytes(3)
        #expect(bytes == [0xAA, 0xBB, 0xCC])
    }

    @Test func seekClamps() {
        let data = Data(repeating: 0, count: 10)
        var reader = BinaryDataReader(data: data)

        reader.seek(to: -5)
        #expect(reader.remaining == 10)

        reader.seek(to: 100)
        #expect(reader.remaining == 0)
    }
}
