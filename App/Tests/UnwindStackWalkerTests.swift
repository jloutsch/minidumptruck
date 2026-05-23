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
        //
        // Plant a non-zero sentinel pattern throughout the stack BEFORE
        // writing 0 at the expected return slot. Without the sentinel,
        // a walker bug that reads from the wrong offset would also see
        // 0 (zero-initialized buffer) and the test would falsely pass.
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

        // 0xAB sentinel: any read from a wrong offset returns
        // 0xABABABAB_ABABABAB, which is far from 0 and so the walker
        // would emit a frame at that address rather than stop. Forces
        // the test to fail unless the walker reads EXACTLY the planted
        // NULL slot at rsp+8 (after undoing the one push).
        var stack = Data(repeating: 0xAB, count: 0x1_0000)
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

    @Test func walksFrameWithAllocLargeOpInfo1() throws {
        // ALLOC_LARGE opInfo=1: 32-bit slot in raw bytes (no *8
        // multiplier). Two follow-up slots: low UInt16 first, then
        // high UInt16. Combined value = low | (high << 16).
        //
        // Plant low=0x0204, high=0x0001 → 0x00010204 = 65,540 bytes.
        // A wrong slot reconstruction would compute the wrong size
        // and the planted return address would be at the wrong offset.
        var codes = SyntheticPE.code(codeOffset: 7, op: .allocLarge, opInfo: 1)
        codes.append(0x04); codes.append(0x02)  // low slot: 0x0204
        codes.append(0x01); codes.append(0x00)  // high slot: 0x0001

        let fn = SyntheticPE.Function(
            beginRVA: 0x1000,
            endRVA: 0x1100,
            prologSize: 7,
            unwindCodes: codes,
            flags: 0
        )
        let pe = SyntheticPE.build(functions: [fn])

        let moduleBase: UInt64 = 0x10_0000
        let stackBase: UInt64 = 0x0008_0000
        let returnAddress = moduleBase + 0x5000
        let allocBytes: Int = 0x00010204  // 65,540

        var stack = Data(count: 0x2_0000)
        let rsp: UInt64 = stackBase + 0x1000
        let rip: UInt64 = moduleBase + 0x1080
        stack.writeLEUInt64(returnAddress, at: 0x1000 + allocBytes)

        let dump = try Self.makeDump(peBytes: pe, moduleBase: moduleBase,
                                     stackBase: stackBase, stackBytes: stack)
        let walker = UnwindStackWalker(dump: dump)
        let frames = walker.walk(initialRIP: rip, initialRSP: rsp)
        #expect(frames.first?.returnAddress == returnAddress,
                "allocLarge opInfo=1 must read 32-bit raw byte count from two follow-up slots")
    }

    @Test func walksFrameWithSaveNonvolPreservesSlotAlignment() throws {
        // SAVE_NONVOL has no RSP effect but consumes 2 slots (opcode
        // + 1 follow-up carrying the saved-to offset). Combine it
        // with a pushNonvol AFTER it (earlier in the prologue order
        // is later in the wire array because codes are stored last-
        // to-first); if the walker's slot count for saveNonvol were
        // wrong (e.g. 1), the pushNonvol would be misaligned or
        // skipped and the test would fail.
        let codes =
            // codeOffset 6: SAVE_NONVOL of RBX (reg 3) at offset 0
            SyntheticPE.code(codeOffset: 6, op: .saveNonvol, opInfo: 3) +
            [0x00, 0x00] +  // saveNonvol follow-up slot (offset / 8)
            // codeOffset 2: PUSH_NONVOL of RBP — adds 8 to RSP on unwind
            SyntheticPE.code(codeOffset: 2, op: .pushNonvol, opInfo: 5)

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
        let returnAddress = moduleBase + 0x6000

        var stack = Data(count: 0x1_0000)
        let rsp: UInt64 = stackBase + 0x1000
        let rip: UInt64 = moduleBase + 0x1080
        // Only the pushNonvol moves RSP — return address sits at rsp+8.
        stack.writeLEUInt64(returnAddress, at: 0x1008)

        let dump = try Self.makeDump(peBytes: pe, moduleBase: moduleBase,
                                     stackBase: stackBase, stackBytes: stack)
        let walker = UnwindStackWalker(dump: dump)
        let frames = walker.walk(initialRIP: rip, initialRSP: rsp)
        #expect(frames.first?.returnAddress == returnAddress,
                "saveNonvol must consume 2 slots so the following pushNonvol stays aligned")
    }

    @Test func walksFrameWithPushMachFrameOpInfo0() throws {
        // PUSH_MACHFRAME opInfo=0 pushes 5 quadwords (40 bytes), no
        // error code on the interrupt frame.
        let fn = SyntheticPE.Function(
            beginRVA: 0x1000,
            endRVA: 0x1100,
            prologSize: 1,
            unwindCodes: SyntheticPE.code(codeOffset: 1, op: .pushMachFrame, opInfo: 0),
            flags: 0
        )
        let pe = SyntheticPE.build(functions: [fn])

        let moduleBase: UInt64 = 0x10_0000
        let stackBase: UInt64 = 0x0008_0000
        let returnAddress = moduleBase + 0x7000

        var stack = Data(count: 0x1_0000)
        let rsp: UInt64 = stackBase + 0x1000
        let rip: UInt64 = moduleBase + 0x1050
        stack.writeLEUInt64(returnAddress, at: 0x1028)  // 40 bytes above rsp

        let dump = try Self.makeDump(peBytes: pe, moduleBase: moduleBase,
                                     stackBase: stackBase, stackBytes: stack)
        let walker = UnwindStackWalker(dump: dump)
        let frames = walker.walk(initialRIP: rip, initialRSP: rsp)
        #expect(frames.first?.returnAddress == returnAddress,
                "pushMachFrame opInfo=0 must unwind exactly 5 quadwords (40 bytes)")
    }

    @Test func walksFrameWithPushMachFrameOpInfo1() throws {
        // PUSH_MACHFRAME opInfo=1 pushes 6 quadwords (48 bytes), with
        // an error code.
        let fn = SyntheticPE.Function(
            beginRVA: 0x1000,
            endRVA: 0x1100,
            prologSize: 1,
            unwindCodes: SyntheticPE.code(codeOffset: 1, op: .pushMachFrame, opInfo: 1),
            flags: 0
        )
        let pe = SyntheticPE.build(functions: [fn])

        let moduleBase: UInt64 = 0x10_0000
        let stackBase: UInt64 = 0x0008_0000
        let returnAddress = moduleBase + 0x7100

        var stack = Data(count: 0x1_0000)
        let rsp: UInt64 = stackBase + 0x1000
        let rip: UInt64 = moduleBase + 0x1050
        stack.writeLEUInt64(returnAddress, at: 0x1030)  // 48 bytes above rsp

        let dump = try Self.makeDump(peBytes: pe, moduleBase: moduleBase,
                                     stackBase: stackBase, stackBytes: stack)
        let walker = UnwindStackWalker(dump: dump)
        let frames = walker.walk(initialRIP: rip, initialRSP: rsp)
        #expect(frames.first?.returnAddress == returnAddress,
                "pushMachFrame opInfo=1 must unwind exactly 6 quadwords (48 bytes)")
    }

    @Test func setFPRegHasNoStackEffect() throws {
        // SET_FPREG has no RSP effect (frame pointer is established
        // from RSP+FrameOffset*16). Combined with a pushNonvol, the
        // total stack delta should be just 8 bytes from the push —
        // the setFPReg contributes nothing. If a buggy walker treated
        // setFPReg as moving RSP, the return address would be at the
        // wrong offset.
        let codes =
            SyntheticPE.code(codeOffset: 5, op: .setFPReg, opInfo: 0) +
            SyntheticPE.code(codeOffset: 2, op: .pushNonvol, opInfo: 5)

        let fn = SyntheticPE.Function(
            beginRVA: 0x1000,
            endRVA: 0x1100,
            prologSize: 5,
            unwindCodes: codes,
            flags: 0
        )
        let pe = SyntheticPE.build(functions: [fn])

        let moduleBase: UInt64 = 0x10_0000
        let stackBase: UInt64 = 0x0008_0000
        let returnAddress = moduleBase + 0x8000

        var stack = Data(count: 0x1_0000)
        let rsp: UInt64 = stackBase + 0x1000
        let rip: UInt64 = moduleBase + 0x1080
        stack.writeLEUInt64(returnAddress, at: 0x1008)  // rsp + 8

        let dump = try Self.makeDump(peBytes: pe, moduleBase: moduleBase,
                                     stackBase: stackBase, stackBytes: stack)
        let walker = UnwindStackWalker(dump: dump)
        let frames = walker.walk(initialRIP: rip, initialRSP: rsp)
        #expect(frames.first?.returnAddress == returnAddress,
                "setFPReg must not alter RSP")
    }

    @Test func walksMultipleFrames() throws {
        // Two functions chained on the stack: A at RVA 0x1000 returns
        // into B at RVA 0x2000. Verify the walker emits BOTH frames
        // and that the second frame's lookup (after popping A's
        // return address) finds function B in the table.
        let fnA = SyntheticPE.Function(
            beginRVA: 0x1000,
            endRVA: 0x1100,
            prologSize: 2,
            unwindCodes: SyntheticPE.code(codeOffset: 2, op: .pushNonvol, opInfo: 5),
            flags: 0
        )
        let fnB = SyntheticPE.Function(
            beginRVA: 0x2000,
            endRVA: 0x2100,
            prologSize: 4,
            unwindCodes: SyntheticPE.code(codeOffset: 4, op: .allocSmall, opInfo: 1),
            flags: 0
        )
        let pe = SyntheticPE.build(functions: [fnA, fnB])

        let moduleBase: UInt64 = 0x10_0000
        let stackBase: UInt64 = 0x0008_0000

        // Stack layout (low to high):
        //   rsp = 0x1000: A's saved RBP (any value)
        //   rsp + 8 = 0x1008: return into B (B's RIP after its prologue)
        //   then B's frame: 16 bytes from its allocSmall(opInfo=1)
        //   rsp + 8 + 16 = 0x1020: return out of B (top-of-thread sentinel)
        let returnIntoB = moduleBase + 0x2080  // inside B's body
        let topOfThread = moduleBase + 0x3000

        var stack = Data(count: 0x1_0000)
        let rsp: UInt64 = stackBase + 0x1000
        let rip: UInt64 = moduleBase + 0x1050  // inside A's body
        stack.writeLEUInt64(returnIntoB, at: 0x1008)
        stack.writeLEUInt64(topOfThread, at: 0x1020)

        let dump = try Self.makeDump(peBytes: pe, moduleBase: moduleBase,
                                     stackBase: stackBase, stackBytes: stack)
        let walker = UnwindStackWalker(dump: dump)
        let frames = walker.walk(initialRIP: rip, initialRSP: rsp)
        #expect(frames.count == 2, "walker should produce both frames")
        #expect(frames.first?.returnAddress == returnIntoB)
        #expect(frames.last?.returnAddress == topOfThread,
                "second frame proves the per-frame re-lookup found function B")
    }

    @Test func walksChainedUnwindInfo() throws {
        // Build a 2-level chain: the leaf function points (via
        // chainInfo) at an outer RUNTIME_FUNCTION whose UNWIND_INFO
        // describes additional prologue effects. We expect the walker
        // to combine BOTH records' stack deltas.
        //
        // Leaf at RVA 0x1000: pushNonvol → +8 RSP delta.
        // Chained outer at RVA 0x2000: allocSmall opInfo=3 → +32 RSP.
        // Total delta: 40 bytes; return address sits at rsp + 40.
        //
        // Wire layout for the leaf's UNWIND_INFO: flags=chainInfo,
        // 1 code (2 bytes), padding to 4-byte boundary, then 12-byte
        // chained RUNTIME_FUNCTION. We use the SyntheticPE.build path
        // for the OUTER function (auto-emitted with its own pdata +
        // xdata entries), and hand-craft the leaf's UnwindInfo bytes
        // because SyntheticPE.build doesn't currently emit chain
        // pointers.
        //
        // Test approach: bypass SyntheticPE.build for the leaf — build
        // a minimal PE manually with two .pdata entries (leaf points
        // to a hand-written xdata with chainInfo flag pointing to
        // outer; outer is a normal record).
        //
        // For simplicity: place the leaf's UNWIND_INFO at xdataRVA
        // 0x400 and the outer's UNWIND_INFO at xdataRVA 0x500. The
        // leaf chains to a RUNTIME_FUNCTION (begin=0x2000, end=0x2100,
        // unwindInfo=0x500).
        let imageSize: UInt32 = 0x4000
        var image = Data(count: Int(imageSize))
        // DOS / NT / optional header (matches SyntheticPE.build).
        image[0] = 0x4D; image[1] = 0x5A
        image.writeLEUInt32(0x80, at: 0x3C)
        image[0x80] = 0x50; image[0x81] = 0x45
        image.writeLEUInt16(0x8664, at: 0x84)
        image.writeLEUInt16(0x020B, at: 0x98)
        let dirBase = 0x108
        // Exception directory @ 0x200, 2 entries (24 bytes).
        image.writeLEUInt32(0x200, at: dirBase + 3 * 8)
        image.writeLEUInt32(24,   at: dirBase + 3 * 8 + 4)

        // RUNTIME_FUNCTION[0] (leaf): begin=0x1000, end=0x1100,
        // unwindInfo=0x400.
        image.writeLEUInt32(0x1000, at: 0x200)
        image.writeLEUInt32(0x1100, at: 0x204)
        image.writeLEUInt32(0x400,  at: 0x208)
        // RUNTIME_FUNCTION[1] (outer chained target): begin=0x2000,
        // end=0x2100, unwindInfo=0x500.
        image.writeLEUInt32(0x2000, at: 0x20C)
        image.writeLEUInt32(0x2100, at: 0x210)
        image.writeLEUInt32(0x500,  at: 0x214)

        // Leaf UNWIND_INFO at 0x400: version=1, flags=chainInfo,
        // prolog=2, 1 code, framereg=0; then 1 UnwindCode (push RBP
        // at codeOffset 2), then 2 bytes padding, then a 12-byte
        // chained RUNTIME_FUNCTION pointing to (0x2000, 0x2100, 0x500).
        image[0x400] = 1 | (0x04 << 3)  // version=1, flags=chainInfo
        image[0x401] = 2                 // prolog size
        image[0x402] = 1                 // 1 code
        image[0x403] = 0                 // frame reg
        image[0x404] = 2                 // codeOffset
        image[0x405] = 0x50              // op=pushNonvol(0), opInfo=5
        // padding bytes 0x406..0x407 left zero
        image.writeLEUInt32(0x2000, at: 0x408)
        image.writeLEUInt32(0x2100, at: 0x40C)
        image.writeLEUInt32(0x500,  at: 0x410)

        // Outer UNWIND_INFO at 0x500: version=1, no flags, prolog=4,
        // 1 code (allocSmall opInfo=3 → 32 bytes).
        image[0x500] = 1
        image[0x501] = 4
        image[0x502] = 1
        image[0x503] = 0
        image[0x504] = 4                 // codeOffset
        image[0x505] = 0x32              // op=allocSmall(2), opInfo=3 → 32 bytes
        // (no padding needed at end of test data)

        let moduleBase: UInt64 = 0x10_0000
        let stackBase: UInt64 = 0x0008_0000
        let returnAddress = moduleBase + 0xA000

        var stack = Data(count: 0x1_0000)
        let rsp: UInt64 = stackBase + 0x1000
        let rip: UInt64 = moduleBase + 0x1050  // inside leaf function
        // Combined delta: 8 (push) + 32 (alloc) = 40 → return slot at rsp + 40.
        stack.writeLEUInt64(returnAddress, at: 0x1028)

        let dump = try Self.makeDump(peBytes: image, moduleBase: moduleBase,
                                     stackBase: stackBase, stackBytes: stack)
        let walker = UnwindStackWalker(dump: dump)
        let frames = walker.walk(initialRIP: rip, initialRSP: rsp)
        #expect(frames.first?.returnAddress == returnAddress,
                "chained UNWIND_INFO must combine leaf + outer stack deltas (8 + 32 = 40)")
    }

    @Test func returnsEmptyWhenUnwindInfoRVAIsOutsideImage() throws {
        // A RUNTIME_FUNCTION whose unwindInfoRVA points outside the
        // image (e.g. 0xFFFF_FFFF) must fail safely: read returns nil,
        // unwindOneFrame returns nil, walker stops with empty frames.
        let imageSize: UInt32 = 0x4000
        var image = Data(count: Int(imageSize))
        image[0] = 0x4D; image[1] = 0x5A
        image.writeLEUInt32(0x80, at: 0x3C)
        image[0x80] = 0x50; image[0x81] = 0x45
        image.writeLEUInt16(0x8664, at: 0x84)
        image.writeLEUInt16(0x020B, at: 0x98)
        image.writeLEUInt32(0x200, at: 0x108 + 3 * 8)
        image.writeLEUInt32(12,    at: 0x108 + 3 * 8 + 4)
        // RUNTIME_FUNCTION covering 0x1000..0x1100, but unwindInfoRVA
        // is bogus (way past the image bounds).
        image.writeLEUInt32(0x1000,      at: 0x200)
        image.writeLEUInt32(0x1100,      at: 0x204)
        image.writeLEUInt32(0xFFFF_FFFF, at: 0x208)

        let moduleBase: UInt64 = 0x10_0000
        let stackBase: UInt64 = 0x0008_0000

        var stack = Data(count: 0x1_0000)
        stack.writeLEUInt64(moduleBase + 0xDEAD, at: 0x1008)
        let rsp: UInt64 = stackBase + 0x1000
        let rip: UInt64 = moduleBase + 0x1050

        let dump = try Self.makeDump(peBytes: image, moduleBase: moduleBase,
                                     stackBase: stackBase, stackBytes: stack)
        let walker = UnwindStackWalker(dump: dump)
        let frames = walker.walk(initialRIP: rip, initialRSP: rsp)
        #expect(frames.isEmpty,
                "bogus unwindInfoRVA must produce no frames, not a crash or garbage frame")
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
