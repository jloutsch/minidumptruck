import Foundation

/// What `InputSniffer` decided a file is, based on its first 4 bytes.
public enum InputKind: Sendable, Equatable {
    case minidump
    case zip
    /// The first up-to-4 bytes seen; empty for an empty file.
    case unsupported(firstBytes: [UInt8])
}

/// Decides the type of an input file from its first 4 bytes. Used by the
/// open pipeline so we can drop filename-based extension checks.
public enum InputSniffer {
    /// Minidump file signature: "MDMP" in little-endian UInt32 byte order.
    static let minidumpSignature: [UInt8] = [0x4D, 0x44, 0x4D, 0x50]
    /// ZIP local file header signature: PK\x03\x04.
    static let zipSignature: [UInt8] = [0x50, 0x4B, 0x03, 0x04]

    /// Classify a chunk of bytes by its first 4 bytes.
    public static func detect(from data: Data) -> InputKind {
        let head = Array(data.prefix(4))
        if head == minidumpSignature { return .minidump }
        if head == zipSignature { return .zip }
        return .unsupported(firstBytes: head)
    }

    /// Read at most the first 4 bytes of the file and classify. Throws only
    /// on filesystem errors (file missing, permission denied, etc.).
    public static func detect(at url: URL) throws -> InputKind {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let chunk = try handle.read(upToCount: 4) ?? Data()
        return detect(from: chunk)
    }
}
