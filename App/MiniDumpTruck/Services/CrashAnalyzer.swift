import Foundation

/// Main crash analysis service
public struct CrashAnalyzer {
    public let dump: ParsedMinidump

    /// Maximum stack bytes to scan
    private let maxStackScanBytes = 8192  // 8KB
    /// Maximum total frames to return from analysis
    private let maxTotalFrames = 100

    public init(dump: ParsedMinidump) {
        self.dump = dump
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

    /// Walk the stack using hybrid approach: RBP chain + heuristic scan
    private func walkStack(context: ThreadContext, thread: ThreadInfo) -> [StackFrame] {
        var frames: [StackFrame] = []
        var seenAddresses: Set<UInt64> = []

        // Frame 0: Exception address (the actual faulting instruction)
        // This is more accurate than RIP which may be in exception handling code
        if let exception = dump.exception {
            let exceptionFrame = createFrame(
                address: exception.exceptionAddress,
                type: .instructionPointer,
                confidence: .high
            )
            frames.append(exceptionFrame)
            seenAddresses.insert(exception.exceptionAddress)
        }

        // Frame 1: Thread RIP (if different from exception address)
        if !seenAddresses.contains(context.rip) {
            let ripFrame = createFrame(
                address: context.rip,
                type: .instructionPointer,
                confidence: .high
            )
            frames.append(ripFrame)
            seenAddresses.insert(context.rip)
        }

        // Try RBP chain walking first
        let rbpFrames = walkRBPChain(
            rbp: context.rbp,
            rsp: context.rsp,
            thread: thread
        )

        for frame in rbpFrames {
            if !seenAddresses.contains(frame.address) {
                frames.append(frame)
                seenAddresses.insert(frame.address)
            }
        }

        // Supplement with heuristic stack scan
        let scannedFrames = scanStackForReturnAddresses(
            rsp: context.rsp,
            thread: thread,
            existingAddresses: seenAddresses
        )
        frames.append(contentsOf: scannedFrames)

        // Apply consistent total frame limit
        return Array(frames.prefix(maxTotalFrames))
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

        // Read stack memory - scan from RSP to end of stack, not just dataSize from stack base
        let availableFromRsp = thread.stack.endAddress > rsp ? Int(thread.stack.endAddress - rsp) : 0
        let scanSize = min(maxStackScanBytes, availableFromRsp)
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

                // Check if address is in a module
                if let module = dump.moduleList?.module(containing: potentialAddress) {
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

        return StackFrame(
            address: address,
            module: module,
            offsetInModule: offset,
            frameType: type,
            confidence: confidence
        )
    }

    /// Read memory from the dump, trying Memory64List then MemoryList
    private func readMemory(at address: UInt64, size: Int) -> Data? {
        if let result = dump.memory64List?.readMemory(at: address, size: size, from: dump.data) {
            return result
        }
        return dump.memoryList?.readMemory(at: address, size: size, from: dump.data)
    }

    private func readUInt64(at address: UInt64) -> UInt64? {
        guard let data = readMemory(at: address, size: 8),
              data.count == 8 else {
            return nil
        }
        return data.readUInt64(at: 0)
    }
}
