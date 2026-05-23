// Build a tiny PE image in memory with .pdata + .xdata sections so
// tests can exercise the RUNTIME_FUNCTION / UNWIND_INFO parsers and
// the table-based stack walker without depending on a real Windows
// binary. The bytes match the PE-COFF spec only as far as our
// production parsers care about: DOS stub, NT signature, optional
// header data directories, and section bodies. Section headers /
// imports / relocations are omitted.
//
// All offsets here mirror what `ModuleUnwindData.locateExceptionDirectory`
// walks, which in turn matches `PEExportTable.init`.

import Foundation
@testable import MiniDumpTruckCore

enum SyntheticPE {

    /// Description of one function the synthetic PE will publish via
    /// its exception directory. `unwindCodes` is a `[UInt8]` because
    /// each UNWIND_CODE is 2 bytes; tests typically construct the
    /// bytes directly to control exact prologue semantics.
    struct Function {
        let beginRVA: UInt32      // absolute within the image
        let endRVA: UInt32
        let prologSize: UInt8     // bytes
        /// Flags + unwindCodes only. The function builds the version
        /// nibble + frameRegister byte automatically. Provide the
        /// `[UInt8]` payload starting at the first UnwindCode slot.
        let unwindCodes: [UInt8]
        let flags: UInt8          // EHANDLER / UHANDLER / CHAININFO
    }

    /// Build PE bytes describing the given functions. The returned
    /// `Data` is ready to be wrapped in a Memory64 region by
    /// `SyntheticDump` so tests can drive `ModuleUnwindData` through
    /// the dump-memory reader.
    static func build(functions: [Function]) -> Data {
        // Image layout (offsets are within the returned blob; the
        // caller maps it at some image base in dump memory):
        //
        //   0x000  DOS header
        //          - 0x00..0x02: 'M' 'Z'
        //          - 0x3C..0x40: e_lfanew = 0x80
        //   0x080  NT header
        //          - 0x00..0x04: "PE\0\0"
        //          - 0x04..0x18: 20-byte IMAGE_FILE_HEADER (zeros, except machine = AMD64)
        //          - 0x18..0x1A: optional-header magic 0x020B (PE32+)
        //          - 0x18+96 .. 0x18+96+128: data directories (16 entries × 8 bytes)
        //   0x200  .pdata section (RUNTIME_FUNCTION array)
        //   0x400  .xdata section (UNWIND_INFO records)
        //   ...    function bodies (we don't emit instructions; the
        //          walker only cares about begin/end RVAs)

        let imageSize: UInt32 = 0x4000     // 16 KB image
        let pdataRVA: UInt32 = 0x200
        let xdataBaseRVA: UInt32 = 0x400

        var image = Data(count: Int(imageSize))

        // DOS header
        image[0] = 0x4D                    // 'M'
        image[1] = 0x5A                    // 'Z'
        image.writeLEUInt32(0x80, at: 0x3C)

        // NT signature
        image[0x80] = 0x50; image[0x81] = 0x45; image[0x82] = 0x00; image[0x83] = 0x00

        // IMAGE_FILE_HEADER at 0x84 (20 bytes); machine = AMD64 (0x8664)
        image.writeLEUInt16(0x8664, at: 0x84)

        // Optional header magic at 0x98 (= 0x84 + 20)
        image.writeLEUInt16(0x020B, at: 0x98)

        // Data directory base = 0x98 + 112 = 0x108
        let dirBase = 0x108
        // Entry 3 = exception directory: RVA + size
        image.writeLEUInt32(pdataRVA, at: dirBase + 3 * 8)
        image.writeLEUInt32(UInt32(functions.count * RuntimeFunction.size), at: dirBase + 3 * 8 + 4)

        // Build .pdata + .xdata payloads side by side. Each function
        // gets one RUNTIME_FUNCTION at pdataRVA + i*12, and one
        // UNWIND_INFO record at xdataBaseRVA + cumulative byte offset.
        var xdataCursor: UInt32 = 0
        for (i, fn) in functions.enumerated() {
            let unwindInfoRVA = xdataBaseRVA + xdataCursor

            // RUNTIME_FUNCTION at pdataRVA + i*12
            let rfOff = Int(pdataRVA) + i * RuntimeFunction.size
            image.writeLEUInt32(fn.beginRVA, at: rfOff)
            image.writeLEUInt32(fn.endRVA, at: rfOff + 4)
            image.writeLEUInt32(unwindInfoRVA, at: rfOff + 8)

            // UNWIND_INFO at xdata cursor
            let codeCount = fn.unwindCodes.count / 2
            precondition(fn.unwindCodes.count.isMultiple(of: 2),
                         "unwindCodes must be an even-length byte array (each opcode is 2 bytes)")
            precondition(codeCount <= 255, "too many UnwindCodes for u8 count field")

            let uiOff = Int(unwindInfoRVA)
            // Byte 0: version (low 3 bits) = 1 ; flags (next 5 bits)
            image[uiOff] = 1 | (fn.flags << 3)
            // Byte 1: SizeOfProlog
            image[uiOff + 1] = fn.prologSize
            // Byte 2: CountOfCodes
            image[uiOff + 2] = UInt8(codeCount)
            // Byte 3: FrameRegister (low 4) | FrameOffset (high 4) = 0
            image[uiOff + 3] = 0
            // Bytes 4..: opcodes
            for (j, b) in fn.unwindCodes.enumerated() {
                image[uiOff + 4 + j] = b
            }

            // Advance the xdata cursor past this record, aligned to 4.
            let recordLen = 4 + UInt32(fn.unwindCodes.count)
            xdataCursor += (recordLen + 3) & ~3
        }

        return image
    }

    /// Helper: encode a UNWIND_CODE byte pair given the parsed fields.
    static func code(codeOffset: UInt8, op: UnwindOpCode, opInfo: UInt8) -> [UInt8] {
        [codeOffset, (op.rawValue & 0x0F) | ((opInfo & 0x0F) << 4)]
    }
}
