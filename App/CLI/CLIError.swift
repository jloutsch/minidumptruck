import Foundation
import ArgumentParser

/// CLI-facing error categories. Each maps to a distinct exit code so
/// scripts can branch on the failure mode.
///
/// Exit codes:
///   0 — success (analysis complete, no crash exception)
///   1 — generic / invalid args (raised by ArgumentParser)
///   2 — crash detected (used by AnalyzeCommand when dump has an exception)
///   3 — parse failure, I/O error, or file rejected by size guard
enum CLIError: Error, CustomStringConvertible {
    case fileNotFound(String)
    case parseError(String)
    case ioError(String)
    case fileTooLarge(path: String, size: Int64, limit: Int64)

    var description: String {
        switch self {
        case .fileNotFound(let path):
            return "File or directory not found: \(path)"
        case .parseError(let reason):
            return "Failed to parse minidump: \(reason)"
        case .ioError(let reason):
            return "I/O error: \(reason)"
        case .fileTooLarge(let path, let size, let limit):
            let sizeMB = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
            let limitMB = ByteCountFormatter.string(fromByteCount: limit, countStyle: .file)
            return "File exceeds maximum size: \(path) is \(sizeMB) (limit \(limitMB)). Override with --max-file-size."
        }
    }

    /// Throws `ExitCode(3)` for parse/I/O/size-guard failures so scripts
    /// can distinguish a typo'd path (exit 1) from a corrupt dump (exit 3).
    /// fileNotFound stays at the default ArgumentParser exit (1).
    var exitCode: ExitCode {
        switch self {
        case .fileNotFound:
            return ExitCode(1)
        case .parseError, .ioError, .fileTooLarge:
            return ExitCode(3)
        }
    }
}
