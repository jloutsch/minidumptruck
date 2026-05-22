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
