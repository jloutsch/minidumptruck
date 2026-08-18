import Foundation

/// Sanitizes error strings destined for terminal output, logs, or any
/// surface where a responder might paste the text into a ticket. Two
/// concerns:
///
/// 1. Path leakage: `Data(contentsOf:)` failures render localized
///    descriptions like "The file ... couldn't be opened because there
///    is no such file" with the **full absolute path** embedded —
///    leaking `$HOME`, username, mount points to whoever sees the log.
/// 2. Terminal injection: filenames are user-controlled. Embedded ANSI
///    escapes, RTL overrides, line/paragraph separators, or zero-width
///    chars can corrupt terminal output and forge log lines.
///
/// ## Callers
/// Use at any surface where an error string is shown, written, or
/// copied — stderr and CLI batch error lines, file-log writers,
/// exported report files, and user-facing alert text.
///
/// AppKit/SwiftUI alerts render control characters safely on their
/// own, so for the *injection* concern they need no help. They are
/// still callers because of the *disclosure* concern: an alert that
/// interpolates `localizedDescription` puts the user's absolute path
/// on screen, and from there into a screenshot or a pasted ticket.
/// `OpenError.errorDescription` routes through `reason(for:)` for
/// exactly that reason.
public enum ErrorSanitization {
    /// Default cap for general output strings (error reasons, etc.).
    public static let defaultMaxLength = 512
    /// Cap for filename display on stderr. macOS filename limit is 255
    /// UTF-8 bytes; this is a grapheme cap, so a multi-byte name may
    /// truncate sooner than the FS limit — acceptable for display.
    public static let filenameMaxLength = 255

    /// Map a thrown error to a short, path-free, human-readable reason
    /// suitable for stderr output. Known domains map to fixed strings;
    /// unknown domains return a generic `<domain>:<code>` marker rather
    /// than echoing `localizedDescription` (which routinely embeds
    /// absolute paths or URLs).
    public static func reason(for error: Error) -> String {
        // MinidumpParser errors are categorical, but the .parseError
        // case carries an arbitrary String — sanitize defensively in
        // case a future caller embeds dump-derived bytes.
        if let parseError = error as? MinidumpParseError {
            return (parseError.errorDescription ?? "parse failed").sanitizedForOutput()
        }

        // ZipError descriptions are app-authored constants interpolating
        // only integers and fixed strings — no paths, filenames, or dump
        // bytes — and they carry the only actionable guidance the user
        // gets ("extract it with the password first"). Collapsing them to
        // a domain marker would buy no disclosure protection and lose all
        // of that, so keep the text and bound it like the parser case.
        if let zipError = error as? ZipError {
            return (zipError.errorDescription ?? "zip error").sanitizedForOutput()
        }

        let ns = error as NSError

        if ns.domain == NSCocoaErrorDomain {
            switch ns.code {
            case NSFileReadNoSuchFileError, NSFileNoSuchFileError:
                return "file not found"
            case NSFileReadNoPermissionError, NSFileWriteNoPermissionError:
                return "permission denied"
            case NSFileReadCorruptFileError, NSFileReadUnknownError:
                return "file unreadable or corrupt"
            case NSFileReadTooLargeError:
                return "file too large"
            case NSFileReadInapplicableStringEncodingError:
                return "file encoding not recognized"
            default:
                return "I/O error"
            }
        }

        if ns.domain == NSPOSIXErrorDomain {
            return "I/O error (errno \(ns.code))"
        }

        if ns.domain == NSURLErrorDomain {
            return "network error (\(ns.code))"
        }

        // Unknown domain. Never echo localizedDescription — it can
        // embed paths, URLs, or other user-routed content. Domain +
        // code is non-sensitive and aids debugging.
        return "error (\(ns.domain): \(ns.code))"
    }
}

public extension String {
    /// Strip ASCII control characters (except tab), DEL, C1 controls,
    /// bidi formatting marks, zero-width / format chars, and line/
    /// paragraph separators. Cap length with ellipsis.
    func sanitizedForOutput(maxLength: Int = ErrorSanitization.defaultMaxLength) -> String {
        let cleaned = unicodeScalars.compactMap { scalar -> Character? in
            Self.disallowedScalars.contains(scalar.value) ? nil : Character(scalar)
        }
        let result = String(cleaned)
        if result.count > maxLength {
            return String(result.prefix(maxLength)) + "…"
        }
        return result
    }

    /// Membership test for the disallowed-scalar policy. Centralized so
    /// future additions (new Unicode bidi marks, etc.) live in one place.
    static func disallowedScalar(_ value: UInt32) -> Bool {
        // C0 controls except TAB (0x09)
        if value < 0x20 && value != 0x09 { return true }
        // DEL
        if value == 0x7F { return true }
        // C1 controls
        if value >= 0x80 && value <= 0x9F { return true }
        // Bidi formatting marks
        switch value {
        case 0x200E, 0x200F,                  // LRM, RLM
             0x202A, 0x202B, 0x202C,          // LRE, RLE, PDF
             0x202D, 0x202E,                  // LRO, RLO
             0x2066, 0x2067, 0x2068, 0x2069,  // LRI, RLI, FSI, PDI
             0x061C:                          // ALM
            return true
        // Zero-width / format chars (homoglyph + identifier-forgery vectors)
        case 0x200B, 0x200C, 0x200D,          // ZWSP, ZWNJ, ZWJ
             0xFEFF,                          // BOM / ZWNBSP
             0x180E:                          // Mongolian vowel separator
            return true
        // Line / paragraph separators — interpreted as newlines by many
        // log aggregators and JSON parsers.
        case 0x2028, 0x2029:
            return true
        default:
            break
        }
        // Variation selectors (used for invisible glyph variants)
        if value >= 0xFE00 && value <= 0xFE0F { return true }
        if value >= 0xE0100 && value <= 0xE01EF { return true }
        // Tag characters (invisible Unicode tags)
        if value >= 0xE0000 && value <= 0xE007F { return true }
        // Unicode noncharacters: invalid in interchange per Unicode TR.
        // Used as anti-forensics markers and known to break XML/HTML
        // parsers and JSON tooling.
        if value >= 0xFDD0 && value <= 0xFDEF { return true }
        // Per-plane noncharacters U+xFFFE / U+xFFFF (planes 0-16).
        let planeLow = value & 0xFFFF
        if (planeLow == 0xFFFE || planeLow == 0xFFFF) && value <= 0x10FFFF { return true }
        return false
    }

    private struct DisallowedSet {
        func contains(_ value: UInt32) -> Bool {
            String.disallowedScalar(value)
        }
    }

    private static let disallowedScalars = DisallowedSet()
}
