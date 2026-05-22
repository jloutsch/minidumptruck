import Foundation

/// Main crash analysis service
public struct CrashAnalyzer: Sendable {
    public let dump: ParsedMinidump

    /// Maximum stack bytes to scan
    private let maxStackScanBytes = 8192  // 8KB
    /// Maximum total frames to return from analysis
    private let maxTotalFrames = 100

    private let memory: DumpMemoryReader
    private let symbolicator: Symbolicator

    public init(dump: ParsedMinidump) {
        self.dump = dump
        self.memory = DumpMemoryReader(dump: dump)
        self.symbolicator = Symbolicator(dump: dump)
    }

    /// Analyze the crash and return results
    public func analyze() -> CrashAnalysis? {
        guard let exception = dump.exception,
              let faultingThread = MinidumpParser.faultingThread(in: dump),
              let context = faultingThread.context else {
            return nil
        }

        // Walk the stack
        let stackFrames = walkStack(context: context, thread: faultingThread)

        // Determine blame
        let blameResult = determineBlame(
            exception: exception,
            frames: stackFrames
        )

        // Generate summary
        let summary = generateSummary(
            exception: exception,
            blameResult: blameResult
        )

        // Assess confidence
        let confidence = assessConfidence(frames: stackFrames)

        return CrashAnalysis(
            stackFrames: stackFrames,
            blameModule: blameResult,
            crashSummary: summary,
            confidence: confidence
        )
    }

    // MARK: - Stack Walking

    /// Walk the stack using a hybrid approach: frame-pointer chain when
    /// available, heuristic scan as a supplement. Architecture-aware —
    /// dispatches to AAPCS64 walking for ARM64 contexts, the existing
    /// RBP-chain logic for x64.
    private func walkStack(context: ThreadContext, thread: ThreadInfo) -> [StackFrame] {
        var frames: [StackFrame] = []
        var seenAddresses: Set<UInt64> = []

        // Frame 0: Exception address (the actual faulting instruction)
        // This is more accurate than IP which may be in exception-handling code.
        if let exception = dump.exception {
            let exceptionFrame = createFrame(
                address: exception.exceptionAddress,
                type: .instructionPointer,
                confidence: .high
            )
            frames.append(exceptionFrame)
            seenAddresses.insert(exception.exceptionAddress)
        }

        // Frame 1: Thread IP (RIP / PC) if different from exception address.
        let ip = context.instructionPointer
        if !seenAddresses.contains(ip) {
            let ipFrame = createFrame(
                address: ip,
                type: .instructionPointer,
                confidence: .high
            )
            frames.append(ipFrame)
            seenAddresses.insert(ip)
        }

        // Architecture-specific frame-pointer walking.
        switch context {
        case .amd64(let amd):
            let rbpFrames = walkRBPChain(rbp: amd.rbp, rsp: amd.rsp, thread: thread)
            for frame in rbpFrames where !seenAddresses.contains(frame.address) {
                frames.append(frame)
                seenAddresses.insert(frame.address)
            }
        case .arm64(let arm):
            // AAPCS64: the LR (X30) holds the immediate return address for
            // the leaf frame; non-leaf frames spill the previous LR at
            // [FP, #8] and the previous FP at [FP, #0]. Seed the walk with
            // LR so we capture the caller even when the function never
            // wrote a frame record.
            if arm.lr != 0, !seenAddresses.contains(arm.lr),
               dump.moduleList?.module(containing: arm.lr) != nil {
                frames.append(createFrame(
                    address: arm.lr,
                    type: .returnAddress,
                    confidence: .medium
                ))
                seenAddresses.insert(arm.lr)
            }
            let fpFrames = walkAArch64FrameChain(fp: arm.fp, sp: arm.sp, thread: thread)
            for frame in fpFrames where !seenAddresses.contains(frame.address) {
                frames.append(frame)
                seenAddresses.insert(frame.address)
            }
        }

        // Supplement with heuristic stack scan from the architecture-neutral SP.
        let scannedFrames = scanStackForReturnAddresses(
            rsp: context.stackPointer,
            thread: thread,
            existingAddresses: seenAddresses
        )
        frames.append(contentsOf: scannedFrames)

        // Apply consistent total frame limit
        return Array(frames.prefix(maxTotalFrames))
    }

    /// Walk the AAPCS64 frame-record chain on ARM64.
    ///
    /// AAPCS64 prologue stores [previous FP | previous LR] as a 16-byte
    /// record at the top of the local stack frame and sets X29 to point
    /// at it. So given a valid FP we read `[fp]` = saved FP and
    /// `[fp+8]` = saved LR (return address into the caller). This
    /// breaks on omit-frame-pointer code (-fomit-frame-pointer or
    /// equivalent), in which case the heuristic scan picks up the
    /// remaining frames.
    private func walkAArch64FrameChain(
        fp: UInt64,
        sp: UInt64,
        thread: ThreadInfo
    ) -> [StackFrame] {
        var frames: [StackFrame] = []
        var currentFP = fp
        var iterations = 0
        let maxIterations = 100

        let stackBase = thread.stack.startOfMemoryRange
        let stackEnd = thread.stack.endAddress

        while iterations < maxIterations {
            iterations += 1

            // FP must point inside the captured stack, be SP-relative, and
            // 16-byte-aligned per AAPCS64.
            guard currentFP >= stackBase && currentFP < stackEnd else { break }
            guard currentFP >= sp else { break }
            guard currentFP % 16 == 0 else { break }

            // Read saved FP at [fp] and saved LR at [fp+8].
            let (fpPlus8, overflow) = currentFP.addingReportingOverflow(8)
            guard !overflow,
                  let savedFP = readUInt64(at: currentFP),
                  let returnAddress = readUInt64(at: fpPlus8) else {
                break
            }

            if dump.moduleList?.module(containing: returnAddress) != nil {
                frames.append(createFrame(
                    address: returnAddress,
                    type: .framePointer,
                    confidence: .high
                ))
            }

            // Frame records grow toward higher addresses; stop if we'd loop.
            guard savedFP > currentFP else { break }
            currentFP = savedFP
        }

        return frames
    }

    /// Walk RBP chain (x64 standard calling convention)
    private func walkRBPChain(
        rbp: UInt64,
        rsp: UInt64,
        thread: ThreadInfo
    ) -> [StackFrame] {
        var frames: [StackFrame] = []
        var currentRBP = rbp
        var iterations = 0
        let maxIterations = 100

        // Validate RBP is within stack bounds
        let stackBase = thread.stack.startOfMemoryRange
        let stackEnd = thread.stack.endAddress

        while iterations < maxIterations {
            iterations += 1

            // RBP should point within valid stack range
            guard currentRBP >= stackBase && currentRBP < stackEnd else { break }
            guard currentRBP >= rsp else { break }  // RBP should be >= RSP
            guard currentRBP % 8 == 0 else { break } // Must be aligned

            // Read saved RBP (at [RBP]) and return address (at [RBP+8])
            let (rbpPlus8, rbpOverflow) = currentRBP.addingReportingOverflow(8)
            guard !rbpOverflow,
                  let savedRBP = readUInt64(at: currentRBP),
                  let returnAddress = readUInt64(at: rbpPlus8) else {
                break
            }

            // Validate return address points to executable code
            if dump.moduleList?.module(containing: returnAddress) != nil {
                let frame = createFrame(
                    address: returnAddress,
                    type: .framePointer,
                    confidence: .high
                )
                frames.append(frame)
            }

            // Move to next frame
            guard savedRBP > currentRBP else { break }  // Must grow upward
            currentRBP = savedRBP
        }

        return frames
    }

    /// Heuristic stack scan for return addresses
    private func scanStackForReturnAddresses(
        rsp: UInt64,
        thread: ThreadInfo,
        existingAddresses: Set<UInt64>
    ) -> [StackFrame] {
        var frames: [StackFrame] = []

        // Read stack memory - scan from RSP to end of stack, not just dataSize from stack base.
        //
        // Clamp the UInt64 delta in UInt64 space BEFORE casting to Int.
        // `thread.stack.endAddress` saturates to `UInt64.max` when a
        // malformed dump declares `baseAddress + regionSize` past the
        // UInt64 ceiling; without the clamp, `Int(UInt64.max - rsp)`
        // would trap and crash the analyzer (DoS via malicious .dmp).
        // We never need more than `maxStackScanBytes` so bounding the
        // UInt64 at that ceiling is safe.
        let availableFromRsp64: UInt64
        if thread.stack.endAddress > rsp {
            availableFromRsp64 = min(thread.stack.endAddress - rsp, UInt64(maxStackScanBytes))
        } else {
            availableFromRsp64 = 0
        }
        let scanSize = Int(availableFromRsp64)
        guard let stackData = readMemory(at: rsp, size: scanSize) else {
            return frames
        }

        var seenAddresses = existingAddresses

        // Scan for 8-byte aligned potential return addresses
        var offset = 0
        while offset + 8 <= stackData.count {
            if let potentialAddress = stackData.readUInt64(at: offset) {
                // Skip if we already have this address
                guard !seenAddresses.contains(potentialAddress) else {
                    offset += 8
                    continue
                }

                // Check if address is in a module. Explicitly verify
                // `potentialAddress >= module.baseAddress` before the
                // UInt64 subtraction — `module(containing:)` is
                // presumed to guarantee this, but the subtraction is
                // a footgun if that contract is ever loosened (e.g.
                // overlapping modules with order-dependent matches).
                if let module = dump.moduleList?.module(containing: potentialAddress),
                   potentialAddress >= module.baseAddress {
                    let offsetInModule = potentialAddress - module.baseAddress

                    // Skip if at very start of module (unlikely to be return addr)
                    if offsetInModule > 0x1000 {
                        let confidence: StackFrame.FrameConfidence =
                            SystemModules.isSystemModule(module.name) ? .medium : .low

                        let frame = createFrame(
                            address: potentialAddress,
                            type: .returnAddress,
                            confidence: confidence
                        )
                        frames.append(frame)
                        seenAddresses.insert(potentialAddress)
                    }
                }
            }
            offset += 8
        }

        // Limit results from scan
        return Array(frames.prefix(20))
    }

    // MARK: - Blame Analysis

    /// Determine which module to blame for the crash
    private func determineBlame(
        exception: ExceptionInfo,
        frames: [StackFrame]
    ) -> BlameResult? {
        // Priority 1: Graphics driver near top of crash path (top 5 frames only)
        for frame in frames.prefix(5) {
            if let module = frame.module,
               SystemModules.isGraphicsDriver(module.name) {
                return BlameResult(
                    module: module,
                    frame: frame,
                    reason: .graphicsDriver
                )
            }
        }

        // Priority 2: Direct crash in non-system module
        if let firstFrame = frames.first,
           let module = firstFrame.module,
           !SystemModules.isSystemModule(module.name) {
            return BlameResult(
                module: module,
                frame: firstFrame,
                reason: .directCrash
            )
        }

        // Priority 3: First non-system module on stack
        for frame in frames {
            if let module = frame.module,
               !SystemModules.isSystemModule(module.name) {
                return BlameResult(
                    module: module,
                    frame: frame,
                    reason: .firstNonSystemFrame
                )
            }
        }

        // Fallback: blame the module containing the exception address
        if let module = dump.moduleList?.module(containing: exception.exceptionAddress) {
            if let frame = frames.first(where: { $0.module?.baseAddress == module.baseAddress }) {
                return BlameResult(
                    module: module,
                    frame: frame,
                    reason: .directCrash
                )
            }
        }

        return nil
    }

    // MARK: - Summary Generation

    private func generateSummary(
        exception: ExceptionInfo,
        blameResult: BlameResult?
    ) -> CrashSummary {
        let faultingModule = dump.moduleList?.module(containing: exception.exceptionAddress)

        let probableCause = generateProbableCause(
            exception: exception,
            blameResult: blameResult
        )

        let recommendation = generateRecommendation(
            exception: exception,
            blameResult: blameResult
        )

        return CrashSummary(
            exceptionType: exception.exceptionName,
            exceptionDescription: exception.exceptionDescription,
            faultingAddress: exception.exceptionAddress,
            faultingModule: faultingModule,
            probableCause: probableCause,
            recommendation: recommendation
        )
    }

    private func generateProbableCause(
        exception: ExceptionInfo,
        blameResult: BlameResult?
    ) -> String {
        switch exception.exceptionCode {
        case 0xC0000005: // ACCESS_VIOLATION
            if let details = exception.accessViolationDetails {
                return details
            }
            return "Invalid memory access"

        case 0xC00000FD: // STACK_OVERFLOW
            return "Stack overflow - excessive recursion or large stack allocations"

        case 0xC0000094: // INTEGER_DIVIDE_BY_ZERO
            return "Division by zero in integer arithmetic"

        case 0xC0000409: // STACK_BUFFER_OVERRUN
            return "Security check failure - buffer overrun detected"

        case 0xE06D7363: // C++ Exception
            return "Unhandled C++ exception"

        default:
            if let blame = blameResult {
                return "Exception in \(blame.module.shortName): \(blame.reasonDescription)"
            }
            return exception.exceptionDescription
        }
    }

    private func generateRecommendation(
        exception: ExceptionInfo,
        blameResult: BlameResult?
    ) -> String {
        if let blame = blameResult {
            let category = SystemModules.category(for: blame.module.name)

            switch category {
            case .graphicsDriver:
                return "Update graphics drivers to the latest version. This crash occurred in a graphics driver module (\(blame.module.shortName))."

            case .thirdParty:
                return "Check for updates to \(blame.module.shortName). Contact the vendor if the issue persists."

            case .application:
                return "This appears to be a bug in the application code. Review the stack trace for debugging."

            case .system:
                return "System component involved. Check for Windows updates or potential hardware issues."
            }
        }

        return "Analyze the stack trace to identify the root cause."
    }

    // MARK: - Confidence Assessment

    private func assessConfidence(frames: [StackFrame]) -> AnalysisConfidence {
        let framePointerCount = frames.filter { $0.frameType == .framePointer }.count
        let highConfidenceCount = frames.filter { $0.confidence == .high }.count

        if framePointerCount >= 3 && highConfidenceCount >= 4 {
            return .high
        }

        if highConfidenceCount >= 2 || framePointerCount >= 1 {
            return .medium
        }

        return .low
    }

    // MARK: - Helpers

    private func createFrame(
        address: UInt64,
        type: StackFrame.FrameType,
        confidence: StackFrame.FrameConfidence
    ) -> StackFrame {
        let module = dump.moduleList?.module(containing: address)
        let offset = module?.offset(for: address)
        let symbol = symbolicator.resolve(address: address)

        return StackFrame(
            address: address,
            module: module,
            offsetInModule: offset,
            symbol: symbol,
            frameType: type,
            confidence: confidence
        )
    }

    /// Read memory from the dump (Memory64List then MemoryList fallback).
    private func readMemory(at address: UInt64, size: Int) -> Data? {
        memory.read(at: address, size: size)
    }

    private func readUInt64(at address: UInt64) -> UInt64? {
        memory.readUInt64(at: address)
    }
}
