import Foundation
import Testing
@testable import MiniDumpTruckCore

@Suite("MinidumpHeader Tests")
struct MinidumpHeaderTests {

    // MARK: - Test Helpers

    /// Creates a valid minidump header data
    func createValidHeader(
        version: UInt16 = 0xA793,
        implVersion: UInt16 = 0x0000,
        streamCount: UInt32 = 10,
        streamDirectoryRva: UInt32 = 32,
        checksum: UInt32 = 0,
        timestamp: UInt32 = 1700000000,
        flags: UInt64 = 0x00000002  // WithFullMemory
    ) -> Data {
        var data = Data()

        // Signature: "MDMP" = 0x504D444D
        data.append(contentsOf: [0x4D, 0x44, 0x4D, 0x50])

        // Version (2 bytes) + Implementation version (2 bytes)
        data.append(contentsOf: withUnsafeBytes(of: version.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: implVersion.littleEndian) { Array($0) })

        // Number of streams (4 bytes)
        data.append(contentsOf: withUnsafeBytes(of: streamCount.littleEndian) { Array($0) })

        // Stream directory RVA (4 bytes)
        data.append(contentsOf: withUnsafeBytes(of: streamDirectoryRva.littleEndian) { Array($0) })

        // Checksum (4 bytes)
        data.append(contentsOf: withUnsafeBytes(of: checksum.littleEndian) { Array($0) })

        // TimeDateStamp (4 bytes)
        data.append(contentsOf: withUnsafeBytes(of: timestamp.littleEndian) { Array($0) })

        // Flags (8 bytes)
        data.append(contentsOf: withUnsafeBytes(of: flags.littleEndian) { Array($0) })

        return data
    }

    // MARK: - Valid Header Tests

    @Test func validHeaderParsing() {
        let data = createValidHeader()

        let header = MinidumpHeader(from: data)

        #expect(header != nil)
        #expect(header?.version == 0xA793)
        #expect(header?.numberOfStreams == 10)
        #expect(header?.streamDirectoryRva == 32)
    }

    @Test func headerTimestamp() {
        let timestamp: UInt32 = 1700000000
        let data = createValidHeader(timestamp: timestamp)

        let header = MinidumpHeader(from: data)

        #expect(header != nil)
        #expect(header?.timeDateStamp == timestamp)

        // Check Date conversion
        let expectedDate = Date(timeIntervalSince1970: TimeInterval(timestamp))
        #expect(header?.timestamp == expectedDate)
    }

    @Test func headerFlags() {
        let flags: UInt64 = 0x00000802  // WithFullMemory | WithFullMemoryInfo
        let data = createValidHeader(flags: flags)

        let header = MinidumpHeader(from: data)

        #expect(header != nil)
        #expect(header?.flags == flags)

        let descriptions = header?.flagsDescription ?? []
        #expect(descriptions.contains("WithFullMemory"))
        #expect(descriptions.contains("WithFullMemoryInfo"))
    }

    @Test func headerFlagsNormal() {
        let data = createValidHeader(flags: 0)

        let header = MinidumpHeader(from: data)

        #expect(header != nil)
        #expect(header?.flagsDescription == ["Normal"])
    }

    // MARK: - Invalid Header Tests

    @Test func invalidSignature() {
        var data = createValidHeader()
        // Corrupt the signature
        data[0] = 0x00

        let header = MinidumpHeader(from: data)
        #expect(header == nil)
    }

    @Test func wrongSignature() {
        // "PMPM" instead of "MDMP"
        var data = Data([0x50, 0x4D, 0x50, 0x4D])
        data.append(contentsOf: Array(repeating: UInt8(0), count: 28))

        let header = MinidumpHeader(from: data)
        #expect(header == nil)
    }

    @Test func truncatedHeader() {
        // Only 20 bytes instead of 32
        let data = Data(repeating: 0, count: 20)

        let header = MinidumpHeader(from: data)
        #expect(header == nil)
    }

    @Test func emptyData() {
        let data = Data()

        let header = MinidumpHeader(from: data)
        #expect(header == nil)
    }

    @Test func minimumValidSize() {
        // Header is exactly 32 bytes
        let data = createValidHeader()
        #expect(data.count == 32)
        #expect(MinidumpHeader(from: data) != nil)
    }

    // MARK: - Signature Constant Test

    @Test func signatureConstant() {
        // "MDMP" in ASCII: M=0x4D, D=0x44, M=0x4D, P=0x50
        // In little-endian as UInt32: 0x504D444D
        #expect(MinidumpHeader.signature == 0x504D444D)
    }

    @Test func headerSize() {
        #expect(MinidumpHeader.size == 32)
    }

    // MARK: - MinidumpType Flag Tests

    @Test func minidumpTypeWithDataSegs() {
        let flags: UInt64 = 0x00000001
        let descriptions = MinidumpType.descriptions(for: flags)
        #expect(descriptions == ["WithDataSegs"])
    }

    @Test func minidumpTypeWithFullMemory() {
        let flags: UInt64 = 0x00000002
        let descriptions = MinidumpType.descriptions(for: flags)
        #expect(descriptions == ["WithFullMemory"])
    }

    @Test func minidumpTypeMultipleFlags() {
        let flags: UInt64 = 0x00000003  // WithDataSegs | WithFullMemory
        let descriptions = MinidumpType.descriptions(for: flags)
        #expect(descriptions.contains("WithDataSegs"))
        #expect(descriptions.contains("WithFullMemory"))
    }

    @Test func minidumpTypeAllMajorFlags() {
        // Test several important flags
        let flagsToTest: [(UInt64, String)] = [
            (0x00000001, "WithDataSegs"),
            (0x00000002, "WithFullMemory"),
            (0x00000004, "WithHandleData"),
            (0x00000020, "WithUnloadedModules"),
            (0x00000800, "WithFullMemoryInfo"),
            (0x00001000, "WithThreadInfo"),
        ]

        for (flag, expectedName) in flagsToTest {
            let descriptions = MinidumpType.descriptions(for: flag)
            #expect(descriptions.contains(expectedName), "Flag \(String(format: "0x%X", flag)) should produce \(expectedName)")
        }
    }
}
