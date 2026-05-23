// Build a minimal-but-valid PDB 7.0 file in memory for tests that
// exercise the MSF container parser and the PDBPublics symbol
// extractor. No real PDB on disk; this is enough structure to round-
// trip the `[name, rva]` table that production code needs.
//
// Format reference: https://llvm.org/docs/PDB/

import Foundation
@testable import MiniDumpTruckCore

enum SyntheticPDB {

    /// One synthetic public symbol entered into the PDB's symbol
    /// record stream.
    struct Symbol {
        let name: String
        let segment: UInt16     // 1-indexed; must match a section below
        let offset: UInt32      // bytes from the section's VirtualAddress
    }

    /// A PE section the synthetic PDB will publish. The PDB's section-
    /// header substream stores these; the parser combines (segment,
    /// offset) records with this VA table to compute final RVAs.
    struct Section {
        let virtualAddress: UInt32
        let virtualSize: UInt32
    }

    /// Build a synthetic PDB. Returns the raw bytes ready to feed to
    /// `PDBPublics.parse(_:)` or `MSFFile(data:)`.
    ///
    /// Layout (block size = 4096):
    ///   block 0: SuperBlock + zeros
    ///   block 1: FPM1 (free-page map, 0xFF = all free — we don't use it)
    ///   block 2: FPM2 (alternate free-page map)
    ///   block 3: Block-map block — contains [4] (directory block list)
    ///   block 4: Directory (stream sizes + per-stream block lists)
    ///   block 5: Stream 3 (DBI)
    ///   block 6: Stream 4 (Symbol records)
    ///   block 7: Stream 5 (Section headers)
    ///
    /// Streams 0-2 exist but are empty (matches real PDBs where slots
    /// 0/1 are Old MSF/PDB-info but absent here).
    static func build(sections: [Section], symbols: [Symbol]) -> Data {
        let blockSize: UInt32 = 4096
        let blockSizeInt = Int(blockSize)

        // Build per-stream payloads first; the directory needs their
        // sizes.
        let dbiStream = buildDBIStream(
            symRecordStreamIndex: 4,
            sectionHeaderStreamIndex: 5
        )
        let symStream = buildSymbolStream(symbols)
        let sectionStream = buildSectionStream(sections)

        // Empty streams (slots 0-2). MSF spec uses 0xFFFFFFFF for
        // "absent" stream — production parsers also accept 0-length.
        let streamSizes: [UInt32] = [
            0, 0, 0,
            UInt32(dbiStream.count),
            UInt32(symStream.count),
            UInt32(sectionStream.count),
        ]
        // Block index per non-empty stream (allocated 5..7).
        let streamBlockLists: [[UInt32]] = [
            [], [], [],
            [5],
            [6],
            [7],
        ]

        // Directory bytes = NumStreams(4) + sizes(N*4) + block lists
        let numStreams = UInt32(streamSizes.count)
        var directory = Data()
        directory.append(uint32: numStreams)
        for size in streamSizes {
            directory.append(uint32: size)
        }
        for list in streamBlockLists {
            for block in list { directory.append(uint32: block) }
        }
        let numDirectoryBytes = UInt32(directory.count)

        // Block-map block at block 3 — contains a u32[] of directory
        // block indices. Our directory fits in one block, so the list
        // is [4].
        var blockMap = Data()
        blockMap.append(uint32: 4)

        // Assemble final file: 8 blocks × 4096 bytes.
        let numBlocks: UInt32 = 8
        var data = Data(count: Int(numBlocks) * blockSizeInt)

        // SuperBlock (block 0)
        writeSuperBlock(
            into: &data,
            blockSize: blockSize,
            numBlocks: numBlocks,
            numDirectoryBytes: numDirectoryBytes,
            blockMapAddr: 3
        )

        // Blocks 1+2: FPM filled with 0xFF (we don't enforce FPM
        // semantics but real-looking bytes can't hurt).
        for offset in (blockSizeInt)..<(3 * blockSizeInt) {
            data[offset] = 0xFF
        }

        // Block 3: block-map block
        data.replaceSubrange((3 * blockSizeInt)..<(3 * blockSizeInt + blockMap.count),
                             with: blockMap)

        // Block 4: directory
        data.replaceSubrange((4 * blockSizeInt)..<(4 * blockSizeInt + directory.count),
                             with: directory)

        // Block 5: DBI stream
        data.replaceSubrange((5 * blockSizeInt)..<(5 * blockSizeInt + dbiStream.count),
                             with: dbiStream)

        // Block 6: symbol records stream
        data.replaceSubrange((6 * blockSizeInt)..<(6 * blockSizeInt + symStream.count),
                             with: symStream)

        // Block 7: section headers stream
        data.replaceSubrange((7 * blockSizeInt)..<(7 * blockSizeInt + sectionStream.count),
                             with: sectionStream)

        return data
    }

    // MARK: - SuperBlock

    private static func writeSuperBlock(
        into data: inout Data,
        blockSize: UInt32,
        numBlocks: UInt32,
        numDirectoryBytes: UInt32,
        blockMapAddr: UInt32
    ) {
        // First 32 bytes: magic.
        for (i, byte) in MSFFile.magic.enumerated() {
            data[i] = byte
        }
        // Offsets 32+: SuperBlock fields (little-endian).
        data.writeLEUInt32(blockSize, at: 32)
        data.writeLEUInt32(1, at: 36)                    // FreeBlockMapBlock = 1
        data.writeLEUInt32(numBlocks, at: 40)
        data.writeLEUInt32(numDirectoryBytes, at: 44)
        data.writeLEUInt32(0, at: 48)                    // unknown
        data.writeLEUInt32(blockMapAddr, at: 52)
    }

    // MARK: - DBI stream

    private static func buildDBIStream(
        symRecordStreamIndex: UInt16,
        sectionHeaderStreamIndex: UInt16
    ) -> Data {
        // Header (64 bytes), then optional-header substream (22 bytes
        // = 11 u16 indices).
        var data = Data(count: 64 + 22)
        // signature
        data.writeLEUInt32(0xFFFF_FFFF, at: 0)          // i32 -1
        // version
        data.writeLEUInt32(19990903, at: 4)
        // age
        data.writeLEUInt32(1, at: 8)
        // globalStreamIndex (unused here)
        data.writeLEUInt16(0xFFFF, at: 12)
        // buildNumber
        data.writeLEUInt16(0, at: 14)
        // publicStreamIndex (unused; we read S_PUB32 directly from symRecord)
        data.writeLEUInt16(0xFFFF, at: 16)
        // pdbDllVersion
        data.writeLEUInt16(0, at: 18)
        // symRecordStream
        data.writeLEUInt16(symRecordStreamIndex, at: 20)
        // pdbDllRbld
        data.writeLEUInt16(0, at: 22)
        // modInfoSize, secContrSize, sectionMapSize, sourceInfoSize,
        // typeServerMapSize, mfcTypeServerIndex — all 0 for the
        // minimal PDB. The parser walks past these substreams in order.
        data.writeLEUInt32(0, at: 24)
        data.writeLEUInt32(0, at: 28)
        data.writeLEUInt32(0, at: 32)
        data.writeLEUInt32(0, at: 36)
        data.writeLEUInt32(0, at: 40)
        data.writeLEUInt32(0, at: 44)
        // optionalDbgHeaderSize: 11 u16 slots = 22 bytes
        data.writeLEUInt32(22, at: 48)
        // ecSubstreamSize
        data.writeLEUInt32(0, at: 52)
        // flags, machine, padding
        data.writeLEUInt16(0, at: 56)
        data.writeLEUInt16(0, at: 58)
        data.writeLEUInt32(0, at: 60)

        // Optional debug header substream — fills bytes [64..86).
        // Slot 5 (section header stream index) is what we care about.
        for slot in 0..<11 {
            let value: UInt16 = (slot == 5) ? sectionHeaderStreamIndex : 0xFFFF
            data.writeLEUInt16(value, at: 64 + slot * 2)
        }
        return data
    }

    // MARK: - Symbol record stream

    private static func buildSymbolStream(_ symbols: [Symbol]) -> Data {
        var data = Data()
        for sym in symbols {
            // Build the S_PUB32 payload first to compute length.
            // Payload = flags(4) + offset(4) + segment(2) + name + nul.
            // The record's `length` field is the count of bytes after
            // the length field itself (so kind + payload).
            let nameBytes = Array(sym.name.utf8) + [0]   // null-terminated
            // Record body is kind(2) + 4+4+2 + name.
            var bodyLen = 2 + 4 + 4 + 2 + nameBytes.count
            // Records are 4-byte aligned. Pad the body so total record
            // (length(2) + body) is a multiple of 4.
            let total = 2 + bodyLen
            let padded = (total + 3) & ~3
            let padding = padded - total
            bodyLen += padding

            var rec = Data()
            rec.append(uint16: UInt16(bodyLen))     // length field
            rec.append(uint16: 0x110E)              // S_PUB32
            rec.append(uint32: 0x2)                 // flags: function
            rec.append(uint32: sym.offset)
            rec.append(uint16: sym.segment)
            rec.append(contentsOf: nameBytes)
            rec.append(contentsOf: [UInt8](repeating: 0, count: padding))
            data.append(rec)
        }
        return data
    }

    // MARK: - Section header stream

    private static func buildSectionStream(_ sections: [Section]) -> Data {
        var data = Data()
        let entrySize = 40
        for section in sections {
            var entry = Data(count: entrySize)
            // bytes 0-7: name — use ".text\0\0\0" placeholder
            let nameBytes: [UInt8] = [0x2E, 0x74, 0x65, 0x78, 0x74, 0x00, 0x00, 0x00]
            for (i, b) in nameBytes.enumerated() { entry[i] = b }
            entry.writeLEUInt32(section.virtualSize, at: 8)
            entry.writeLEUInt32(section.virtualAddress, at: 12)
            // Remaining 24 bytes (SizeOfRawData..Characteristics) are
            // zero — fine for our parser which only reads VA/VSize.
            data.append(entry)
        }
        return data
    }
}

// MARK: - Tiny Data append helpers

private extension Data {
    mutating func append(uint16 value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
    }
    mutating func append(uint32 value: UInt32) {
        for i in 0..<4 { append(UInt8((value >> (i * 8)) & 0xFF)) }
    }
}
