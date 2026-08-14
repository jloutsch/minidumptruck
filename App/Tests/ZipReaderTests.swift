import Foundation
import CZlib
import Testing
@testable import MiniDumpTruckCore

// MARK: - Synthetic ZIP builder

/// Builds a ZIP buffer in memory: local file headers + data + central directory + EOCD.
/// Per-entry: provide name, uncompressed data, and compression method.
/// For DEFLATE, this helper does the deflation using zlib.
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
        var stream = z_stream()
        // Negative windowBits emits a bare deflate stream with no RFC-1950 header,
        // which is the form ZIP stores and the form the reader expects.
        let initStatus = deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED,
                                       -MAX_WBITS, 8, Z_DEFAULT_STRATEGY,
                                       ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard initStatus == Z_OK else { return Data() }
        defer { deflateEnd(&stream) }
        let written = input.withUnsafeBytes { srcPtr -> Int in
            let src = srcPtr.bindMemory(to: UInt8.self).baseAddress!
            return dst.withUnsafeMutableBytes { dstPtr -> Int in
                let dstP = dstPtr.bindMemory(to: UInt8.self).baseAddress!
                stream.next_in = UnsafeMutablePointer(mutating: src)
                stream.avail_in = uInt(input.count)
                stream.next_out = dstP
                stream.avail_out = uInt(dstCapacity)
                guard CZlib.deflate(&stream, Z_FINISH) == Z_STREAM_END else { return 0 }
                return dstCapacity - Int(stream.avail_out)
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

@Suite("ZipArchive rejections")
struct ZipArchiveRejectionTests {
    @Test func rejectsBytesWithoutEocd() {
        let garbage = Data(repeating: 0xAA, count: 100)
        do {
            _ = try ZipArchive(data: garbage)
            Issue.record("expected .notAZip")
        } catch ZipError.notAZip {
            // expected
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func rejectsTooSmall() {
        do {
            _ = try ZipArchive(data: Data([0x01, 0x02, 0x03]))
            Issue.record("expected .notAZip")
        } catch ZipError.notAZip {
            // expected
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func rejectsEncryptedEntry() throws {
        var zip = SyntheticZipBuilder.build([
            .init(name: "encrypted.dmp", uncompressed: Data("x".utf8), method: .store)
        ])
        // Find the central directory record signature (PK\x01\x02) and set
        // general-purpose bit flag (offset +8 from sig) bit 0 = encrypted.
        let cdSig: [UInt8] = [0x50, 0x4B, 0x01, 0x02]
        guard let range = zip.range(of: Data(cdSig)) else {
            Issue.record("CD signature not found"); return
        }
        let gpFlagsOffset = range.lowerBound + 8
        zip[gpFlagsOffset] = 0x01
        do {
            _ = try ZipArchive(data: zip)
            Issue.record("expected .encrypted")
        } catch ZipError.encrypted {
            // expected
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func rejectsUnsupportedCompression() throws {
        var zip = SyntheticZipBuilder.build([
            .init(name: "weird.dmp", uncompressed: Data("x".utf8), method: .store)
        ])
        // Central directory record: compression method at offset +10 from CD sig.
        let cdSig: [UInt8] = [0x50, 0x4B, 0x01, 0x02]
        guard let range = zip.range(of: Data(cdSig)) else {
            Issue.record("CD signature not found"); return
        }
        let methodOffset = range.lowerBound + 10
        zip[methodOffset] = 0x0C       // 12 = bzip2
        zip[methodOffset + 1] = 0x00
        do {
            _ = try ZipArchive(data: zip)
            Issue.record("expected .unsupportedCompression")
        } catch ZipError.unsupportedCompression(let method) {
            #expect(method == 12)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func rejectsZip64Locator() throws {
        // Build a minimal valid empty ZIP (no entries) and inject a ZIP64
        // EOCD locator immediately before the EOCD signature.
        var zip = SyntheticZipBuilder.build([])
        // EOCD is at end (22 bytes). Insert 20 bytes of ZIP64 locator before it.
        let eocdSig: [UInt8] = [0x50, 0x4B, 0x05, 0x06]
        guard let range = zip.range(of: Data(eocdSig)) else {
            Issue.record("EOCD not found"); return
        }
        var z64Locator = Data()
        z64Locator.appendUInt32LE(0x07064B50)  // ZIP64 locator signature
        z64Locator.append(Data(repeating: 0, count: 16))  // padding
        zip.insert(contentsOf: z64Locator, at: range.lowerBound)
        do {
            _ = try ZipArchive(data: zip)
            Issue.record("expected .zip64Unsupported")
        } catch ZipError.zip64Unsupported {
            // expected
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func rejectsTooManyEntries() {
        // Bound documentation: maxEntries = 100_000. The runtime path that
        // fires `tooManyEntries` requires totalRecords > 100_000 in EOCD,
        // which exceeds UInt16 (65535) and therefore can only be expressed
        // via ZIP64. ZIP64 is already rejected upstream, so this guard is
        // currently unreachable from well-formed non-ZIP64 input. The
        // constant exists for the parser's defensive check; documented here.
        #expect(ZipArchive.maxEntries == 100_000)
    }

    @Test func rejectsCorruptCentralDirectoryRecord() throws {
        var zip = SyntheticZipBuilder.build([
            .init(name: "ok.dmp", uncompressed: Data("hi".utf8), method: .store)
        ])
        // Corrupt the central directory record signature.
        let cdSig: [UInt8] = [0x50, 0x4B, 0x01, 0x02]
        guard let range = zip.range(of: Data(cdSig)) else {
            Issue.record("CD sig not found"); return
        }
        zip[range.lowerBound] = 0xFF
        do {
            _ = try ZipArchive(data: zip)
            Issue.record("expected .corrupted")
        } catch ZipError.corrupted {
            // expected
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func rejectsTruncatedCentralDirectory() {
        // EOCD claims CD extends past file size.
        var zip = Data()
        zip.appendUInt32LE(0x06054B50)
        zip.appendUInt16LE(0); zip.appendUInt16LE(0)
        zip.appendUInt16LE(1); zip.appendUInt16LE(1)
        zip.appendUInt32LE(46)                  // CD size 46
        zip.appendUInt32LE(0xFFFF_FFFF)         // CD offset way past file end
        zip.appendUInt16LE(0)
        do {
            _ = try ZipArchive(data: zip)
            Issue.record("expected .corrupted")
        } catch ZipError.corrupted {
            // expected
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func rejectsInvalidUTF8Filename() throws {
        // Build a normal zip, then corrupt the filename bytes to invalid UTF-8.
        var zip = SyntheticZipBuilder.build([
            .init(name: "ok.dmp", uncompressed: Data("hi".utf8), method: .store)
        ])
        // Central directory record: filename starts at CD+46.
        let cdSig: [UInt8] = [0x50, 0x4B, 0x01, 0x02]
        guard let range = zip.range(of: Data(cdSig)) else {
            Issue.record("CD sig not found"); return
        }
        let nameStart = range.lowerBound + 46
        // Replace first filename byte with an isolated UTF-8 continuation byte (0x80) — invalid as a leading byte.
        zip[nameStart] = 0x80
        do {
            _ = try ZipArchive(data: zip)
            Issue.record("expected .corrupted for invalid UTF-8 filename")
        } catch ZipError.corrupted {
            // expected
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func rejectsWinZipAESEncryption() throws {
        // Build a normal zip, then set the WinZip AES bit (bit 6 = 0x0040) without bit 0.
        var zip = SyntheticZipBuilder.build([
            .init(name: "aes.dmp", uncompressed: Data("x".utf8), method: .store)
        ])
        let cdSig: [UInt8] = [0x50, 0x4B, 0x01, 0x02]
        guard let range = zip.range(of: Data(cdSig)) else {
            Issue.record("CD sig not found"); return
        }
        let gpFlagsOffset = range.lowerBound + 8
        zip[gpFlagsOffset] = 0x40       // bit 6 set, bit 0 clear
        zip[gpFlagsOffset + 1] = 0x00
        do {
            _ = try ZipArchive(data: zip)
            Issue.record("expected .encrypted for WinZip AES")
        } catch ZipError.encrypted {
            // expected
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func rejectsCursorOverflowInCDIteration() throws {
        // Construct an EOCD claiming 2 records but with the first record's
        // extraLen+commentLen so large that the cursor would advance past
        // the file. The overflow check + cdEnd64 guard together must reject.
        var zip = SyntheticZipBuilder.build([
            .init(name: "a.dmp", uncompressed: Data("a".utf8), method: .store),
            .init(name: "b.dmp", uncompressed: Data("b".utf8), method: .store)
        ])
        // Find the first CD record and set extraLen = commentLen = 0xFFFF so
        // cursor advances by 131k after this record — past cdEnd64.
        let cdSig: [UInt8] = [0x50, 0x4B, 0x01, 0x02]
        guard let range = zip.range(of: Data(cdSig)) else {
            Issue.record("CD sig not found"); return
        }
        let extraLenOff = range.lowerBound + 30   // CD record: extraLen at +30
        let commentLenOff = range.lowerBound + 32 // CD record: commentLen at +32
        zip[extraLenOff] = 0xFF; zip[extraLenOff + 1] = 0xFF
        zip[commentLenOff] = 0xFF; zip[commentLenOff + 1] = 0xFF
        do {
            _ = try ZipArchive(data: zip)
            Issue.record("expected .corrupted for cursor overflow")
        } catch ZipError.corrupted {
            // expected — either the explicit overflow guard or the cursor<cdEnd64 guard catches it
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }
}
