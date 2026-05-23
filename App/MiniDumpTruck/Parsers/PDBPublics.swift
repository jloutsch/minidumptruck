import Foundation

/// Extract public symbols (function names + RVAs) from a PDB 7.0 file.
///
/// This is a deliberately narrow PDB parser — we don't model types,
/// inlines, source lines, modi, or any of the rest. The goal is just
/// to convert a captured stack address into a function name, so we
/// only need:
///
/// 1. The DBI Stream Header (stream 3) — tells us which streams hold
///    the symbol records and which substream contains the PE section
///    headers.
/// 2. The Symbol Record Stream — concatenated CodeView records, of
///    which we extract `S_PUB32` entries (kind 0x110E) for public
///    symbols.
/// 3. The "section headers" optional debug-info substream — gives us
///    a PE section table so we can convert (segment, offset) into RVA.
///
/// Reference: https://llvm.org/docs/PDB/index.html
public enum PDBPublics {

    /// One resolved public symbol: a function/data name and its
    /// RVA inside the module's image.
    public struct Symbol: Hashable, Sendable {
        public let name: String
        public let rva: UInt32
    }

    public enum ParseError: Error, Sendable, Equatable {
        case missingDBIStream
        case dbiHeaderTruncated
        case missingSymbolRecordStream(Int)
        case missingSectionHeaders
        case symbolStreamTruncated
    }

    // MARK: - DBI Stream Header (64 bytes prefix we care about)
    //
    // Reference: https://llvm.org/docs/PDB/DbiStream.html#stream-header
    private struct DBIHeader {
        let symRecordStream: Int16             // u16 — stream index for symbol records
        let modInfoSize: UInt32
        let secContrSize: UInt32
        let sectionMapSize: UInt32
        let sourceInfoSize: UInt32
        let typeServerMapSize: UInt32
        let optionalDbgHeaderSize: UInt32     // bytes for optional-header substream
        let ecSubstreamSize: UInt32
    }

    /// Parse the public symbol table out of a PDB file's raw bytes.
    public static func parse(_ pdbData: Data) throws -> [Symbol] {
        let msf = try MSFFile(data: pdbData)

        // Stream 3 is always the DBI stream in a PDB.
        guard let dbi = msf.readStream(3), !dbi.isEmpty else {
            throw ParseError.missingDBIStream
        }
        let dbiHeader = try readDBIHeader(from: dbi)

        // The DBI is laid out as:
        //   Header (64 bytes)
        //   ModInfo substream
        //   SectionContribution substream
        //   SectionMap substream
        //   SourceInfo substream
        //   TypeServerMap substream
        //   ECSubstream substream
        //   OptionalDbgHeader substream  (array of u16 stream indices)
        var cursor = 64
        cursor += Int(dbiHeader.modInfoSize)
        cursor += Int(dbiHeader.secContrSize)
        cursor += Int(dbiHeader.sectionMapSize)
        cursor += Int(dbiHeader.sourceInfoSize)
        cursor += Int(dbiHeader.typeServerMapSize)
        cursor += Int(dbiHeader.ecSubstreamSize)

        guard cursor + Int(dbiHeader.optionalDbgHeaderSize) <= dbi.count else {
            throw ParseError.dbiHeaderTruncated
        }

        // OptionalDbgHeader is an array of u16 stream indices. We only
        // care about index 5 (section header stream) — slot is fixed
        // by the PDB spec. The array may be shorter than 6 entries on
        // very old PDBs, in which case section headers aren't available.
        let optHeaderCount = Int(dbiHeader.optionalDbgHeaderSize) / 2
        var sectionHeaderStreamIndex: Int? = nil
        if optHeaderCount > 5,
           let raw = dbi.readUInt16(at: cursor + 5 * 2),
           raw != 0xFFFF {
            sectionHeaderStreamIndex = Int(raw)
        }

        guard let sectionHeaderStreamIndex,
              let sectionData = msf.readStream(sectionHeaderStreamIndex)
        else { throw ParseError.missingSectionHeaders }

        let sections = parseSectionHeaders(sectionData)

        // Read the Symbol Record stream. Its index lives in the DBI header.
        let symRecordStreamIdx = Int(dbiHeader.symRecordStream)
        guard let symData = msf.readStream(symRecordStreamIdx) else {
            throw ParseError.missingSymbolRecordStream(symRecordStreamIdx)
        }

        return extractPublicSymbols(from: symData, sections: sections)
    }

    private static func readDBIHeader(from dbi: Data) throws -> DBIHeader {
        guard dbi.count >= 64 else { throw ParseError.dbiHeaderTruncated }

        // The header has many fields; we only need a handful. Offsets
        // from the LLVM reference doc (offsets in bytes from start of
        // DBI stream):
        //   0  signature (i32, expected -1)
        //   4  version (u32)
        //   8  age (u32)
        //   12 globalStreamIndex (u16)
        //   14 buildNumber (u16)
        //   16 publicStreamIndex (u16)
        //   18 pdbDllVersion (u16)
        //   20 symRecordStream (u16)
        //   22 pdbDllRbld (u16)
        //   24 modInfoSize (u32)
        //   28 secContrSize (u32)
        //   32 sectionMapSize (u32)
        //   36 sourceInfoSize (u32)
        //   40 typeServerMapSize (u32)
        //   44 mfcTypeServerIndex (u32)
        //   48 optionalDbgHeaderSize (u32)
        //   52 ecSubstreamSize (u32)
        //   56 flags (u16)
        //   58 machine (u16)
        //   60 padding (u32)

        guard let symRecord = dbi.readUInt16(at: 20),
              let modInfoSize = dbi.readUInt32(at: 24),
              let secContrSize = dbi.readUInt32(at: 28),
              let sectionMapSize = dbi.readUInt32(at: 32),
              let sourceInfoSize = dbi.readUInt32(at: 36),
              let typeServerMapSize = dbi.readUInt32(at: 40),
              let optionalDbgHeaderSize = dbi.readUInt32(at: 48),
              let ecSubstreamSize = dbi.readUInt32(at: 52)
        else { throw ParseError.dbiHeaderTruncated }

        return DBIHeader(
            symRecordStream: Int16(bitPattern: symRecord),
            modInfoSize: modInfoSize,
            secContrSize: secContrSize,
            sectionMapSize: sectionMapSize,
            sourceInfoSize: sourceInfoSize,
            typeServerMapSize: typeServerMapSize,
            optionalDbgHeaderSize: optionalDbgHeaderSize,
            ecSubstreamSize: ecSubstreamSize
        )
    }

    // MARK: - Section header parsing
    //
    // The PE section header is 40 bytes; we only need VirtualAddress
    // at offset 12 to convert (segment, offset) to RVA. Segments in
    // CodeView records are 1-indexed.
    private struct Section {
        let virtualAddress: UInt32
        let virtualSize: UInt32
    }

    private static func parseSectionHeaders(_ data: Data) -> [Section] {
        var sections: [Section] = []
        let entrySize = 40
        var offset = 0
        while offset + entrySize <= data.count {
            guard let vSize = data.readUInt32(at: offset + 8),
                  let vAddr = data.readUInt32(at: offset + 12) else { break }
            // A zero VA with zero size marks the end-of-table in some dumps.
            if vAddr == 0 && vSize == 0 && offset > 0 { break }
            sections.append(Section(virtualAddress: vAddr, virtualSize: vSize))
            offset += entrySize
        }
        return sections
    }

    // MARK: - Symbol record extraction (S_PUB32)
    //
    // The Symbol Record stream is a series of variable-length records.
    // Each record is laid out as:
    //   length (u16) — bytes after this field
    //   kind   (u16) — record type, e.g. S_PUB32 = 0x110E
    //   payload (length-2 bytes)
    //
    // S_PUB32 payload:
    //   flags    (u32)
    //   offset   (u32)
    //   segment  (u16)
    //   name     (null-terminated string, ASCII)

    private static let S_PUB32: UInt16 = 0x110E

    private static func extractPublicSymbols(
        from data: Data,
        sections: [Section]
    ) -> [Symbol] {
        var symbols: [Symbol] = []
        symbols.reserveCapacity(1024)  // typical OS DLL has 1k-10k publics
        var offset = 0

        while offset + 4 <= data.count {
            guard let length = data.readUInt16(at: offset),
                  let kind = data.readUInt16(at: offset + 2)
            else { break }

            // A length of 0 would be a parse error; bail to avoid loops.
            guard length >= 2 else { break }
            let recordEnd = offset + 2 + Int(length)
            guard recordEnd <= data.count else { break }

            if kind == S_PUB32 {
                if let sym = parseS_PUB32(
                    payloadStart: offset + 4,
                    payloadEnd: recordEnd,
                    in: data,
                    sections: sections
                ) {
                    symbols.append(sym)
                }
            }

            // Records are 4-byte-aligned. The on-disk length field is
            // typically already a multiple of 4 but we round up just
            // in case to avoid drifting.
            let alignedEnd = (recordEnd + 3) & ~3
            offset = alignedEnd
        }

        return symbols
    }

    private static func parseS_PUB32(
        payloadStart: Int,
        payloadEnd: Int,
        in data: Data,
        sections: [Section]
    ) -> Symbol? {
        guard payloadStart + 10 <= payloadEnd,
              let _ /* flags */ = data.readUInt32(at: payloadStart),
              let symOffset = data.readUInt32(at: payloadStart + 4),
              let segment = data.readUInt16(at: payloadStart + 8)
        else { return nil }

        // Segments are 1-indexed; segment 0 means "absolute" symbol
        // (not section-relative) and can't form an RVA.
        guard segment >= 1, Int(segment) <= sections.count else { return nil }
        let section = sections[Int(segment) - 1]
        let rva = section.virtualAddress &+ symOffset

        // Name starts at payloadStart + 10, null-terminated ASCII.
        //
        // Performance: avoid `data.subdata(in:)` + `String(data:encoding:)`
        // (two allocations per symbol; for a 10 k-symbol PDB that's
        // 20 k transient allocations). Use a Data slice (no copy) plus
        // `String(decoding:as:)` which builds the String directly from
        // the bytes.
        let nameStart = payloadStart + 10
        var nameEnd = nameStart
        while nameEnd < payloadEnd && data[nameEnd] != 0 {
            nameEnd += 1
        }
        guard nameStart < nameEnd else { return nil }
        let name = String(decoding: data[nameStart..<nameEnd], as: Unicode.ASCII.self)
        guard !name.isEmpty else { return nil }

        return Symbol(name: name, rva: rva)
    }
}
