import Foundation

/// Table-based x64 stack walker. Given a thread's saved register
/// state and per-module `.pdata` / `.xdata` tables, produces the
/// list of return addresses on the stack — matching WinDbg's `k`
/// output for optimized release binaries that omit the frame
/// pointer.
///
/// Algorithm (per frame):
///   1. Look up the module containing `currentRIP`.
///   2. Find the `RUNTIME_FUNCTION` whose [begin, end) covers RIP.
///   3. Read its `UNWIND_INFO` record.
///   4. Replay the unwind codes in REVERSE order — every code
///      describes a step of the function's prologue, so reversing
///      undoes the stack effects of those steps. Skip codes whose
///      CodeOffset is greater than RIP's offset into the function
///      (we haven't executed past them yet, so there's nothing to
///      undo).
///   5. Result: RSP now points at the saved return address. Pop it,
///      that becomes the next frame's RIP. Loop.
///
/// Reference: x64 software conventions, "Stack Unwind" section.
public struct UnwindStackWalker: Sendable {

    public struct WalkedFrame: Hashable, Sendable {
        public let returnAddress: UInt64
        /// True when this frame's predecessor was found via table-
        /// based unwinding (high confidence). False when we fell
        /// back to the heuristic scan — caller marks those frames as
        /// low confidence.
        public let isTableBased: Bool
    }

    private let memory: MemoryReading
    /// Module base address -> parsed unwind data. Constructed lazily
    /// from `ModuleList`; modules whose `.pdata` isn't captured in
    /// the dump are simply absent.
    private let modules: [UInt64: ModuleUnwindData]
    private let moduleList: ModuleList?

    /// DoS / runaway-walk cap. Real call stacks are deep but
    /// bounded; this matches what WinDbg shows in practice.
    public static let maxFrames = 256
    /// DoS cap on chained-info recursion. Even the gnarliest
    /// compiler-generated functions only chain a few deep.
    public static let maxChainDepth = 8

    public init(dump: ParsedMinidump) {
        self.memory = DumpMemoryReader(dump: dump)
        self.moduleList = dump.moduleList
        var built: [UInt64: ModuleUnwindData] = [:]
        for module in dump.moduleList?.modules ?? [] {
            if built[module.baseAddress] != nil { continue }
            if let data = ModuleUnwindData(
                reader: memory,
                imageBase: module.baseAddress,
                imageSize: module.sizeOfImage
            ) {
                built[module.baseAddress] = data
            }
        }
        self.modules = built
    }

    /// True if at least one module has parseable unwind data —
    /// without that, callers should skip the table walk entirely
    /// and use the heuristic scanner.
    public var hasAnyUnwindData: Bool { !modules.isEmpty }

    /// Walk the stack starting from (RIP, RSP). Returns frames in
    /// inner-to-outer order. The first element is the caller of the
    /// function containing RIP (the leaf frame's own RIP is NOT
    /// included; callers usually have it separately as the
    /// "instruction pointer" frame).
    ///
    /// When unwinding fails for any frame (no module, no covering
    /// RUNTIME_FUNCTION, malformed UNWIND_INFO, memory unreadable),
    /// the walk stops and returns what it has so far. The caller
    /// can then optionally fall back to heuristic scanning for the
    /// remainder of the stack.
    public func walk(initialRIP: UInt64, initialRSP: UInt64) -> [WalkedFrame] {
        var frames: [WalkedFrame] = []
        var rip = initialRIP
        var rsp = initialRSP

        for _ in 0..<Self.maxFrames {
            guard let unwound = unwindOneFrame(rip: rip, rsp: rsp) else {
                break
            }
            // Loop / corruption guard: each frame should strictly
            // grow the stack pointer (stacks grow downward on x86_64
            // so unwinding RAISES RSP). A bug or malformed table
            // that left RSP unchanged would loop forever.
            guard unwound.rsp > rsp else { break }
            // Return address of 0 typically means we hit the start
            // of the thread (e.g. RtlUserThreadStart return slot).
            // Stop here rather than emit a bogus frame at 0.
            guard unwound.returnAddress != 0 else { break }
            frames.append(WalkedFrame(
                returnAddress: unwound.returnAddress,
                isTableBased: true
            ))
            rip = unwound.returnAddress
            rsp = unwound.rsp
        }
        return frames
    }

    /// Per-frame unwind result: the next RIP (popped return
    /// address) and the next RSP (where the caller's stack
    /// starts).
    private struct OneFrame {
        let returnAddress: UInt64
        let rsp: UInt64
    }

    private func unwindOneFrame(rip: UInt64, rsp: UInt64) -> OneFrame? {
        guard let module = moduleList?.module(containing: rip),
              let unwindData = modules[module.baseAddress] else {
            return nil
        }
        let rva = UInt32(truncatingIfNeeded: rip - module.baseAddress)

        // Follow chained UNWIND_INFO if necessary. A chain points
        // from one RUNTIME_FUNCTION's UNWIND_INFO to a sibling
        // RUNTIME_FUNCTION whose unwind codes we should apply
        // *first*. We collect the chain head-to-tail then apply in
        // that order so the OUTERMOST function's prologue gets
        // reversed first.
        var rfChain: [RuntimeFunction] = []
        guard var current = unwindData.runtimeFunctions.lookup(rva) else {
            return nil
        }
        rfChain.append(current)

        for _ in 0..<Self.maxChainDepth {
            guard let info = unwindData.unwindInfo(at: current.unwindInfoRVA),
                  info.flags.contains(.chainInfo),
                  let next = info.chainedFunction else {
                break
            }
            rfChain.append(next)
            current = next
        }

        // Apply each function's unwind codes in order. For each
        // RUNTIME_FUNCTION in the chain (which we built outermost-
        // last), read its UNWIND_INFO and replay its codes against
        // the running RSP.
        var rsp = rsp
        // Iterate the chain in the order we collected (innermost
        // function first); this matches Microsoft's documented
        // semantics for chained info.
        for rf in rfChain {
            guard let info = unwindData.unwindInfo(at: rf.unwindInfoRVA) else {
                return nil
            }
            let offsetIntoFn = UInt8(min(rva &- rf.beginRVA, UInt32(UInt8.max)))
            guard let newRSP = applyUnwindCodes(
                info: info,
                offsetInFunction: offsetIntoFn,
                rsp: rsp
            ) else { return nil }
            rsp = newRSP
        }

        // After all codes are applied, RSP points at the return
        // address. Read it, then increment RSP by 8 to advance past
        // the return-address slot for the caller's frame.
        guard let returnAddress = memory.readUInt64(at: rsp) else {
            return nil
        }
        let (callerRSP, of) = rsp.addingReportingOverflow(8)
        guard !of else { return nil }
        return OneFrame(returnAddress: returnAddress, rsp: callerRSP)
    }

    /// Walk the opcode array IN REVERSE (since each opcode
    /// describes a forward prologue step we want to undo) and
    /// apply each one to RSP. Returns the unwound RSP.
    ///
    /// `offsetInFunction` is the byte distance from the function's
    /// `BeginAddress` to the current RIP. We only undo codes whose
    /// `CodeOffset` is `<= offsetInFunction` — the rest are
    /// prologue instructions we haven't executed past yet.
    private func applyUnwindCodes(
        info: UnwindInfo,
        offsetInFunction: UInt8,
        rsp initialRSP: UInt64
    ) -> UInt64? {
        var rsp = initialRSP
        var i = 0
        let codes = info.codes
        // Code array uses variable-length opcodes — index advances
        // by 1, 2, or 3 per logical code depending on the op.
        while i < codes.count {
            let code = codes[i]
            // Skip codes that lie past our RIP — those prologue
            // operations haven't run yet, so they don't affect the
            // current stack layout.
            if code.codeOffset > offsetInFunction {
                // Advance over slot count for this op even though
                // we're not applying it, so subsequent ops align.
                i += slotsConsumed(code: code, remaining: codes[i...])
                continue
            }
            guard let op = UnwindOpCode(rawValue: code.unwindOp) else {
                // Unknown opcode — give up rather than guess.
                return nil
            }
            let consumed: Int
            switch op {
            case .pushNonvol:
                // PUSH reg → SUB rsp,8 in the prologue. Undo by
                // ADD rsp, 8.
                let (newRSP, of) = rsp.addingReportingOverflow(8)
                guard !of else { return nil }
                rsp = newRSP
                consumed = 1

            case .allocSmall:
                // SUB rsp, 8*(OpInfo+1). Undo by ADD.
                let bytes = UInt64(code.opInfo) * 8 + 8
                let (newRSP, of) = rsp.addingReportingOverflow(bytes)
                guard !of else { return nil }
                rsp = newRSP
                consumed = 1

            case .allocLarge:
                // OpInfo selects the encoding:
                //   0 = 16-bit slot * 8 (max 0x7FFF8 bytes)
                //   1 = 32-bit slot (raw bytes)
                guard i + 1 < codes.count else { return nil }
                let lowSlot = codes[i + 1]
                let lowU16 = UInt16(lowSlot.codeOffset) | (UInt16(lowSlot.unwindOp) << 4) | (UInt16(lowSlot.opInfo) << 8)
                let bytes: UInt32
                if code.opInfo == 0 {
                    bytes = UInt32(lowU16) * 8
                    consumed = 2
                } else if code.opInfo == 1 {
                    guard i + 2 < codes.count else { return nil }
                    let highSlot = codes[i + 2]
                    let highU16 = UInt16(highSlot.codeOffset) | (UInt16(highSlot.unwindOp) << 4) | (UInt16(highSlot.opInfo) << 8)
                    bytes = UInt32(lowU16) | (UInt32(highU16) << 16)
                    consumed = 3
                } else {
                    return nil
                }
                let (newRSP, of) = rsp.addingReportingOverflow(UInt64(bytes))
                guard !of else { return nil }
                rsp = newRSP

            case .setFPReg:
                // The prologue did: lea fp, [rsp+FrameOffset*16].
                // From here on the function uses the frame pointer
                // instead of RSP. To reverse, we'd need to restore
                // RSP from the saved frame pointer — but we don't
                // track register state. For a leaf walk where RIP
                // is inside the function body, the unwind tables
                // tell us the full prologue effect via subsequent
                // ALLOC ops, so this op is a no-op for OUR purposes
                // (we just keep applying remaining codes). The
                // table's job is to make sure RSP ends up correct
                // after ALL codes are applied; setFPReg doesn't
                // change RSP itself.
                consumed = 1

            case .saveNonvol, .saveXMM128:
                // Saved a register to a fixed offset on the stack.
                // No effect on RSP. 1 follow-up slot carries the
                // offset.
                consumed = 2

            case .saveNonvolFar, .saveXMM128Far:
                // Far variant: 2 follow-up slots carry a 32-bit
                // offset. No effect on RSP.
                consumed = 3

            case .epilog:
                // v2 epilog marker — 1 slot, no stack effect from
                // the walker's perspective.
                consumed = 1

            case .pushMachFrame:
                // Interrupt frame: pushes 5 or 6 quadwords
                // depending on error-code presence. OpInfo == 0
                // means 5 (no error code), OpInfo == 1 means 6.
                // For an unwind we just adjust RSP past them.
                let push = (code.opInfo == 0) ? UInt64(5 * 8) : UInt64(6 * 8)
                let (newRSP, of) = rsp.addingReportingOverflow(push)
                guard !of else { return nil }
                rsp = newRSP
                consumed = 1

            case .spareCode:
                // Reserved / shouldn't appear in compiler-generated
                // code. Be defensive: consume 1 slot.
                consumed = 1
            }
            i += consumed
        }
        return rsp
    }

    /// How many opcode slots `code` consumes. Used when skipping a
    /// code that's beyond our current RIP. Mirrors the slot logic
    /// inside `applyUnwindCodes`.
    private func slotsConsumed(code: UnwindCode, remaining: ArraySlice<UnwindCode>) -> Int {
        guard let op = UnwindOpCode(rawValue: code.unwindOp) else { return 1 }
        switch op {
        case .pushNonvol, .allocSmall, .setFPReg, .epilog, .pushMachFrame, .spareCode:
            return 1
        case .allocLarge:
            return code.opInfo == 0 ? 2 : 3
        case .saveNonvol, .saveXMM128:
            return 2
        case .saveNonvolFar, .saveXMM128Far:
            return 3
        }
    }
}
