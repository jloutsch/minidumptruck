import Foundation

/// Parser/extraction errors from `ZipArchive`. Surfaced to the user via
/// `OpenError.zipParseFailed`. (The `CompressionMethod` enum lives in
/// `ZipReader.swift` alongside the parser; `ZipError.unsupportedCompression`
/// carries a raw `UInt16` so this type does not need that import.)
public enum ZipError: Error, LocalizedError, Equatable, Sendable {
    case notAZip
    case corrupted(reason: String)
    case encrypted
    case zip64Unsupported
    case unsupportedCompression(method: UInt16)
    case entryTooLarge(actual: UInt32, limit: UInt32)
    case tooManyEntries(actual: UInt64, limit: UInt64)

    public var errorDescription: String? {
        switch self {
        case .notAZip:
            return "This file is not a ZIP archive."
        case .corrupted(let reason):
            return "This ZIP appears to be corrupt: \(reason)."
        case .encrypted:
            return "This ZIP is encrypted. Extract it with the password first, then open the .dmp."
        case .zip64Unsupported:
            return "This ZIP uses the ZIP64 format (over 4 GB), which is not supported yet."
        case .unsupportedCompression(let method):
            return "This ZIP uses compression method \(method), which is not supported. Re-create the zip with standard deflate."
        case .entryTooLarge(let actual, let limit):
            return "A ZIP entry is too large to extract: \(actual) bytes (limit \(limit))."
        case .tooManyEntries(let actual, let limit):
            return "This ZIP has too many entries: \(actual) (limit \(limit))."
        }
    }
}

/// User-facing errors emitted by the input pipeline. `localizedDescription`
/// returns human-readable text suitable for an alert dialog; the raw Swift
/// type names are never shown to the user.
public enum OpenError: Error, LocalizedError, Sendable {
    case notAMinidump(firstBytes: [UInt8])
    case corruptedMinidump(underlying: Error)
    case zipParseFailed(ZipError)
    case zipNoMinidumps(zipName: String)
    case zipExtractFailed(entry: String, underlying: Error)

    public var errorDescription: String? {
        switch self {
        case .notAMinidump(let bytes):
            let hex = bytes.prefix(4).map { String(format: "%02X", $0) }.joined(separator: " ")
            return "This file does not look like a Windows minidump or a zip containing one. (First bytes: \(hex.isEmpty ? "<empty>" : hex))"
        case .corruptedMinidump(let underlying):
            let detail = underlying.localizedDescription
            return "This minidump appears to be truncated or corrupt: \(detail)."
        case .zipParseFailed(let zipError):
            return zipError.errorDescription ?? "ZIP parsing failed."
        case .zipNoMinidumps(let zipName):
            return "\(zipName) does not contain any .dmp / .mdmp / .minidump files."
        case .zipExtractFailed(let entry, let underlying):
            let detail = underlying.localizedDescription
            return "Could not extract \(entry) from the zip: \(detail)."
        }
    }
}
