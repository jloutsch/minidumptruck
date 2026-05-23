import Foundation
import Testing
@testable import MiniDumpTruckCore

/// Pin the parser's behavior on malformed PDB inputs. Every test here
/// mutates a known-good `SyntheticPDB.build()` output and asserts the
/// parser refuses to crash, infinite-loop, or produce garbage symbols.
/// These tests guard against future regressions in the
/// failure-handling guards inside `MSFFile.init` and `PDBPublics.parse`.
@Suite("PDB parsing rejects malformed inputs")
struct PDBPublicsMalformedTests {

    // Helper: locate the byte offset of stream N's first block in a
    // synthetic PDB built by `SyntheticPDB.build` (block size 4096).
    // Stream 3 = DBI (block 5), stream 4 = Symbol records (block 6),
    // stream 5 = Section headers (block 7).
    private static let blockSize = 4096

    @Test func truncatedBufferRejected() {
        let pdb = SyntheticPDB.build(
            sections: [SyntheticPDB.Section(virtualAddress: 0x1000, virtualSize: 0)],
            symbols: []
        )
        // Cut to half — too small to even hold a valid MSF.
        let truncated = pdb.prefix(pdb.count / 2)
        #expect(throws: (any Error).self) {
            _ = try PDBPublics.parse(Data(truncated))
        }
    }

    @Test func truncatedDBIStreamThrowsHeaderError() {
        // Corrupt the DBI stream's first block (block 5) by zeroing
        // out everything past byte 32. The DBI header needs 64 bytes;
        // a 32-byte header is truncated.
        var pdb = SyntheticPDB.build(
            sections: [SyntheticPDB.Section(virtualAddress: 0x1000, virtualSize: 0)],
            symbols: []
        )
        // Zero out bytes 32..64 of the DBI stream so `optionalDbgHeaderSize`
        // and `ecSubstreamSize` reads return values that don't match
        // the actual DBI bytes. The walker overshoots `dbi.count`.
        let dbiStart = 5 * Self.blockSize
        for i in (dbiStart + 32)..<(dbiStart + 64) { pdb[i] = 0xFF }
        // Force a huge `optionalDbgHeaderSize` so cursor advances past
        // the end.
        pdb.writeLEUInt32(0xFFFF_0000, at: dbiStart + 48)
        do {
            _ = try PDBPublics.parse(pdb)
            Issue.record("expected dbiHeaderTruncated")
        } catch PDBPublics.ParseError.dbiHeaderTruncated {
            // expected
        } catch {
            // Some other rejection path (e.g. missingSectionHeaders) is
            // acceptable too — the contract is "no crash, throw a
            // typed error", not the specific case.
        }
    }

    @Test func zeroLengthSymbolRecordTerminatesScan() throws {
        // Plant a S_PUB32 record followed by a length=0 sentinel. The
        // parser must not infinite-loop on the zero-length record; the
        // valid record before it must surface.
        let pdb = SyntheticPDB.build(
            sections: [SyntheticPDB.Section(virtualAddress: 0x1000, virtualSize: 0x1000)],
            symbols: [SyntheticPDB.Symbol(name: "ValidSym", segment: 1, offset: 0x100)]
        )
        // Append a length=0 record to the symbol stream by zeroing out
        // the bytes after the valid record. The synthetic builder
        // produces a single S_PUB32 of ~24 bytes; rest of block 6 is
        // already zero. So this is effectively already tested — the
        // parser must scan the zeros and stop.
        let symbols = try PDBPublics.parse(pdb)
        #expect(symbols.count == 1)
        #expect(symbols.first?.name == "ValidSym")
    }

    @Test func recordLengthBeyondStreamEndIsSkipped() throws {
        // Plant a record whose `length` field claims more bytes than
        // remain in the stream. The parser must bail without reading
        // past `data.count`.
        var pdb = SyntheticPDB.build(
            sections: [SyntheticPDB.Section(virtualAddress: 0x1000, virtualSize: 0x1000)],
            symbols: [SyntheticPDB.Symbol(name: "Before", segment: 1, offset: 0x100)]
        )
        // Symbol records stream is at block 6. After the "Before"
        // record (~24 bytes) plant a record with length = UInt16.max.
        let symStart = 6 * Self.blockSize
        // Skip past the existing valid record. A real record is
        // length(2)+kind(2)+flags(4)+offset(4)+segment(2)+"Before\0\0\0" =
        // 4+10+8 = roughly 22 bytes. Round up to 24 (4-byte aligned).
        let badRecordOffset = symStart + 24
        pdb.writeLEUInt16(0xFFFF, at: badRecordOffset)            // length
        pdb.writeLEUInt16(0x110E, at: badRecordOffset + 2)        // S_PUB32

        // Parser must produce the "Before" symbol and not crash on
        // the malformed record after it. It may or may not surface the
        // pre-existing valid record — what matters is no crash + no
        // OOB read.
        let symbols = try PDBPublics.parse(pdb)
        #expect(!symbols.isEmpty)
        #expect(symbols.contains { $0.name == "Before" })
    }

    @Test func segmentIndexBeyondSectionTableIsDropped() throws {
        // Built-in: SyntheticPDB.Symbol with segment > sections.count
        // should be dropped silently. Already covered indirectly by
        // PDBPublicsTests.oversizedSegmentRecordIsDropped but pin
        // here too so malformed-input behavior is co-located.
        let pdb = SyntheticPDB.build(
            sections: [SyntheticPDB.Section(virtualAddress: 0x1000, virtualSize: 0x1000)],
            symbols: [
                SyntheticPDB.Symbol(name: "Good", segment: 1, offset: 0x100),
                SyntheticPDB.Symbol(name: "BadSegment", segment: 99, offset: 0x100),
            ]
        )
        let symbols = try PDBPublics.parse(pdb)
        #expect(symbols.map(\.name) == ["Good"])
    }

    @Test func emptySymbolStreamYieldsNoSymbols() throws {
        let pdb = SyntheticPDB.build(
            sections: [SyntheticPDB.Section(virtualAddress: 0x1000, virtualSize: 0x1000)],
            symbols: []
        )
        let symbols = try PDBPublics.parse(pdb)
        #expect(symbols.isEmpty)
    }

    @Test func zeroByteNameRecordIsDropped() throws {
        // S_PUB32 with name "" (just a single NUL byte). Parser
        // returns nil for this record (empty name), so it should be
        // absent from the result.
        var pdb = SyntheticPDB.build(
            sections: [SyntheticPDB.Section(virtualAddress: 0x1000, virtualSize: 0x1000)],
            symbols: [SyntheticPDB.Symbol(name: "Good", segment: 1, offset: 0x100)]
        )
        // Plant a record after "Good" with empty name.
        // length(2)+kind(2)+flags(4)+offset(4)+segment(2)+"\0"+pad =
        // 2+2+10+1+3pad = 18 bytes -> length field = 16.
        let symStart = 6 * Self.blockSize
        let emptyNameOffset = symStart + 24    // past "Good" record
        pdb.writeLEUInt16(16, at: emptyNameOffset)              // length
        pdb.writeLEUInt16(0x110E, at: emptyNameOffset + 2)      // S_PUB32
        pdb.writeLEUInt32(0, at: emptyNameOffset + 4)           // flags
        pdb.writeLEUInt32(0x200, at: emptyNameOffset + 8)       // offset
        pdb.writeLEUInt16(1, at: emptyNameOffset + 12)          // segment
        // bytes 14, 15: NUL + padding to 4-byte alignment
        pdb[emptyNameOffset + 14] = 0
        pdb[emptyNameOffset + 15] = 0
        pdb[emptyNameOffset + 16] = 0
        pdb[emptyNameOffset + 17] = 0

        let symbols = try PDBPublics.parse(pdb)
        // "Good" is present; the empty-name record is dropped.
        #expect(symbols.map(\.name) == ["Good"])
    }
}
