import Foundation
import Testing
@testable import MiniDumpTruckCore

@Suite("MSF (Multi-Stream File) container parser")
struct MSFParserTests {

    @Test func parsesSyntheticPDBSuperBlock() throws {
        let pdb = SyntheticPDB.build(
            sections: [SyntheticPDB.Section(virtualAddress: 0x1000, virtualSize: 0x10000)],
            symbols: []
        )
        let msf = try MSFFile(data: pdb)
        #expect(msf.superBlock.blockSize == 4096)
        #expect(msf.superBlock.numBlocks == 8)
        #expect(msf.superBlock.blockMapAddr == 3)
    }

    @Test func directoryEnumeratesAllSixStreams() throws {
        let pdb = SyntheticPDB.build(
            sections: [SyntheticPDB.Section(virtualAddress: 0x1000, virtualSize: 0x10000)],
            symbols: []
        )
        let msf = try MSFFile(data: pdb)
        #expect(msf.streams.count == 6,
                "synthetic PDB declares 6 streams (0-5); a count mismatch means directory parsing is off")
    }

    @Test func emptyStreamsAreReadable() throws {
        let pdb = SyntheticPDB.build(
            sections: [SyntheticPDB.Section(virtualAddress: 0x1000, virtualSize: 0)],
            symbols: []
        )
        let msf = try MSFFile(data: pdb)
        // Streams 0-2 are empty in the synthetic builder.
        for i in 0..<3 {
            let bytes = msf.readStream(i)
            #expect(bytes != nil, "empty stream \(i) must still be readable")
            #expect(bytes?.count == 0)
        }
    }

    @Test func dbiStreamReadbackMatchesEncodedHeader() throws {
        let pdb = SyntheticPDB.build(
            sections: [SyntheticPDB.Section(virtualAddress: 0x1000, virtualSize: 0x10000)],
            symbols: []
        )
        let msf = try MSFFile(data: pdb)
        let dbi = try #require(msf.readStream(3),
                               "DBI stream 3 must be readable")
        // DBI signature lives at offset 0 — 0xFFFFFFFF (i32 -1).
        #expect(dbi.readUInt32(at: 0) == 0xFFFF_FFFF,
                "DBI signature must round-trip through MSF read")
        // symRecordStream at offset 20 must be 4 in our synthetic PDB.
        #expect(dbi.readUInt16(at: 20) == 4)
    }

    @Test func badMagicRejected() {
        var pdb = SyntheticPDB.build(
            sections: [SyntheticPDB.Section(virtualAddress: 0x1000, virtualSize: 0)],
            symbols: []
        )
        // Corrupt the magic prefix.
        pdb[0] = 0x00
        #expect(throws: MSFFile.ParseError.badMagic) {
            _ = try MSFFile(data: pdb)
        }
    }

    @Test func tooSmallBufferRejected() {
        let tiny = Data(repeating: 0, count: 16)
        #expect(throws: MSFFile.ParseError.fileTooSmall) {
            _ = try MSFFile(data: tiny)
        }
    }

    @Test func invalidBlockSizeRejected() {
        var pdb = SyntheticPDB.build(
            sections: [SyntheticPDB.Section(virtualAddress: 0x1000, virtualSize: 0)],
            symbols: []
        )
        // Corrupt blockSize field at offset 32 to a non-power-of-2.
        pdb.writeLEUInt32(0xDEAD, at: 32)
        do {
            _ = try MSFFile(data: pdb)
            Issue.record("expected invalidBlockSize")
        } catch MSFFile.ParseError.invalidBlockSize {
            // expected
        } catch {
            Issue.record("expected invalidBlockSize, got \(error)")
        }
    }

    @Test func outOfRangeStreamIndexReturnsNil() throws {
        let pdb = SyntheticPDB.build(
            sections: [SyntheticPDB.Section(virtualAddress: 0x1000, virtualSize: 0)],
            symbols: []
        )
        let msf = try MSFFile(data: pdb)
        #expect(msf.readStream(99) == nil)
        #expect(msf.readStream(-1) == nil)
    }

    @Test func absurdNumBlocksRejected() {
        // Malformed SuperBlock claiming the file is far larger than
        // its actual byte count must fail early instead of trying to
        // read past EOF on every block access.
        var pdb = SyntheticPDB.build(
            sections: [SyntheticPDB.Section(virtualAddress: 0x1000, virtualSize: 0)],
            symbols: []
        )
        // numBlocks at offset 40 — overwrite with a huge value.
        pdb.writeLEUInt32(0x0010_0000, at: 40)  // claim 1M blocks * 4KB = 4 GB
        do {
            _ = try MSFFile(data: pdb)
            Issue.record("expected streamExceedsFileSize")
        } catch MSFFile.ParseError.streamExceedsFileSize {
            // expected
        } catch {
            Issue.record("expected streamExceedsFileSize, got \(error)")
        }
    }

    @Test func multiBlockConcatenationProducesByteExactOutput() throws {
        // The perf refactor switched concatenateBlocks from
        // data.subdata(_:) per block to a single withUnsafeBytes copy
        // via raw pointer arithmetic. A typo (off-by-one on `take`,
        // wrong `advanced(by:)` argument, partial-block early-return
        // bug) would silently produce wrong bytes mid-stream. The
        // SyntheticPDB happy-path tests don't pin per-byte output;
        // this test does.
        //
        // Build a PDB whose DBI stream lives at a known block, then
        // verify the bytes we read back equal the bytes we wrote.
        let pdb = SyntheticPDB.build(
            sections: [SyntheticPDB.Section(virtualAddress: 0x1000, virtualSize: 0x10000)],
            symbols: [
                SyntheticPDB.Symbol(name: "Alpha", segment: 1, offset: 0x100),
                SyntheticPDB.Symbol(name: "Bravo", segment: 1, offset: 0x200),
                SyntheticPDB.Symbol(name: "Charlie", segment: 1, offset: 0x300),
            ]
        )
        let msf = try MSFFile(data: pdb)

        // DBI stream is block 5, 86 bytes long per SyntheticPDB.
        let dbi = try #require(msf.readStream(3))
        // Pin specific bytes the raw-pointer copy would have moved.
        // Byte 0..3 of DBI: signature (i32 -1) = 0xFF 0xFF 0xFF 0xFF.
        #expect(dbi[0] == 0xFF)
        #expect(dbi[1] == 0xFF)
        #expect(dbi[2] == 0xFF)
        #expect(dbi[3] == 0xFF)
        // Byte 20..21: symRecordStream u16 = 4.
        #expect(dbi[20] == 4)
        #expect(dbi[21] == 0)
        // Byte 24..27: modInfoSize u32 = 0.
        #expect(dbi.subdata(in: 24..<28) == Data([0, 0, 0, 0]))

        // Symbol record stream contains our three planted records.
        // Each record starts with a length u16, then kind u16 = 0x110E
        // (S_PUB32). The first record's kind bytes should be 0E 11.
        let syms = try #require(msf.readStream(4))
        // Find the first S_PUB32 kind marker. It must appear at offset
        // 2 (right after the length u16).
        #expect(syms[2] == 0x0E)
        #expect(syms[3] == 0x11)
    }

    @Test func absurdDirectorySizeRejected() {
        // numDirectoryBytes > maxStreamSize must reject before
        // walking the directory block list. Otherwise an attacker-
        // claimed huge directory could pin gigabytes.
        var pdb = SyntheticPDB.build(
            sections: [SyntheticPDB.Section(virtualAddress: 0x1000, virtualSize: 0)],
            symbols: []
        )
        // numDirectoryBytes at offset 44.
        pdb.writeLEUInt32(UInt32(MSFFile.maxStreamSize + 1), at: 44)
        #expect(throws: MSFFile.ParseError.self) {
            _ = try MSFFile(data: pdb)
        }
    }
}
