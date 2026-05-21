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
        // file produces an NSError whose localizedDescription embeds
        // the absolute path. Verify our wrapper strips it. Assertion is
        // loose — we don't require the exact mapped string, only that
        // no path component leaks. Future OS releases may change the
        // exact NSError mapping (Cocoa vs POSIX) without changing the
        // safety property.
        let url = URL(fileURLWithPath: "/Users/secret/private/path/missing-leaf.dmp")
        do {
            _ = try Data(contentsOf: url)
            Issue.record("expected Data(contentsOf:) to throw")
        } catch {
            let safe = ErrorSanitization.reason(for: error)
            #expect(!safe.contains("/Users/secret"))
            #expect(!safe.contains("private"))
            #expect(!safe.contains("missing-leaf.dmp"))
            #expect(!safe.contains("/"))
        }
    }

    @Test func unknownDomainReturnsGenericMarkerNotDescription() {
        // The whole point of the fix: even if a future error type's
        // localizedDescription embeds an absolute path, the fallback
        // must not echo it. Return a generic domain+code marker instead.
        let raw = NSError(domain: "com.example.thing", code: 42, userInfo: [
            NSLocalizedDescriptionKey: "oops at /Users/secret/path"
        ])
        let reason = ErrorSanitization.reason(for: raw)
        #expect(!reason.contains("/Users/secret"))
        #expect(!reason.contains("oops"))
        #expect(reason.contains("com.example.thing"))
        #expect(reason.contains("42"))
    }

    @Test func mapsPosixDomainProducesErrno() {
        let error = NSError(domain: NSPOSIXErrorDomain, code: 13)  // EACCES
        #expect(ErrorSanitization.reason(for: error) == "I/O error (errno 13)")
    }

    @Test func mapsUrlDomainGenericallyWithoutLeakingUrl() {
        let error = NSError(domain: NSURLErrorDomain, code: -1003, userInfo: [
            NSLocalizedDescriptionKey: "A server with the specified hostname could not be found.",
            NSURLErrorFailingURLStringErrorKey: "https://internal.corp.local/secret"
        ])
        let reason = ErrorSanitization.reason(for: error)
        #expect(!reason.contains("internal.corp.local"))
        #expect(!reason.contains("/secret"))
        #expect(reason.contains("network"))
    }

    @Test func mapsAdditionalCocoaCodes() {
        // Parametrize the table — a refactor that drops one branch must
        // fail at least one assertion.
        let cases: [(Int, String)] = [
            (NSFileNoSuchFileError, "file not found"),
            (NSFileWriteNoPermissionError, "permission denied"),
            (NSFileReadUnknownError, "file unreadable or corrupt"),
            (NSFileReadTooLargeError, "file too large"),
            (NSFileReadInapplicableStringEncodingError, "file encoding not recognized"),
            (999_999, "I/O error")  // unknown code -> safe default
        ]
        for (code, expected) in cases {
            let err = NSError(domain: NSCocoaErrorDomain, code: code)
            #expect(ErrorSanitization.reason(for: err) == expected,
                    "code \(code) should map to \"\(expected)\"")
        }
    }

    @Test func mapsMinidumpParseErrorAllVariants() {
        // .parseError(String) carries arbitrary text. The wrapper must
        // sanitize defensively in case future callers embed dump bytes.
        let injected = MinidumpParseError.parseError("bad\u{001B}[2J\nfake")
        let reason = ErrorSanitization.reason(for: injected)
        #expect(!reason.contains("\u{001B}"))
        #expect(!reason.contains("\n"))
        #expect(reason.contains("bad"))

        // .streamNotFound — display name, currently safe but covered.
        let notFound = MinidumpParseError.streamNotFound(.threadList)
        let nfReason = ErrorSanitization.reason(for: notFound)
        #expect(!nfReason.isEmpty)
        #expect(!nfReason.contains("\u{001B}"))
    }

    // MARK: - Adversarial combinations

    @Test func stripsCombinedAttackPayload() {
        // Stack every vector: ANSI + RTL override + newline + C1 + ZWSP +
        // LSEP + variation selector. The printable chars must survive.
        let evil = "a\u{001B}[31mb\u{202E}c\nd\u{0085}e\u{200B}f\u{2028}g\u{FE0F}"
        let result = evil.sanitizedForOutput()
        #expect(result == "a[31mbcdefg",
                "expected 'a[31mbcdefg', got '\(result)'")
    }

    @Test func stripsZeroWidthCharacters() {
        let s = "user\u{200B}name\u{200C}.dmp\u{200D}suffix\u{FEFF}"
        let result = s.sanitizedForOutput()
        for v: UInt32 in [0x200B, 0x200C, 0x200D, 0xFEFF] {
            #expect(!result.unicodeScalars.contains { $0.value == v },
                    "expected U+\(String(v, radix: 16)) stripped")
        }
        #expect(result.contains("username"))
    }

    @Test func stripsLineAndParagraphSeparators() {
        let s = "row1\u{2028}row2\u{2029}row3"
        let result = s.sanitizedForOutput()
        #expect(!result.unicodeScalars.contains { $0.value == 0x2028 })
        #expect(!result.unicodeScalars.contains { $0.value == 0x2029 })
        #expect(result == "row1row2row3")
    }

    @Test func stripsVariationSelectors() {
        // U+FE0F = emoji variation selector. Strips invisible variants
        // that could be used for identifier forgery.
        let s = "warn\u{FE0F}ing"
        #expect(s.sanitizedForOutput() == "warning")
    }

    @Test func sanitizationIsIdempotent() {
        let inputs = [
            "plain.dmp",
            "evil\u{001B}[2J.dmp",
            "rtl\u{202E}injection",
            "日本語.dmp",
            String(repeating: "a", count: 600)
        ]
        for input in inputs {
            let once = input.sanitizedForOutput()
            let twice = once.sanitizedForOutput()
            #expect(once == twice, "sanitization not idempotent for \(input)")
        }
    }

    @Test func lengthCapWithOnlyControlChars() {
        let s = String(repeating: "\u{0001}", count: 600)
        let result = s.sanitizedForOutput(maxLength: 100)
        #expect(result.isEmpty)
        #expect(!result.hasSuffix("…"))  // empty means no truncation needed
    }

    @Test func lengthCapBoundaryExactlyAtLimit() {
        let s = String(repeating: "a", count: 100)
        let result = s.sanitizedForOutput(maxLength: 100)
        #expect(result.count == 100)
        #expect(!result.hasSuffix("…"))
    }

    @Test func lengthCapMixedControlAndPrintable() {
        // 200 controls + 100 printables — after stripping, 100 chars,
        // exactly at cap; no ellipsis.
        let s = String(repeating: "\u{0001}", count: 200) + String(repeating: "x", count: 100)
        let result = s.sanitizedForOutput(maxLength: 100)
        #expect(result == String(repeating: "x", count: 100))
    }
}
