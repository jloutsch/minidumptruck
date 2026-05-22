import Foundation
import Testing
@testable import MiniDumpTruckCore

/// Behavioral coverage for `CrashAnalyzer.walkAArch64FrameChain`. Each
/// test plants frame records or LR values into a synthetic ARM64 dump's
/// stack and asserts the walker emits (or correctly rejects) the
/// corresponding frames.
@Suite("CrashAnalyzer ARM64 frame-chain walker")
struct ARM64FrameChainTests {

    /// Build a stack image with two valid AAPCS64 frame records:
    ///   frame 0 at `fp0`:  [savedFP = fp1, savedLR = lr0]
    ///   frame 1 at `fp1`:  [savedFP = 0,   savedLR = lr1]
    /// Both savedLR values point into the module's range so
    /// `dump.moduleList?.module(containing:)` succeeds.
    @Test func twoDeepFrameChainProducesTwoReturnAddresses() throws {
        let stackBase: UInt64 = 0x0008_0000
        let stackSize: UInt32 = 0x1_0000
        let moduleBase: UInt64 = 0x7FF0_0000_0000
        let moduleSize: UInt32 = 0x10_0000

        // 16-byte-aligned FPs inside the stack range.
        let fp0Offset: Int = 0x0020
        let fp1Offset: Int = 0x0040
        let fp0 = stackBase + UInt64(fp0Offset)
        let fp1 = stackBase + UInt64(fp1Offset)
        let lr0 = moduleBase + 0x100  // return into module
        let lr1 = moduleBase + 0x200

        var stack = Data(repeating: 0, count: Int(stackSize))
        // Frame 0 record
        stack.writeLEUInt64(fp1, at: fp0Offset)
        stack.writeLEUInt64(lr0, at: fp0Offset + 8)
        // Frame 1 record (terminator: savedFP=0)
        stack.writeLEUInt64(0, at: fp1Offset)
        stack.writeLEUInt64(lr1, at: fp1Offset + 8)

        let dump = try makeARM64SyntheticDump(
            pc: moduleBase + 0x10,       // currently executing in module
            sp: stackBase + 0x10,
            fp: fp0,
            lr: 0,                       // exercise the FP chain, not the seed
            moduleBase: moduleBase,
            moduleSize: moduleSize,
            stackBase: stackBase,
            stackSize: stackSize,
            stackData: stack
        )

        let analysis = try #require(CrashAnalyzer(dump: dump).analyze())
        let addresses = analysis.stackFrames.map(\.address)

        #expect(addresses.contains(lr0),
                "first frame record's saved LR must surface as a stack frame")
        #expect(addresses.contains(lr1),
                "second frame record's saved LR must surface as a stack frame")
        // Ordering: lr0 should come before lr1 (innermost frame first).
        let idx0 = addresses.firstIndex(of: lr0)
        let idx1 = addresses.firstIndex(of: lr1)
        if let idx0, let idx1 {
            #expect(idx0 < idx1, "frame ordering reversed: walker is unwinding outward incorrectly")
        }
    }

    @Test func lrSeedsLeafFrameWhenChainIsEmpty() throws {
        let stackBase: UInt64 = 0x0008_0000
        let moduleBase: UInt64 = 0x7FF0_0000_0000
        let lr: UInt64 = moduleBase + 0x80

        let dump = try makeARM64SyntheticDump(
            pc: moduleBase + 0x10,
            sp: stackBase + 0x10,
            fp: 0,                       // no frame record to walk
            lr: lr,
            moduleBase: moduleBase
        )

        let analysis = try #require(CrashAnalyzer(dump: dump).analyze())
        #expect(analysis.stackFrames.map(\.address).contains(lr),
                "leaf-frame LR must seed the walk when FP is null")
    }

    @Test func misalignedFpProducesNoFrameChainFrames() throws {
        // FP = 0x0008_0008 — inside the stack but NOT 16-byte aligned.
        // AAPCS64 requires 16-byte alignment; the walker must skip it.
        let stackBase: UInt64 = 0x0008_0000
        let moduleBase: UInt64 = 0x7FF0_0000_0000
        let lr0 = moduleBase + 0x100

        var stack = Data(repeating: 0, count: 0x1_0000)
        // Plant what would be a valid record at the misaligned offset
        // so a buggy walker (no alignment check) would find it.
        stack.writeLEUInt64(0, at: 8)
        stack.writeLEUInt64(lr0, at: 16)

        let dump = try makeARM64SyntheticDump(
            pc: moduleBase + 0x10,
            sp: stackBase + 0x4,
            fp: stackBase + 8,           // misaligned
            lr: 0,
            moduleBase: moduleBase,
            stackBase: stackBase,
            stackData: stack
        )

        let analysis = try #require(CrashAnalyzer(dump: dump).analyze())
        // lr0 came in via the chain only — must NOT appear if alignment
        // check rejects misaligned FP. (Module-base IP and exception
        // address may still surface as IP-confidence frames.)
        let chainHits = analysis.stackFrames.filter { $0.address == lr0 }
        #expect(chainHits.isEmpty,
                "misaligned FP must not produce frame-chain frames")
    }

    @Test func fpOutsideStackRangeIsRejected() throws {
        // Plant a valid AAPCS64 frame record at an address that's INSIDE
        // the Memory64 region (so the dump reader returns valid bytes)
        // but OUTSIDE the declared `thread.stack` range (so the walker's
        // range guard must reject it). Round-1 review caught the prior
        // version of this test passing only because the memory reader
        // returned nil — meaning the range guard wasn't actually under
        // test.
        let stackBase: UInt64 = 0x0008_0000
        let stackSize: UInt32 = 0x1_0000      // declared thread.stack
        let extraBytes: UInt32 = 0x2_0000     // Memory64 covers past stack
        let moduleBase: UInt64 = 0x7FF0_0000_0000
        let lr0 = moduleBase + 0x100

        // Frame record at offset stackSize+0x100 (= 0x10100) inside the
        // extended Memory64 region; absolute address = stackBase+0x10100,
        // which is past stackBase+stackSize. 16-byte aligned.
        let recordOffset = Int(stackSize) + 0x100
        var memory = Data(repeating: 0, count: Int(stackSize + extraBytes))
        memory.writeLEUInt64(0, at: recordOffset)            // savedFP = 0
        memory.writeLEUInt64(lr0, at: recordOffset + 8)      // savedLR = lr0

        let dump = try makeARM64SyntheticDump(
            pc: moduleBase + 0x10,
            sp: stackBase + 0x4,
            fp: stackBase + UInt64(recordOffset),   // OOR but readable
            lr: 0,
            moduleBase: moduleBase,
            stackBase: stackBase,
            stackSize: stackSize,
            stackData: memory,
            memoryExtraBytes: extraBytes
        )

        let analysis = try #require(CrashAnalyzer(dump: dump).analyze())
        // With the range guard active: lr0 is unreachable because the
        // walker breaks before reading. Without the range guard: the
        // memory reader DOES return the planted bytes and lr0 surfaces
        // as a frame. So this test now actually depends on the guard.
        let chainHits = analysis.stackFrames.filter { $0.address == lr0 }
        #expect(chainHits.isEmpty,
                "FP outside thread.stack must be rejected by the walker's range guard, even when memory at that address is captured")
    }
}
