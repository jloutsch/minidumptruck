// Shared synthetic-minidump builder for test fixtures.
//
// Both AMD64 and ARM64 tests need a minimal but realistic minidump to
// drive CrashAnalyzer end-to-end: header + directory + Exception +
// ThreadList + ModuleList + Memory64List + a context blob. The only
// real difference between the two is the context size (1232 vs 912)
// and which register fields the test wants to populate.
//
// This builder owns the entire byte layout — header offsets, stream
// directory, all stream framing — so a future minidump-format change
// touches one place instead of two. Each caller provides a closure
// that writes the architecture-specific context payload.

import Foundation
@testable import MiniDumpTruckCore

enum SyntheticDump {
    /// Build a complete synthetic Windows minidump and parse it into a
    /// `ParsedMinidump`. The dump always carries: an Exception stream
    /// (so `CrashAnalyzer.analyze()` will run), a single thread with
    /// the supplied stack range, a single module covering
    /// `[moduleBase, moduleBase + moduleSize)`, and a Memory64List
    /// region covering `[stackBase, stackBase + stackSize + memoryExtraBytes)`.
    ///
    /// `contextWriter` is invoked with a mutable reference to the
    /// constructed `Data` and the absolute offset where the context
    /// blob begins. The closure should write architecture-specific
    /// registers at fixed offsets relative to that base.
    ///
    /// `stackData`, when provided, replaces the bytes in the Memory64
    /// region (starting at `stackBase`) so callers can plant frame
    /// records, return addresses, or other stack content.
    ///
    /// `memoryExtraBytes` extends the Memory64 region BEYOND the
    /// declared `thread.stack` range, used by range-guard tests that
    /// need bytes readable at addresses the walker's range check must
    /// reject.
    static func build(
        contextSize: Int,
        exceptionCode: UInt32 = 0xC0000005,
        exceptionAddress: UInt64 = 0x7FF8_1000_1234,
        exceptionParams: [UInt64] = [0, 0xDEAD],
        moduleName: String = "test.dll",
        moduleBase: UInt64 = 0x7FF8_1000_0000,
        moduleSize: UInt32 = 0x10_0000,
        stackBase: UInt64 = 0x0008_0000,
        stackSize: UInt32 = 0x1_0000,
        memoryExtraBytes: UInt32 = 0,
        stackData: Data? = nil,
        contextWriter: (inout Data, Int) -> Void
    ) throws -> ParsedMinidump {
        precondition(stackData == nil || stackData!.count <= Int(stackSize) + Int(memoryExtraBytes),
                     "stackData must fit inside the declared memory region")
        precondition(exceptionParams.count <= 15,
                     "MINIDUMP_EXCEPTION carries at most 15 parameters")

        let headerSize = 32
        let dirCount: UInt32 = 4
        let dirSize = Int(dirCount) * 12
        let exRva = UInt32(headerSize + dirSize)
        let threadRva = exRva + 168
        let moduleRva = threadRva + 4 + 48
        let moduleNameUtf16 = Array(moduleName.utf16)
        let moduleNameBytes = 4 + moduleNameUtf16.count * 2
        let moduleNameStart = moduleRva + 4 + 108
        let contextRva = moduleNameStart + UInt32(moduleNameBytes) + 4  // align
        let m64Rva = contextRva + UInt32(contextSize)
        let m64DataStart = m64Rva + 16 + 16  // header + 1 descriptor
        let memoryRegionSize = stackSize + memoryExtraBytes
        let totalSize = Int(m64DataStart) + Int(memoryRegionSize)

        var data = Data(repeating: 0, count: totalSize)

        // Header (MINIDUMP_HEADER)
        data.writeLEUInt32(0x504D444D, at: 0)             // MDMP signature
        data.writeLEUInt16(0xA793, at: 4)                 // version
        data.writeLEUInt32(dirCount, at: 8)
        data.writeLEUInt32(UInt32(headerSize), at: 12)
        data.writeLEUInt32(0, at: 16)                     // checksum
        data.writeLEUInt32(1700000000, at: 20)            // timestamp
        data.writeLEUInt64(0, at: 24)                     // flags

        // Stream directory
        var dirOffset = headerSize
        // 0: Exception (stream 6)
        data.writeLEUInt32(6, at: dirOffset)
        data.writeLEUInt32(168, at: dirOffset + 4)
        data.writeLEUInt32(exRva, at: dirOffset + 8)
        dirOffset += 12
        // 1: ThreadList (stream 3)
        data.writeLEUInt32(3, at: dirOffset)
        data.writeLEUInt32(4 + 48, at: dirOffset + 4)
        data.writeLEUInt32(threadRva, at: dirOffset + 8)
        dirOffset += 12
        // 2: ModuleList (stream 4)
        data.writeLEUInt32(4, at: dirOffset)
        data.writeLEUInt32(4 + 108 + UInt32(moduleNameBytes), at: dirOffset + 4)
        data.writeLEUInt32(moduleRva, at: dirOffset + 8)
        dirOffset += 12
        // 3: Memory64List (stream 9)
        data.writeLEUInt32(9, at: dirOffset)
        data.writeLEUInt32(UInt32(16 + 16), at: dirOffset + 4)
        data.writeLEUInt32(m64Rva, at: dirOffset + 8)

        // MINIDUMP_EXCEPTION_STREAM
        let exOff = Int(exRva)
        data.writeLEUInt32(1, at: exOff)                  // threadId
        data.writeLEUInt32(exceptionCode, at: exOff + 8)
        data.writeLEUInt64(exceptionAddress, at: exOff + 24)
        data.writeLEUInt32(UInt32(exceptionParams.count), at: exOff + 32)
        for (i, param) in exceptionParams.enumerated() {
            data.writeLEUInt64(param, at: exOff + 40 + i * 8)
        }
        data.writeLEUInt32(UInt32(contextSize), at: exOff + 160)
        data.writeLEUInt32(contextRva, at: exOff + 164)

        // ThreadList — 1 thread referencing this context
        let threadOff = Int(threadRva)
        data.writeLEUInt32(1, at: threadOff)              // count
        data.writeLEUInt32(1, at: threadOff + 4)          // threadId
        data.writeLEUInt32(0, at: threadOff + 8)          // suspendCount
        data.writeLEUInt32(32, at: threadOff + 12)        // priorityClass
        data.writeLEUInt32(8, at: threadOff + 16)         // priority
        data.writeLEUInt64(0, at: threadOff + 20)         // teb
        data.writeLEUInt64(stackBase, at: threadOff + 28) // stack startOfMemoryRange
        data.writeLEUInt32(stackSize, at: threadOff + 36) // stack dataSize
        data.writeLEUInt32(0, at: threadOff + 40)         // stack rva (memory64 covers it)
        data.writeLEUInt32(UInt32(contextSize), at: threadOff + 44)
        data.writeLEUInt32(contextRva, at: threadOff + 48)

        // Architecture-specific context bytes
        contextWriter(&data, Int(contextRva))

        // ModuleList
        let modOff = Int(moduleRva)
        data.writeLEUInt32(1, at: modOff)                 // count
        data.writeLEUInt64(moduleBase, at: modOff + 4)
        data.writeLEUInt32(moduleSize, at: modOff + 12)
        data.writeLEUInt32(0, at: modOff + 16)            // checksum
        data.writeLEUInt32(1700000000, at: modOff + 20)   // timestamp
        data.writeLEUInt32(moduleNameStart, at: modOff + 24)

        let nameOff = Int(moduleNameStart)
        data.writeLEUInt32(UInt32(moduleNameUtf16.count * 2), at: nameOff)
        for (i, u) in moduleNameUtf16.enumerated() {
            data.writeLEUInt16(u, at: nameOff + 4 + i * 2)
        }

        // Memory64List — region may extend past thread.stack
        let m64Off = Int(m64Rva)
        data.writeLEUInt64(1, at: m64Off)                            // numberOfRanges
        data.writeLEUInt64(UInt64(m64DataStart), at: m64Off + 8)     // baseRva
        data.writeLEUInt64(stackBase, at: m64Off + 16)
        data.writeLEUInt64(UInt64(memoryRegionSize), at: m64Off + 24)

        if let stackData {
            data.replaceSubrange(Int(m64DataStart)..<(Int(m64DataStart) + stackData.count),
                                 with: stackData)
        }

        return try MinidumpParser.parse(data: data)
    }
}
