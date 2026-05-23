import Foundation
import Testing
@testable import MiniDumpTruckCore

/// End-to-end stack walker tests. Build a synthetic PE with known
/// `.pdata` / `.xdata`, plant it in a synthetic dump's Memory64
/// region, then walk a stack that contains return addresses pointing
/// into the synthetic functions.
@Suite("UnwindStackWalker", .serialized)
struct UnwindStackWalkerTests {

    /// Compose a complete dump: the synthetic PE bytes live at
    /// `moduleBase`, the stack lives at `stackBase`. Returns the
    /// parsed dump ready to feed `UnwindStackWalker(dump:)`.
    private static func makeDump(
        peBytes: Data,
        moduleBase: UInt64 = 0x10_0000,
        stackBase: UInt64 = 0x0008_0000,
        stackBytes: Data
    ) throws -> ParsedMinidump {
        // Use the existing SyntheticDump builder; it places a single
        // module + a Memory64 region. For our purposes the module's
        // image bytes need to be in dump memory too — we'll smuggle
        // them in as part of a second Memory64 region OR by placing
        // them *inside* the stack region's data (since the dump
        // builder lets us pass arbitrary stackData).
        //
        // Easiest: extend the dump's memory region so it covers both
        // the stack AND the PE image. The dump only declares ONE
        // region, but we can make it large enough to span both.
        //
        // Layout: stackBase=0x80000, stackSize=0x1_0000 (stack ends
        // at 0x90000). moduleBase = stackBase + extraBytes_to_module.
        // The Memory64 region covers [stackBase, stackBase + total]
        // where total contains the stack bytes followed by the PE
        // image at moduleBase - stackBase.
        precondition(moduleBase > stackBase, "module must live above stack")
        let moduleOffsetInRegion = moduleBase - stackBase
        let regionSize = moduleOffsetInRegion + UInt64(peBytes.count)
        precondition(regionSize <= UInt64(UInt32.max), "region too big")

        var regionData = Data(count: Int(regionSize))
        // Copy stack bytes at offset 0.
        regionData.replaceSubrange(0..<stackBytes.count, with: stackBytes)
        // Copy PE bytes at moduleOffsetInRegion.
        regionData.replaceSubrange(
            Int(moduleOffsetInRegion)..<(Int(moduleOffsetInRegion) + peBytes.count),
            with: peBytes
        )

        return try SyntheticDump.build(
            contextSize: AMD64Context.size,
            moduleName: "test.dll",
            moduleBase: moduleBase,
            moduleSize: 0x4000,
            stackBase: stackBase,
            stackSize: UInt32(stackBytes.count),
            memoryExtraBytes: UInt32(regionSize) - UInt32(stackBytes.count),
            stackData: regionData
        ) { _, _ in
            // Walker tests don't care about the AMD64Context payload;
            // we pass RIP / RSP directly to walk(initialRIP:initialRSP:).
        }
    }

    @Test func walksOneFrameWithSinglePushNonvolPrologue() throws {
        // Synthetic function: prologue pushed one register. So the
        // function's prologue contains "push rbp" — RSP got
        // decremented by 8 in the prologue, and the return address
        // is at [rsp + 8] when RIP is inside the function body.
        //
        // To unwind: ADD rsp, 8 (undo the push), then read return
        // address at [rsp] and advance another 8.
        let fn = SyntheticPE.Function(
            beginRVA: 0x1000,
            endRVA: 0x1100,
            prologSize: 2,
            // One UnwindCode: PUSH_NONVOL at codeOffset 2, register 5 (RBP).
            unwindCodes: SyntheticPE.code(codeOffset: 2, op: .pushNonvol, opInfo: 5),
            flags: 0
        )
        let pe = SyntheticPE.build(functions: [fn])

        // Stack layout:
        //   [stack+0x1000] = pushed RBP value (garbage, we don't care)
        //   [stack+0x1008] = return address pointing back into the module
        let moduleBase: UInt64 = 0x10_0000  // 1 MB above stackBase
        let stackBase: UInt64 = 0x0008_0000
        let returnAddress = moduleBase + 0x2000  // arbitrary, just needs to be a UInt64

        var stack = Data(count: 0x1_0000)
        // RIP is at moduleBase + 0x1050 (inside function 0x1000..0x1100,
        // past the prologue). RSP points at the pushed-RBP slot.
        let rsp: UInt64 = stackBase + 0x1000
        let rip: UInt64 = moduleBase + 0x1050
        // [rsp] = pushed RBP (any value)
        stack.writeLEUInt64(0xDEAD_BEEF, at: 0x1000)
        // [rsp + 8] = return address
        stack.writeLEUInt64(returnAddress, at: 0x1008)

        let dump = try Self.makeDump(peBytes: pe, moduleBase: moduleBase,
                                     stackBase: stackBase, stackBytes: stack)
        let walker = UnwindStackWalker(dump: dump)
        #expect(walker.hasAnyUnwindData == true)

        let frames = walker.walk(initialRIP: rip, initialRSP: rsp)
        #expect(frames.count >= 1,
                "walker must produce at least the one frame our prologue describes")
        #expect(frames.first?.returnAddress == returnAddress,
                "first unwound frame must be the return address sitting at [rsp + 8]")
        #expect(frames.first?.isTableBased == true)
    }

    @Test func walksFrameWithAllocSmall() throws {
        // Function with a 32-byte stack allocation in its prologue.
        // OpInfo=3 → allocSize = 8*(3+1) = 32 bytes.
        let fn = SyntheticPE.Function(
            beginRVA: 0x1000,
            endRVA: 0x1100,
            prologSize: 4,
            unwindCodes: SyntheticPE.code(codeOffset: 4, op: .allocSmall, opInfo: 3),
            flags: 0
        )
        let pe = SyntheticPE.build(functions: [fn])

        let moduleBase: UInt64 = 0x10_0000  // 1 MB above stackBase
        let stackBase: UInt64 = 0x0008_0000
        let returnAddress = moduleBase + 0x3000

        var stack = Data(count: 0x1_0000)
        // RSP points 32 bytes below the return address (the alloc).
        let rsp: UInt64 = stackBase + 0x1000
        let rip: UInt64 = moduleBase + 0x1080
        // Return address sits at rsp + 32 (after undoing the alloc).
        stack.writeLEUInt64(returnAddress, at: 0x1020)

        let dump = try Self.makeDump(peBytes: pe, moduleBase: moduleBase,
                                     stackBase: stackBase, stackBytes: stack)
        let walker = UnwindStackWalker(dump: dump)
        let frames = walker.walk(initialRIP: rip, initialRSP: rsp)
        #expect(frames.first?.returnAddress == returnAddress)
    }

    @Test func walksFrameWithAllocLargeOpInfo0() throws {
        // ALLOC_LARGE with OpInfo=0 uses the next code slot as a
        // 16-bit (little-endian) count of 8-byte words. Plant a slot
        // whose raw little-endian value is 0x0204 (= 516); the
        // prologue then allocated 516 * 8 = 4128 bytes. Use a
        // non-trivial slot value so the bit-assembly is checked
        // against the wrong-shift bug that previously lived here
        // (codeOffset 0x04, unwindOp = 2 nibble, opInfo = 0 nibble).
        //
        // Wire bytes of the follow-up slot: 0x04 0x02 → reassembled
        // little-endian = 0x0204 = 516.
        var codes = SyntheticPE.code(codeOffset: 6, op: .allocLarge, opInfo: 0)
        codes.append(0x04)  // slot byte 0 (low)
        codes.append(0x02)  // slot byte 1 (high)

        let fn = SyntheticPE.Function(
            beginRVA: 0x1000,
            endRVA: 0x1100,
            prologSize: 6,
            unwindCodes: codes,
            flags: 0
        )
        let pe = SyntheticPE.build(functions: [fn])

        let moduleBase: UInt64 = 0x10_0000
        let stackBase: UInt64 = 0x0008_0000
        let returnAddress = moduleBase + 0x5000
        let allocBytes: Int = 516 * 8  // 4128

        var stack = Data(count: 0x2_0000)
        let rsp: UInt64 = stackBase + 0x1000
        let rip: UInt64 = moduleBase + 0x1080
        // After undoing the alloc, RSP is rsp + 4128 and the return
        // address sits at that location.
        stack.writeLEUInt64(returnAddress, at: 0x1000 + allocBytes)

        let dump = try Self.makeDump(peBytes: pe, moduleBase: moduleBase,
                                     stackBase: stackBase, stackBytes: stack)
        let walker = UnwindStackWalker(dump: dump)
        let frames = walker.walk(initialRIP: rip, initialRSP: rsp)
        #expect(frames.first?.returnAddress == returnAddress,
                "allocLarge slot must be reassembled from the raw little-endian wire bytes, not from shifted nibble fields")
    }

    @Test func walksFrameWithMultipleOpcodesInOrder() throws {
        // Real-ish prologue: push RBP, sub RSP, 0x10. Two opcodes,
        // total stack delta of 24 (8 from push + 16 from alloc).
        // CodeOffsets are in reverse: in the wire format, the last
        // opcode listed is the EARLIEST in the prologue. We list
        // allocSmall before pushNonvol so the array is in
        // last-executed-first order (per Microsoft's spec).
        let fn = SyntheticPE.Function(
            beginRVA: 0x1000,
            endRVA: 0x1100,
            prologSize: 8,
            unwindCodes:
                SyntheticPE.code(codeOffset: 8, op: .allocSmall, opInfo: 1) +
                SyntheticPE.code(codeOffset: 2, op: .pushNonvol, opInfo: 5),
            flags: 0
        )
        let pe = SyntheticPE.build(functions: [fn])

        let moduleBase: UInt64 = 0x10_0000  // 1 MB above stackBase
        let stackBase: UInt64 = 0x0008_0000
        let returnAddress = moduleBase + 0x4000

        var stack = Data(count: 0x1_0000)
        let rsp: UInt64 = stackBase + 0x1000
        let rip: UInt64 = moduleBase + 0x1080
        // 16-byte alloc + 8-byte push = return address at rsp + 24.
        stack.writeLEUInt64(returnAddress, at: 0x1018)

        let dump = try Self.makeDump(peBytes: pe, moduleBase: moduleBase,
                                     stackBase: stackBase, stackBytes: stack)
        let walker = UnwindStackWalker(dump: dump)
        let frames = walker.walk(initialRIP: rip, initialRSP: rsp)
        #expect(frames.first?.returnAddress == returnAddress,
                "multi-opcode prologue must combine all stack deltas")
    }

    @Test func stopsAtZeroReturnAddress() throws {
        // A return address of 0 conventionally means "top of thread";
        // the walker must stop rather than emit a frame at NULL.
        let fn = SyntheticPE.Function(
            beginRVA: 0x1000,
            endRVA: 0x1100,
            prologSize: 2,
            unwindCodes: SyntheticPE.code(codeOffset: 2, op: .pushNonvol, opInfo: 5),
            flags: 0
        )
        let pe = SyntheticPE.build(functions: [fn])

        let moduleBase: UInt64 = 0x10_0000  // 1 MB above stackBase
        let stackBase: UInt64 = 0x0008_0000

        var stack = Data(count: 0x1_0000)
        let rsp: UInt64 = stackBase + 0x1000
        let rip: UInt64 = moduleBase + 0x1050
        stack.writeLEUInt64(0, at: 0x1008)  // explicit NULL return slot

        let dump = try Self.makeDump(peBytes: pe, moduleBase: moduleBase,
                                     stackBase: stackBase, stackBytes: stack)
        let walker = UnwindStackWalker(dump: dump)
        let frames = walker.walk(initialRIP: rip, initialRSP: rsp)
        #expect(frames.isEmpty,
                "walker must stop at NULL return address; emitting a frame at 0 would be a bogus result")
    }

    @Test func returnsEmptyWhenNoModuleAtRIP() throws {
        let fn = SyntheticPE.Function(
            beginRVA: 0x1000,
            endRVA: 0x1100,
            prologSize: 0,
            unwindCodes: [],
            flags: 0
        )
        let pe = SyntheticPE.build(functions: [fn])
        let dump = try Self.makeDump(
            peBytes: pe,
            stackBytes: Data(count: 0x1_0000)
        )
        let walker = UnwindStackWalker(dump: dump)
        // RIP that doesn't belong to any module — walker returns
        // empty, callers fall back to heuristic scan.
        let frames = walker.walk(initialRIP: 0xDEAD_BEEF, initialRSP: 0x80000)
        #expect(frames.isEmpty)
    }

    @Test func returnsEmptyWhenRIPNotInRuntimeFunctionTable() throws {
        // Module exists, but the RUNTIME_FUNCTION table only covers
        // 0x1000..0x1100. RIP at 0x5000 has no covering entry.
        let fn = SyntheticPE.Function(
            beginRVA: 0x1000,
            endRVA: 0x1100,
            prologSize: 0,
            unwindCodes: [],
            flags: 0
        )
        let pe = SyntheticPE.build(functions: [fn])
        let moduleBase: UInt64 = 0x10_0000  // 1 MB above stackBase

        let dump = try Self.makeDump(
            peBytes: pe,
            moduleBase: moduleBase,
            stackBytes: Data(count: 0x1_0000)
        )
        let walker = UnwindStackWalker(dump: dump)
        let frames = walker.walk(
            initialRIP: moduleBase + 0x5000,  // outside [0x1000, 0x1100)
            initialRSP: 0x80000
        )
        #expect(frames.isEmpty,
                "no covering RUNTIME_FUNCTION → no unwind possible → walker returns empty")
    }
}
