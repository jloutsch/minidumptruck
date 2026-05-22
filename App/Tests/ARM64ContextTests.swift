import Foundation
import Testing
@testable import MiniDumpTruckCore

private extension Data {
    mutating func writeLEUInt32(_ value: UInt32, at offset: Int) {
        for i in 0..<4 {
            self[offset + i] = UInt8((value >> (i * 8)) & 0xFF)
        }
    }
    mutating func writeLEUInt64(_ value: UInt64, at offset: Int) {
        for i in 0..<8 {
            self[offset + i] = UInt8((value >> (i * 8)) & 0xFF)
        }
    }
}

/// Build a synthetic `CONTEXT_ARM64` (912-byte) blob with the given
/// register values populated. Fields not passed are zero, which is what
/// the on-disk format would carry for "unset / not captured".
private func makeARM64ContextBytes(
    contextFlags: UInt32 = 0,
    cpsr: UInt32 = 0,
    xRegs: [UInt64] = Array(repeating: 0, count: 31),
    sp: UInt64 = 0,
    pc: UInt64 = 0,
    vRegs: [(low: UInt64, high: UInt64)]? = nil,
    fpcr: UInt32 = 0,
    fpsr: UInt32 = 0
) -> Data {
    precondition(xRegs.count == 31, "xRegs must contain X0–X30")
    if let vRegs { precondition(vRegs.count == 32, "vRegs must contain V0–V31") }

    var d = Data(repeating: 0, count: ARM64Context.size)
    d.writeLEUInt32(contextFlags, at: 0)
    d.writeLEUInt32(cpsr, at: 4)
    for (i, v) in xRegs.enumerated() {
        d.writeLEUInt64(v, at: 8 + i * 8)
    }
    d.writeLEUInt64(sp, at: 256)
    d.writeLEUInt64(pc, at: 264)
    if let vRegs {
        for (i, v) in vRegs.enumerated() {
            d.writeLEUInt64(v.low, at: 272 + i * 16)
            d.writeLEUInt64(v.high, at: 272 + i * 16 + 8)
        }
    }
    d.writeLEUInt32(fpcr, at: 784)
    d.writeLEUInt32(fpsr, at: 788)
    return d
}

@Suite("ARM64 thread context")
struct ARM64ContextTests {

    @Test func zeroBufferParsesToAllZeroRegisters() throws {
        let d = Data(repeating: 0, count: ARM64Context.size)
        let arm = try #require(ARM64Context(from: d, at: 0))
        #expect(arm.contextFlags == 0)
        #expect(arm.cpsr == 0)
        #expect(arm.pc == 0)
        #expect(arm.sp == 0)
        #expect(arm.fp == 0)
        #expect(arm.lr == 0)
        #expect(arm.xRegs.count == 31)
        #expect(arm.floatSaveValid == false,
                "ARM64 FP state is gated on bit 0x4 of contextFlags; a zero buffer must report missing")
    }

    @Test func parsesXRegistersInOrder() {
        // X0=0xA0..., X1=0xA1..., …, X30=0xBE...
        var xs: [UInt64] = []
        for i in 0..<31 { xs.append(0xA000_0000_0000_0000 | UInt64(i)) }
        let d = makeARM64ContextBytes(xRegs: xs)
        let arm = ARM64Context(from: d, at: 0)!

        for i in 0..<31 {
            #expect(arm.xRegs[i] == 0xA000_0000_0000_0000 | UInt64(i),
                    "X\(i) parsed at offset 8 + \(i)*8 — regression means the offset table moved")
        }
    }

    @Test func fpAndLrAreX29AndX30() {
        var xs = Array<UInt64>(repeating: 0, count: 31)
        xs[29] = 0x7000_0000_0000_BEEF  // FP
        xs[30] = 0x7000_0000_0000_CAFE  // LR
        let d = makeARM64ContextBytes(xRegs: xs)
        let arm = ARM64Context(from: d, at: 0)!
        #expect(arm.fp == 0x7000_0000_0000_BEEF)
        #expect(arm.lr == 0x7000_0000_0000_CAFE)
    }

    @Test func spAndPcParseAtCorrectOffsets() {
        let d = makeARM64ContextBytes(
            sp: 0x0000_007F_FFFF_F000,
            pc: 0x0000_00AA_BBCC_DDEE
        )
        let arm = ARM64Context(from: d, at: 0)!
        #expect(arm.sp == 0x0000_007F_FFFF_F000)
        #expect(arm.pc == 0x0000_00AA_BBCC_DDEE)
    }

    @Test func cpsrFlagsDecodeNZCV() {
        // N=0x80000000, Z=0x40000000, C=0x20000000, V=0x10000000
        let all: UInt32 = 0x8000_0000 | 0x4000_0000 | 0x2000_0000 | 0x1000_0000
        let arm = ARM64Context(from: makeARM64ContextBytes(cpsr: all), at: 0)!
        #expect(arm.cpsrFlags == ["N", "Z", "C", "V"])

        let none = ARM64Context(from: makeARM64ContextBytes(cpsr: 0), at: 0)!
        #expect(none.cpsrFlags.isEmpty)

        // Just Z, in WinDbg order.
        let z = ARM64Context(from: makeARM64ContextBytes(cpsr: 0x4000_0000), at: 0)!
        #expect(z.cpsrFlags == ["Z"])
    }

    @Test func generalRegistersExposeFpLrSpPcInWinDbgOrder() {
        var xs = Array<UInt64>(repeating: 0, count: 31)
        xs[0] = 0xAA
        xs[29] = 0xFF_AA  // FP
        xs[30] = 0xFF_BB  // LR
        let arm = ARM64Context(from: makeARM64ContextBytes(
            xRegs: xs, sp: 0xFF_CC, pc: 0xFF_DD
        ), at: 0)!

        let regs = arm.generalRegisters
        #expect(regs.count == 29 + 4, "29 X regs (X0–X28) + FP + LR + SP + PC")
        #expect(regs[0].name == "X0")
        #expect(regs[0].value == 0xAA)
        #expect(regs[28].name == "X28")
        #expect(regs[29].name == "FP")
        #expect(regs[29].value == 0xFF_AA)
        #expect(regs[30].name == "LR")
        #expect(regs[30].value == 0xFF_BB)
        #expect(regs[31].name == "SP")
        #expect(regs[31].value == 0xFF_CC)
        #expect(regs[32].name == "PC")
        #expect(regs[32].value == 0xFF_DD)
    }

    @Test func neonRegistersOnlyPresentWhenFloatStateValid() {
        let vs = Array(repeating: (low: UInt64(0xDEAD), high: UInt64(0xBEEF)), count: 32)

        // With CONTEXT_FLOATING_POINT bit clear, FP regs must be nil.
        let off = ARM64Context(from: makeARM64ContextBytes(contextFlags: 0, vRegs: vs), at: 0)!
        #expect(off.vRegs == nil)
        #expect(off.neonRegisters.isEmpty)

        // With bit set, all 32 V regs surface.
        let on = ARM64Context(from: makeARM64ContextBytes(contextFlags: 0x4, vRegs: vs), at: 0)!
        #expect(on.vRegs?.count == 32)
        #expect(on.vRegs?[0] == NEONRegister(low: 0xDEAD, high: 0xBEEF))
        let neon = on.neonRegisters
        #expect(neon.count == 32)
        #expect(neon[0].name == "V0")
        #expect(neon[0].value == "000000000000BEEF000000000000DEAD")
    }

    @Test func neonRegistersParseAtUniqueOffsets() {
        // Every V_i gets a unique value pair so off-by-one stride or
        // lo/hi-swap regressions in the parser fail this test loudly.
        // The previous test used identical payloads for all 32 regs and
        // would happily pass with `272 + i*8` (wrong) or low/high swapped.
        let vs: [(low: UInt64, high: UInt64)] = (0..<32).map { i in
            (low: 0xAA00_0000_0000_0000 | UInt64(i),
             high: 0xBB00_0000_0000_0000 | UInt64(i))
        }
        let arm = ARM64Context(from: makeARM64ContextBytes(
            contextFlags: 0x4, vRegs: vs
        ), at: 0)!
        let parsed = try? #require(arm.vRegs)
        guard let parsed else { return }
        for i in 0..<32 {
            #expect(parsed[i].low == 0xAA00_0000_0000_0000 | UInt64(i),
                    "V\(i).low must round-trip; regression means stride or lo/hi byte order moved")
            #expect(parsed[i].high == 0xBB00_0000_0000_0000 | UInt64(i),
                    "V\(i).high must round-trip; regression means stride or lo/hi byte order moved")
        }
    }

    @Test func failsParseWhenBufferTooShort() {
        let short = Data(repeating: 0, count: ARM64Context.size - 1)
        #expect(ARM64Context(from: short, at: 0) == nil)
    }
}

/// End-to-end check on the `ThreadContext` enum's dataSize-based
/// dispatch — confirms that a 912-byte descriptor produces an `.arm64`
/// case and a 1232-byte descriptor produces an `.amd64` case.
@Suite("ThreadContext architecture dispatch")
struct ThreadContextDispatchTests {
    @Test func arm64DataSizeDispatchesToARM64Case() {
        let d = Data(repeating: 0, count: ARM64Context.size)
        let ctx = ThreadContext(from: d, at: 0, dataSize: UInt32(ARM64Context.size))
        switch ctx {
        case .arm64: break  // expected
        case .some, .none:
            Issue.record("expected .arm64 case for 912-byte dataSize, got \(String(describing: ctx))")
        }
    }

    @Test func amd64DataSizeDispatchesToAMD64Case() {
        let d = Data(repeating: 0, count: AMD64Context.size)
        let ctx = ThreadContext(from: d, at: 0, dataSize: UInt32(AMD64Context.size))
        switch ctx {
        case .amd64: break
        default:
            Issue.record("expected .amd64 case for 1232-byte dataSize, got \(String(describing: ctx))")
        }
    }

    @Test func unknownDataSizeFallsBackToAMD64AndParsesRegisters() {
        // x86 (716-byte) dumps survived under the pre-multi-arch
        // single-init parse; preserve that fallback so we don't
        // regress existing fixtures. Plant a recognizable RIP value at
        // the AMD64 offset (248) and assert it round-trips — proves the
        // fallback isn't returning a zeroed/garbage context.
        var d = Data(repeating: 0, count: 8192)
        d.writeLEUInt64(0xCAFE_BABE_DEAD_BEEF, at: 248)  // AMD64 RIP offset
        let ctx = ThreadContext(from: d, at: 0, dataSize: 716)
        if case .amd64(let amd) = ctx {
            #expect(amd.rip == 0xCAFE_BABE_DEAD_BEEF,
                    "fallback must parse the AMD64 layout, not return a default-initialized stub")
        } else {
            Issue.record("unknown dataSize must fall back to AMD64 parse for legacy compat")
        }
    }

    @Test func archAgnosticAccessorsMirrorPerArchFields() {
        var xs = Array<UInt64>(repeating: 0, count: 31)
        xs[29] = 0x1111  // FP
        xs[30] = 0x2222  // LR
        let arm = ARM64Context(from: makeARM64ContextBytes(
            xRegs: xs, sp: 0x3333, pc: 0x4444
        ), at: 0)!
        let ctx = ThreadContext.arm64(arm)

        #expect(ctx.instructionPointer == 0x4444)
        #expect(ctx.stackPointer == 0x3333)
        #expect(ctx.framePointer == 0x1111)
        #expect(ctx.architectureName == "ARM64")
        #expect(ctx.ipRegisterName == "PC")
        #expect(ctx.spRegisterName == "SP")
        #expect(ctx.fpRegisterName == "FP")
    }
}
