import Foundation

/// Result of crash analysis
struct CrashAnalysis {
    let stackFrames: [StackFrame]
    let blameModule: BlameResult?
    let crashSummary: CrashSummary
    let confidence: AnalysisConfidence
}

/// Single stack frame
struct StackFrame: Identifiable {
    let id = UUID()
    let address: UInt64
    let module: ModuleInfo?
    let offsetInModule: UInt64?
    let frameType: FrameType
    let confidence: FrameConfidence

    enum FrameType {
        case instructionPointer  // RIP - current execution
        case returnAddress       // From stack scan
        case framePointer        // From RBP chain
    }

    enum FrameConfidence {
        case high    // From RBP chain or known call instruction
        case medium  // Return address in module text section
        case low     // Address in module range but uncertain
    }

    var displayAddress: String {
        if let module = module, let offset = offsetInModule {
            return "\(module.shortName)+0x\(String(offset, radix: 16))"
        }
        return String(format: "0x%016llX", address)
    }
}

/// Blame analysis result
struct BlameResult {
    let module: ModuleInfo
    let frame: StackFrame
    let reason: BlameReason

    enum BlameReason {
        case directCrash              // Exception address is in this module
        case firstNonSystemFrame      // First non-system DLL on stack
        case graphicsDriver           // Known graphics driver
        case thirdPartyInCallChain    // Third-party in crash call chain
    }

    var reasonDescription: String {
        switch reason {
        case .directCrash:
            return "Exception occurred directly in this module"
        case .firstNonSystemFrame:
            return "First third-party module on call stack"
        case .graphicsDriver:
            return "Graphics driver detected in crash path"
        case .thirdPartyInCallChain:
            return "Third-party code in the crash call chain"
        }
    }
}

/// High-level crash summary
struct CrashSummary {
    let exceptionType: String
    let exceptionDescription: String
    let faultingAddress: UInt64
    let faultingModule: ModuleInfo?
    let probableCause: String
    let recommendation: String
}

/// Overall analysis confidence
enum AnalysisConfidence {
    case high      // Full RBP chain available
    case medium    // Heuristic scan with good results
    case low       // Limited stack data or ambiguous results

    var displayName: String {
        switch self {
        case .high: return "High"
        case .medium: return "Medium"
        case .low: return "Low"
        }
    }
}
