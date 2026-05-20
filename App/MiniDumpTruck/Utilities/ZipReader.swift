import Foundation
import Compression

/// Compression methods we support reading from a ZIP archive.
public enum CompressionMethod: UInt16, Sendable {
    case store = 0
    case deflate = 8
}

/// One entry in a ZIP archive's central directory.
public struct ZipEntry: Sendable, Identifiable {
    public let id: UUID
    public let name: String
    public let uncompressedSize: UInt32
    public let compressedSize: UInt32
    public let compressionMethod: CompressionMethod
    /// File offset of the local file header (used by extract).
    internal let localHeaderOffset: UInt32
    /// General-purpose bit flag from the central directory record (bit 0 = encrypted).
    internal let generalPurposeFlags: UInt16
}
// NOTE: ZipEntry is intentionally NOT Equatable. Synthesized Equatable would
// compare the UUID id, so two entries with identical content but different
// ids would be unequal — a footgun.

/// A parsed ZIP archive read from in-memory bytes.
/// Supports STORE and DEFLATE; rejects encrypted, ZIP64, and other methods
/// with a typed error.
public struct ZipArchive: Sendable {
    /// DoS bound: maximum entries parsed from one archive.
    public static let maxEntries: UInt64 = 100_000
    /// DoS bound: maximum uncompressed size of one entry. This is the ZIP
    /// non-64 structural hard limit (4 GB - 1), NOT a practical memory
    /// budget — `extract` pre-allocates this much for inflate. The current
    /// interactive-desktop use opens one dump at a time, so the cap is
    /// acceptable. Future batch-processing callers should add a tighter
    /// practical cap (e.g., 256 MB).
    public static let maxEntrySize: UInt32 = 0xFFFFFFFF
    /// DoS bound: maximum central-directory size.
    public static let maxCentralDirectorySize: UInt32 = 32 * 1024 * 1024

    public let entries: [ZipEntry]

    private let data: Data  // retained for extract()

    public init(data: Data) throws {
        self.data = data
        guard data.count >= 22 else { throw ZipError.notAZip }

        // 1. Find EOCD: signature 0x06054B50, search backwards from end.
        let eocdSig: UInt32 = 0x06054B50
        let zip64LocatorSig: UInt32 = 0x07064B50
        let maxComment = 0xFFFF
        let searchStart = max(0, data.count - 22 - maxComment)
        var eocdOffset: Int? = nil
        var i = data.count - 22
        while i >= searchStart {
            if data.readUInt32(at: i) == eocdSig {
                eocdOffset = i
                break
            }
            i -= 1
        }
        guard let eocd = eocdOffset else { throw ZipError.notAZip }

        // 2. Detect ZIP64 EOCD locator immediately before EOCD.
        if eocd >= 20, data.readUInt32(at: eocd - 20) == zip64LocatorSig {
            throw ZipError.zip64Unsupported
        }

        // 3. Read EOCD fields.
        guard let totalRecords16 = data.readUInt16(at: eocd + 10),
              let cdSize = data.readUInt32(at: eocd + 12),
              let cdOffset = data.readUInt32(at: eocd + 16) else {
            throw ZipError.corrupted(reason: "EOCD truncated")
        }
        let totalRecords = UInt64(totalRecords16)
        if totalRecords > Self.maxEntries {
            throw ZipError.tooManyEntries(actual: totalRecords, limit: Self.maxEntries)
        }
        if cdSize > Self.maxCentralDirectorySize {
            throw ZipError.corrupted(reason: "central directory too large")
        }
        let cdEnd64 = UInt64(cdOffset) + UInt64(cdSize)
        guard cdEnd64 <= UInt64(data.count) else {
            throw ZipError.corrupted(reason: "central directory exceeds file size")
        }

        // 4. Iterate central directory records.
        var entries: [ZipEntry] = []
        entries.reserveCapacity(Int(totalRecords))
        var cursor = Int(cdOffset)
        let cdRecordSig: UInt32 = 0x02014B50
        for _ in 0..<Int(totalRecords) {
            guard cursor < Int(cdEnd64) else {
                throw ZipError.corrupted(reason: "cursor escaped central directory at offset \(cursor)")
            }
            guard data.readUInt32(at: cursor) == cdRecordSig else {
                throw ZipError.corrupted(reason: "bad central directory record signature at offset \(cursor)")
            }
            guard let gpFlags = data.readUInt16(at: cursor + 8),
                  let methodRaw = data.readUInt16(at: cursor + 10),
                  let compressed = data.readUInt32(at: cursor + 20),
                  let uncompressed = data.readUInt32(at: cursor + 24),
                  let nameLen = data.readUInt16(at: cursor + 28),
                  let extraLen = data.readUInt16(at: cursor + 30),
                  let commentLen = data.readUInt16(at: cursor + 32),
                  let localOffset = data.readUInt32(at: cursor + 42) else {
                throw ZipError.corrupted(reason: "central directory record truncated at offset \(cursor)")
            }
            if (gpFlags & 0x0001) != 0 { throw ZipError.encrypted }
            guard let method = CompressionMethod(rawValue: methodRaw) else {
                throw ZipError.unsupportedCompression(method: methodRaw)
            }
            if uncompressed > Self.maxEntrySize {
                throw ZipError.entryTooLarge(actual: uncompressed, limit: Self.maxEntrySize)
            }
            let nameStart = cursor + 46
            let nameEnd = nameStart + Int(nameLen)
            guard nameEnd <= data.count else {
                throw ZipError.corrupted(reason: "filename runs past end of file")
            }
            let nameData = data[nameStart..<nameEnd]
            let name = String(data: nameData, encoding: .utf8) ?? ""

            entries.append(ZipEntry(
                id: UUID(),
                name: name,
                uncompressedSize: uncompressed,
                compressedSize: compressed,
                compressionMethod: method,
                localHeaderOffset: localOffset,
                generalPurposeFlags: gpFlags
            ))
            cursor = nameEnd + Int(extraLen) + Int(commentLen)
        }
        self.entries = entries
    }

    /// Extract one entry's uncompressed bytes.
    public func extract(_ entry: ZipEntry) throws -> Data {
        let localSig: UInt32 = 0x04034B50
        let lh = Int(entry.localHeaderOffset)
        guard lh + 30 <= data.count, data.readUInt32(at: lh) == localSig else {
            throw ZipError.corrupted(reason: "bad local file header at offset \(lh)")
        }
        guard let nameLen = data.readUInt16(at: lh + 26),
              let extraLen = data.readUInt16(at: lh + 28) else {
            throw ZipError.corrupted(reason: "local header truncated")
        }
        let dataStart = lh + 30 + Int(nameLen) + Int(extraLen)
        let dataEnd = dataStart + Int(entry.compressedSize)
        guard dataEnd <= data.count else {
            throw ZipError.corrupted(reason: "entry data runs past end of file")
        }
        let body = data.subdata(in: dataStart..<dataEnd)

        switch entry.compressionMethod {
        case .store:
            guard body.count == Int(entry.uncompressedSize) else {
                throw ZipError.corrupted(reason: "STORE size mismatch")
            }
            return body
        case .deflate:
            return try Self.inflate(body, uncompressedSize: Int(entry.uncompressedSize))
        }
    }

    /// Inflate a raw deflate stream (no zlib header) using Compression.framework.
    private static func inflate(_ compressed: Data, uncompressedSize: Int) throws -> Data {
        if uncompressedSize == 0 { return Data() }
        var dst = Data(count: uncompressedSize)
        let produced = compressed.withUnsafeBytes { srcPtr -> Int in
            let src = srcPtr.bindMemory(to: UInt8.self).baseAddress!
            return dst.withUnsafeMutableBytes { dstPtr -> Int in
                let dstP = dstPtr.bindMemory(to: UInt8.self).baseAddress!
                return compression_decode_buffer(dstP, uncompressedSize, src, compressed.count, nil, COMPRESSION_ZLIB)
            }
        }
        if produced != uncompressedSize {
            throw ZipError.corrupted(reason: "DEFLATE produced \(produced) bytes, expected \(uncompressedSize)")
        }
        return dst
    }
}
