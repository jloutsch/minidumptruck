import Foundation
import Testing
@testable import MiniDumpTruckCore

@Suite("OpenError")
struct OpenErrorTests {
    @Test func notAMinidumpMentionsBytes() {
        let err = OpenError.notAMinidump(firstBytes: [0x50, 0x4B, 0x03, 0x04])
        let msg = try? #require(err.errorDescription)
        #expect(msg?.contains("does not look like a Windows minidump") == true)
        #expect(msg?.contains("50") == true)  // hex of first byte
    }

    @Test func corruptedMinidumpIncludesUnderlying() {
        struct Boom: LocalizedError {
            var errorDescription: String? { "stream offset out of range" }
        }
        let err = OpenError.corruptedMinidump(underlying: Boom())
        let msg = try? #require(err.errorDescription)
        #expect(msg?.contains("truncated or corrupt") == true)
        #expect(msg?.contains("stream offset out of range") == true)
    }

    @Test func zipNoMinidumpsIncludesZipName() {
        let err = OpenError.zipNoMinidumps(zipName: "crashes.zip")
        let msg = try? #require(err.errorDescription)
        #expect(msg?.contains("crashes.zip") == true)
        #expect(msg?.contains(".dmp") == true)
    }

    @Test func zipParseFailedWrapsZipError() {
        let err = OpenError.zipParseFailed(.encrypted)
        let msg = try? #require(err.errorDescription)
        #expect(msg?.contains("encrypted") == true)
    }

    @Test func zipExtractFailedIncludesEntryName() {
        struct Boom: LocalizedError {
            var errorDescription: String? { "disk full" }
        }
        let err = OpenError.zipExtractFailed(entry: "crash.dmp", underlying: Boom())
        let msg = try? #require(err.errorDescription)
        #expect(msg?.contains("crash.dmp") == true)
        #expect(msg?.contains("disk full") == true)
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
