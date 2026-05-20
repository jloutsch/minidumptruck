import Foundation
import Testing
@testable import MiniDumpTruckCore

@Suite("OpenError")
struct OpenErrorTests {
    @Test func notAMinidumpMentionsBytes() throws {
        let err = OpenError.notAMinidump(firstBytes: [0x50, 0x4B, 0x03, 0x04])
        let msg = try #require(err.errorDescription)
        #expect(msg.contains("does not look like a Windows minidump"))
        #expect(msg.contains("50"))  // hex of first byte
    }

    @Test func corruptedMinidumpIncludesUnderlying() throws {
        struct Boom: LocalizedError {
            var errorDescription: String? { "stream offset out of range" }
        }
        let err = OpenError.corruptedMinidump(underlying: Boom())
        let msg = try #require(err.errorDescription)
        #expect(msg.contains("truncated or corrupt"))
        #expect(msg.contains("stream offset out of range"))
    }

    @Test func zipNoMinidumpsIncludesZipName() throws {
        let err = OpenError.zipNoMinidumps(zipName: "crashes.zip")
        let msg = try #require(err.errorDescription)
        #expect(msg.contains("crashes.zip"))
        #expect(msg.contains(".dmp"))
    }

    @Test func zipParseFailedWrapsZipError() throws {
        let err = OpenError.zipParseFailed(.encrypted)
        let msg = try #require(err.errorDescription)
        #expect(msg.contains("encrypted"))
    }

    @Test func zipExtractFailedIncludesEntryName() throws {
        struct Boom: LocalizedError {
            var errorDescription: String? { "disk full" }
        }
        let err = OpenError.zipExtractFailed(entry: "crash.dmp", underlying: Boom())
        let msg = try #require(err.errorDescription)
        #expect(msg.contains("crash.dmp"))
        #expect(msg.contains("disk full"))
    }
}

@Suite("ZipError")
struct ZipErrorTests {
    @Test func notAZipDescription() {
        #expect(ZipError.notAZip.errorDescription?.contains("not a ZIP") == true)
    }

    @Test func corruptedIncludesReason() {
        let err = ZipError.corrupted(reason: "truncated central directory")
        #expect(err.errorDescription?.contains("truncated central directory") == true)
    }

    @Test func encryptedDescription() {
        #expect(ZipError.encrypted.errorDescription?.contains("encrypted") == true)
    }

    @Test func zip64UnsupportedDescription() {
        #expect(ZipError.zip64Unsupported.errorDescription?.contains("ZIP64") == true)
    }

    @Test func unsupportedCompressionIncludesMethod() {
        let err = ZipError.unsupportedCompression(method: 12)
        #expect(err.errorDescription?.contains("12") == true)
    }

    @Test func entryTooLargeIncludesNumbers() {
        let err = ZipError.entryTooLarge(actual: 0xFFFFFFFF, limit: 0xFFFFFFFF)
        #expect(err.errorDescription?.contains("too large") == true)
    }

    @Test func tooManyEntriesIncludesCount() {
        let err = ZipError.tooManyEntries(actual: 200_000, limit: 100_000)
        #expect(err.errorDescription?.contains("100000") == true || err.errorDescription?.contains("100,000") == true)
    }
}
