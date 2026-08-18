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

    @Test func corruptedMinidumpIncludesParserDetail() throws {
        // Parser detail is the diagnostically useful half and must survive
        // sanitization — `reason(for:)` special-cases `MinidumpParseError`.
        let err = OpenError.corruptedMinidump(
            underlying: MinidumpParseError.parseError("stream offset out of range")
        )
        let msg = try #require(err.errorDescription)
        #expect(msg.contains("truncated or corrupt"))
        #expect(msg.contains("stream offset out of range"))
    }

    @Test func corruptedMinidumpDoesNotLeakPathFromFileError() throws {
        // A real Cocoa file error whose localizedDescription embeds the
        // user's filename. Verify it genuinely does before asserting it's
        // gone, so this cannot silently become a vacuous test. The filename
        // is the half that actually leaks on current macOS; the broader
        // path assertions guard against an OS that embeds the full path.
        let path = "/Users/someone/Secret Folder/crash.dmp"
        let underlying = NSError(
            domain: NSCocoaErrorDomain,
            code: NSFileReadNoSuchFileError,
            userInfo: [NSFilePathErrorKey: path,
                       NSURLErrorKey: URL(fileURLWithPath: path)]
        )
        #expect(underlying.localizedDescription.contains("crash.dmp"),
                "precondition: the raw description must embed the filename")

        let msg = try #require(OpenError.corruptedMinidump(underlying: underlying).errorDescription)
        #expect(msg.contains("truncated or corrupt"))
        #expect(msg.contains("file not found"))
        // The disclosure assertions — these are the point of the test.
        #expect(!msg.contains(path))
        #expect(!msg.contains("crash.dmp"))
        #expect(!msg.contains("Secret Folder"))
        #expect(!msg.contains("/Users/"))
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
        // The entry name is caller-supplied, not error-derived, so it still
        // appears. An error of an *unknown* type collapses to a domain/code
        // marker — its description could embed anything. (`ZipError`, the
        // type actually thrown on this path, is exempt; see the two tests
        // below.)
        struct Boom: LocalizedError {
            var errorDescription: String? { "disk full" }
        }
        let err = OpenError.zipExtractFailed(entry: "crash.dmp", underlying: Boom())
        let msg = try #require(err.errorDescription)
        #expect(msg.contains("crash.dmp"))
        #expect(!msg.contains("disk full"))
    }

    @Test func zipExtractFailedKeepsZipErrorGuidance() throws {
        // `ZipArchive.extract` throws `ZipError` and nothing else, so this is
        // the dominant path. The guidance is the entire value of the message;
        // a bare type-name marker would leave the user nothing to act on.
        let err = OpenError.zipExtractFailed(entry: "crash.dmp", underlying: ZipError.encrypted)
        let msg = try #require(err.errorDescription)
        #expect(msg.contains("crash.dmp"))
        #expect(msg.contains("Extract it with the password first"))
        // The invariant OpenError documents: no raw Swift type names.
        #expect(!msg.contains("ZipError"))
        #expect(!msg.contains("MiniDumpTruckCore"))
    }

    @Test func zipExtractFailedKeepsZipCorruptionReason() throws {
        let err = OpenError.zipExtractFailed(
            entry: "crash.dmp",
            underlying: ZipError.corrupted(reason: "DEFLATE stream could not be initialized")
        )
        let msg = try #require(err.errorDescription)
        #expect(msg.contains("DEFLATE stream could not be initialized"))
        #expect(!msg.contains("ZipError"))
    }

    @Test func zipExtractFailedBoundsZipErrorReason() throws {
        // `corrupted(reason:)` is the one `ZipError` case carrying a free-form
        // String, so it is the one that needs a length bound.
        let err = OpenError.zipExtractFailed(
            entry: "crash.dmp",
            underlying: ZipError.corrupted(reason: String(repeating: "X", count: 10_000))
        )
        let msg = try #require(err.errorDescription)
        #expect(msg.count < 600)
        #expect(msg.contains("…"))
    }

    @Test func zipExtractFailedDoesNotLeakPathFromFileError() throws {
        let path = "/Users/someone/Secret Folder/out.dmp"
        let underlying = NSError(
            domain: NSCocoaErrorDomain,
            code: NSFileWriteNoPermissionError,
            userInfo: [NSFilePathErrorKey: path,
                       NSURLErrorKey: URL(fileURLWithPath: path)]
        )
        #expect(underlying.localizedDescription.contains("out.dmp"),
                "precondition: the raw description must embed the filename")

        let err = OpenError.zipExtractFailed(entry: "crash.dmp", underlying: underlying)
        let msg = try #require(err.errorDescription)
        #expect(msg.contains("permission denied"))
        #expect(!msg.contains(path))
        #expect(!msg.contains("Secret Folder"))
        #expect(!msg.contains("/Users/"))
    }

    @Test func corruptedMinidumpBoundsAttackerControlledParserDetail() throws {
        // `MinidumpParseError.parseError` carries an arbitrary String and is
        // the only branch a dump-derived (attacker-controlled) message can
        // still reach. Boundedness is enforced there by `sanitizedForOutput`.
        let err = OpenError.corruptedMinidump(
            underlying: MinidumpParseError.parseError(String(repeating: "X", count: 10_000))
        )
        let msg = try #require(err.errorDescription)
        #expect(msg.count < 600)  // bounded, not 10_000+ chars
        #expect(msg.contains("…"))  // truncation marker from sanitizedForOutput
    }

    @Test func corruptedMinidumpBoundsUnknownErrorTypes() throws {
        // A non-parser error cannot produce an unbounded alert at all: it
        // collapses to a fixed-shape domain/code marker.
        struct Loud: LocalizedError {
            var errorDescription: String? { String(repeating: "X", count: 10_000) }
        }
        let msg = try #require(OpenError.corruptedMinidump(underlying: Loud()).errorDescription)
        #expect(msg.count < 200)
        #expect(!msg.contains("XXXX"))
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
