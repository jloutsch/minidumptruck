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
///    escapes, RTL overrides, or newlines can corrupt terminal output
///    and forge log lines.
public enum ErrorSanitization {
    /// Map a thrown error to a short, path-free, human-readable reason
    /// suitable for stderr output. Falls back to a sanitized version
    /// of the system's localized description for unknown errors.
    public static func reason(for error: Error) -> String {
        // MinidumpParser errors are already safe — they describe parse
        // failures categorically without paths.
        if let parseError = error as? MinidumpParseError {
            return parseError.errorDescription ?? "parse failed"
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

        // Unknown error domain: sanitize the localized description as a
        // last resort. Better than nothing, but `unsafeSanitized` may
        // still leak path fragments — categorize new error sources here.
        return ns.localizedDescription.sanitizedForOutput()
    }
}

public extension String {
    /// Strip ASCII control characters (except space and tab), bidi
    /// formatting marks, and cap length. Use at any presentation
    /// boundary where the string came from user-controlled or
    /// system-generated input (filenames, error descriptions, etc.).
    func sanitizedForOutput(maxLength: Int = 512) -> String {
        let cleaned = unicodeScalars.compactMap { scalar -> Character? in
            let v = scalar.value
            // C0 control chars (except tab/space): drop
            if v < 0x20 && v != 0x09 { return nil }
            // DEL
            if v == 0x7F { return nil }
            // C1 control chars
            if v >= 0x80 && v <= 0x9F { return nil }
            // Bidi formatting (RLO, LRO, isolates, embeds, marks)
            switch v {
            case 0x200E, 0x200F,                  // LRM, RLM
                 0x202A, 0x202B, 0x202C,          // LRE, RLE, PDF
                 0x202D, 0x202E,                  // LRO, RLO
                 0x2066, 0x2067, 0x2068, 0x2069:  // LRI, RLI, FSI, PDI
                return nil
            default:
                break
            }
            return Character(scalar)
        }
        let result = String(cleaned)
        if result.count > maxLength {
            return String(result.prefix(maxLength)) + "…"
        }
        return result
    }
}
