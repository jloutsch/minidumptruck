import Foundation
import Compression
import Testing
@testable import MiniDumpTruckCore

// MARK: - Synthetic ZIP builder

/// Builds a ZIP buffer in memory: local file headers + data + central directory + EOCD.
/// Per-entry: provide name, uncompressed data, and compression method.
/// For DEFLATE, this helper does the deflation using Compression.framework.
struct SyntheticZipBuilder {
    struct Entry {
        let name: String
        let uncompressed: Data
        let method: CompressionMethod
    }

    static func build(_ entries: [Entry]) -> Data {
        var out = Data()
        struct CdMeta { let name: String; let method: CompressionMethod; let uncompressedSize: UInt32; let compressedSize: UInt32; let localHeaderOffset: UInt32; let body: Data }
        var meta: [CdMeta] = []

        for e in entries {
            let body: Data
            switch e.method {
            case .store:
                body = e.uncompressed
            case .deflate:
                body = deflate(e.uncompressed)
            }
            let offset = UInt32(out.count)
            let nameBytes = Array(e.name.utf8)
            // Local file header
            out.appendUInt32LE(0x04034B50)            // signature
            out.appendUInt16LE(20)                    // version needed
            out.appendUInt16LE(0)                     // general-purpose flags
            out.appendUInt16LE(e.method.rawValue)     // compression method
            out.appendUInt16LE(0)                     // mod time
            out.appendUInt16LE(0)                     // mod date
            out.appendUInt32LE(0)                     // CRC-32 (unused by reader)
            out.appendUInt32LE(UInt32(body.count))    // compressed size
            out.appendUInt32LE(UInt32(e.uncompressed.count))  // uncompressed size
            out.appendUInt16LE(UInt16(nameBytes.count))       // name len
            out.appendUInt16LE(0)                     // extra len
            out.append(contentsOf: nameBytes)
            out.append(body)
            meta.append(CdMeta(name: e.name, method: e.method,
                               uncompressedSize: UInt32(e.uncompressed.count),
                               compressedSize: UInt32(body.count),
                               localHeaderOffset: offset, body: body))
        }

        let cdOffset = UInt32(out.count)
        for m in meta {
            let nameBytes = Array(m.name.utf8)
            out.appendUInt32LE(0x02014B50)            // CD signature
            out.appendUInt16LE(20)                    // version made by
            out.appendUInt16LE(20)                    // version needed
            out.appendUInt16LE(0)                     // gp flags
            out.appendUInt16LE(m.method.rawValue)     // method
            out.appendUInt16LE(0); out.appendUInt16LE(0)  // mod time/date
            out.appendUInt32LE(0)                     // CRC-32
            out.appendUInt32LE(m.compressedSize)
            out.appendUInt32LE(m.uncompressedSize)
            out.appendUInt16LE(UInt16(nameBytes.count))
            out.appendUInt16LE(0)                     // extra len
            out.appendUInt16LE(0)                     // comment len
            out.appendUInt16LE(0)                     // disk number
            out.appendUInt16LE(0)                     // internal attrs
            out.appendUInt32LE(0)                     // external attrs
            out.appendUInt32LE(m.localHeaderOffset)
            out.append(contentsOf: nameBytes)
        }
        let cdSize = UInt32(out.count) - cdOffset
        // EOCD
        out.appendUInt32LE(0x06054B50)
        out.appendUInt16LE(0)                         // disk no
        out.appendUInt16LE(0)                         // disk where CD starts
        out.appendUInt16LE(UInt16(meta.count))        // records on this disk
        out.appendUInt16LE(UInt16(meta.count))        // total records
        out.appendUInt32LE(cdSize)
        out.appendUInt32LE(cdOffset)
        out.appendUInt16LE(0)                         // comment len
        return out
    }

    private static func deflate(_ input: Data) -> Data {
        if input.isEmpty { return Data() }
        let dstCapacity = max(input.count * 2, 64)
        var dst = Data(count: dstCapacity)
        let written = input.withUnsafeBytes { srcPtr -> Int in
            let src = srcPtr.bindMemory(to: UInt8.self).baseAddress!
            return dst.withUnsafeMutableBytes { dstPtr -> Int in
                let dstP = dstPtr.bindMemory(to: UInt8.self).baseAddress!
                return compression_encode_buffer(dstP, dstCapacity, src, input.count, nil, COMPRESSION_ZLIB)
            }
        }
        return dst.prefix(written)
    }
}

private extension Data {
    mutating func appendUInt16LE(_ v: UInt16) {
        append(UInt8(v & 0xFF)); append(UInt8((v >> 8) & 0xFF))
    }
    mutating func appendUInt32LE(_ v: UInt32) {
        for i in 0..<4 { append(UInt8((v >> (i*8)) & 0xFF)) }
    }
}

// MARK: - Tests

@Suite("ZipArchive happy path")
struct ZipArchiveHappyTests {
    @Test func parsesSingleStoreEntry() throws {
        let body = Data("hello world".utf8)
        let zip = SyntheticZipBuilder.build([
            .init(name: "hello.txt", uncompressed: body, method: .store)
        ])
        let archive = try ZipArchive(data: zip)
        #expect(archive.entries.count == 1)
        #expect(archive.entries[0].name == "hello.txt")
        #expect(archive.entries[0].compressionMethod == .store)
        #expect(archive.entries[0].uncompressedSize == UInt32(body.count))
        #expect(try archive.extract(archive.entries[0]) == body)
    }

    @Test func parsesSingleDeflateEntry() throws {
        let body = Data(repeating: 0x41, count: 4096)  // 4 KB of 'A' — highly compressible
        let zip = SyntheticZipBuilder.build([
            .init(name: "filler.bin", uncompressed: body, method: .deflate)
        ])
        let archive = try ZipArchive(data: zip)
        #expect(archive.entries.count == 1)
        #expect(archive.entries[0].compressionMethod == .deflate)
        #expect(archive.entries[0].uncompressedSize == UInt32(body.count))
        #expect(archive.entries[0].compressedSize < UInt32(body.count))  // actually compressed
        let extracted = try archive.extract(archive.entries[0])
        #expect(extracted == body)
    }

    @Test func parsesMultipleEntriesInCentralDirectoryOrder() throws {
        let a = Data("alpha contents".utf8)
        let b = Data("beta beta".utf8)
        let c = Data(repeating: 0x42, count: 100)
        let zip = SyntheticZipBuilder.build([
            .init(name: "a.dmp", uncompressed: a, method: .store),
            .init(name: "b.txt", uncompressed: b, method: .deflate),
            .init(name: "c.dmp", uncompressed: c, method: .store)
        ])
        let archive = try ZipArchive(data: zip)
        #expect(archive.entries.map(\.name) == ["a.dmp", "b.txt", "c.dmp"])
        #expect(try archive.extract(archive.entries[0]) == a)
        #expect(try archive.extract(archive.entries[1]) == b)
        #expect(try archive.extract(archive.entries[2]) == c)
    }

    @Test func emptyEntryRoundTrips() throws {
        let zip = SyntheticZipBuilder.build([
            .init(name: "empty.dmp", uncompressed: Data(), method: .store)
        ])
        let archive = try ZipArchive(data: zip)
        #expect(archive.entries[0].uncompressedSize == 0)
        #expect(try archive.extract(archive.entries[0]) == Data())
    }
}
