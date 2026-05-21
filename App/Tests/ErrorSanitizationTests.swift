import Foundation
import Testing
@testable import MiniDumpTruckCore

@Suite("ErrorSanitization")
struct ErrorSanitizationTests {

    // MARK: - String.sanitizedForOutput

    @Test func passesThroughPrintableAscii() {
        let s = "crash.dmp: file not found"
        #expect(s.sanitizedForOutput() == s)
    }

    @Test func stripsAnsiEscapeSequences() {
        // ESC [ 2 J — clear screen, common terminal attack
        let injected = "good.dmp\u{001B}[2J"
        let result = injected.sanitizedForOutput()
        #expect(!result.contains("\u{001B}"))
        #expect(result.contains("good.dmp"))
    }

    @Test func stripsEmbeddedNewlines() {
        // Newline in a filename would forge a second log line.
        let injected = "good.dmp\nFAKE LOG: admin authenticated"
        let result = injected.sanitizedForOutput()
        #expect(!result.contains("\n"))
        #expect(result.contains("good.dmp"))
        #expect(result.contains("FAKE LOG"))  // text survives, newline gone
    }

    @Test func stripsRtlOverride() {
        // RLO can make "evil.exe.dmp" render as "evilpmd.exe" — text is
        // preserved but the override is gone.
        let injected = "report\u{202E}gnp.exe"
        let result = injected.sanitizedForOutput()
        #expect(!result.unicodeScalars.contains { $0.value == 0x202E })
    }

    @Test func stripsLtrAndRtlMarks() {
        let s = "name\u{200E}\u{200F}.dmp"
        let result = s.sanitizedForOutput()
        #expect(!result.unicodeScalars.contains { $0.value == 0x200E })
        #expect(!result.unicodeScalars.contains { $0.value == 0x200F })
    }

    @Test func stripsBidiIsolates() {
        // FSI / PDI used for directional isolation attacks
        let s = "a\u{2066}b\u{2069}c"
        let result = s.sanitizedForOutput()
        #expect(result == "abc")
    }

    @Test func stripsDelAndC1Controls() {
        let s = "a\u{007F}b\u{0085}c"  // DEL + NEL
        #expect(s.sanitizedForOutput() == "abc")
    }

    @Test func preservesTab() {
        // Tabs are legitimate output formatting; keep them.
        let s = "col1\tcol2"
        #expect(s.sanitizedForOutput() == s)
    }

    @Test func capsLengthWithEllipsis() {
        let s = String(repeating: "a", count: 600)
        let result = s.sanitizedForOutput(maxLength: 100)
        #expect(result.count == 101)  // 100 chars + ellipsis
        #expect(result.hasSuffix("…"))
    }

    @Test func preservesUnicodeText() {
        // Non-ASCII content is fine — only control chars/bidi are stripped.
        let s = "日本語.dmp — résumé"
        #expect(s.sanitizedForOutput() == s)
    }

    // MARK: - ErrorSanitization.reason

    @Test func mapsFileNotFound() {
        let error = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError)
        #expect(ErrorSanitization.reason(for: error) == "file not found")
    }

    @Test func mapsPermissionDenied() {
        let error = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)
        #expect(ErrorSanitization.reason(for: error) == "permission denied")
    }

    @Test func mapsCorruptFile() {
        let error = NSError(domain: NSCocoaErrorDomain, code: NSFileReadCorruptFileError)
        #expect(ErrorSanitization.reason(for: error) == "file unreadable or corrupt")
    }

    @Test func mapsMinidumpParseError() {
        let reason = ErrorSanitization.reason(for: MinidumpParseError.invalidSignature)
        #expect(reason.contains("MDMP") || reason.contains("signature"))
    }

    @Test func realFileNotFoundDoesNotLeakPath() {
        // The whole point of the issue: Data(contentsOf:) on a missing
        // file produces an NSError whose localizedDescription embeds the
        // absolute path. Verify our wrapper strips it.
        let url = URL(fileURLWithPath: "/Users/secret/private/path/missing.dmp")
        do {
            _ = try Data(contentsOf: url)
            Issue.record("expected Data(contentsOf:) to throw")
        } catch {
            let safe = ErrorSanitization.reason(for: error)
            #expect(!safe.contains("/Users/secret"))
            #expect(!safe.contains("private"))
            #expect(safe == "file not found")
        }
    }

    @Test func unknownDomainFallsBackToSanitizedDescription() {
        let raw = NSError(domain: "com.example.something", code: 42, userInfo: [
            NSLocalizedDescriptionKey: "oops\u{001B}[2J\nFAKE LINE"
        ])
        let reason = ErrorSanitization.reason(for: raw)
        #expect(!reason.contains("\u{001B}"))
        #expect(!reason.contains("\n"))
    }
}
