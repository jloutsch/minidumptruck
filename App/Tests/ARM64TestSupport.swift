// Shared ARM64 dump-fixture support for the ARM64 test suites.
//
// The four ARM64-related @Suite types (parser integration, frame-chain
// walker, exporters, Codable schema) each live in their own file but
// share this synthetic-dump builder.

import Foundation
@testable import MiniDumpTruckCore

/// Build a complete synthetic ARM64 minidump on top of the shared
/// `SyntheticDump` builder. Only the architecture-specific context
/// payload lives here — the header/directory/stream framing is owned
/// by `SyntheticDump.build` so AMD64 and ARM64 fixtures stay in sync.
///
/// `exceptionAddress` defaults to `pc` because most callers want the
/// faulting instruction to coincide with the captured program counter.
func makeARM64SyntheticDump(
    pc: UInt64,
    sp: UInt64,
    fp: UInt64,
    lr: UInt64 = 0,
    cpsr: UInt32 = 0,
    exceptionAddress: UInt64? = nil,
    moduleName: String = "arm.dll",
    moduleBase: UInt64 = 0x7FF0_0000_0000,
    moduleSize: UInt32 = 0x10_0000,
    stackBase: UInt64 = 0x0008_0000,
    stackSize: UInt32 = 0x1_0000,
    stackData: Data? = nil,
    memoryExtraBytes: UInt32 = 0
) throws -> ParsedMinidump {
    try SyntheticDump.build(
        contextSize: ARM64Context.size,
        exceptionAddress: exceptionAddress ?? pc,
        moduleName: moduleName,
        moduleBase: moduleBase,
        moduleSize: moduleSize,
        stackBase: stackBase,
        stackSize: stackSize,
        memoryExtraBytes: memoryExtraBytes,
        stackData: stackData
    ) { data, ctxOff in
        // CONTEXT_ARM64 layout: ContextFlags(4) + Cpsr(4) + X0..X30 +
        // Sp + Pc + V0..V31 + Fpcr + Fpsr + breakpoint/watchpoint regs.
        data.writeLEUInt32(0, at: ctxOff)               // contextFlags
        data.writeLEUInt32(cpsr, at: ctxOff + 4)
        // X29 = FP, X30 = LR (AAPCS64)
        data.writeLEUInt64(fp, at: ctxOff + 8 + 29 * 8)
        data.writeLEUInt64(lr, at: ctxOff + 8 + 30 * 8)
        data.writeLEUInt64(sp, at: ctxOff + 256)
        data.writeLEUInt64(pc, at: ctxOff + 264)
    }
}
