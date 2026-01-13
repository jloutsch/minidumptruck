import Foundation

/// Result of crash analysis
public struct CrashAnalysis {
    public let stackFrames: [StackFrame]
    public let blameModule: BlameResult?
    public let crashSummary: CrashSummary
    public let confidence: AnalysisConfidence

    public init(stackFrames: [StackFrame], blameModule: BlameResult?, crashSummary: CrashSummary, confidence: AnalysisConfidence) {
        self.stackFrames = stackFrames
        self.blameModule = blameModule
        self.crashSummary = crashSummary
        self.confidence = confidence
    }
}

/// Single stack frame
public struct StackFrame: Identifiable {
    public let id = UUID()
    public let address: UInt64
    public let module: ModuleInfo?
    public let offsetInModule: UInt64?
    public let frameType: FrameType
    public let confidence: FrameConfidence

    public enum FrameType {
        case instructionPointer  // RIP - current execution
        case returnAddress       // From stack scan
        case framePointer        // From RBP chain
    }

    public enum FrameConfidence {
        case high    // From RBP chain or known call instruction
        case medium  // Return address in module text section
        case low     // Address in module range but uncertain
    }

    public var displayAddress: String {
        if let module = module, let offset = offsetInModule {
            return "\(module.shortName)+0x\(String(offset, radix: 16))"
        }
        return String(format: "0x%016llX", address)
    }

    public init(address: UInt64, module: ModuleInfo?, offsetInModule: UInt64?, frameType: FrameType, confidence: FrameConfidence) {
        self.address = address
        self.module = module
        self.offsetInModule = offsetInModule
        self.frameType = frameType
        self.confidence = confidence
    }
}

/// Blame analysis result
public struct BlameResult {
    public let module: ModuleInfo
    public let frame: StackFrame
    public let reason: BlameReason

    public enum BlameReason {
        case directCrash              // Exception address is in this module
        case firstNonSystemFrame      // First non-system DLL on stack
        case graphicsDriver           // Known graphics driver
        case thirdPartyInCallChain    // Third-party in crash call chain
    }

    public var reasonDescription: String {
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

    public init(module: ModuleInfo, frame: StackFrame, reason: BlameReason) {
        self.module = module
        self.frame = frame
        self.reason = reason
    }
}

/// High-level crash summary
public struct CrashSummary {
    public let exceptionType: String
    public let exceptionDescription: String
    public let faultingAddress: UInt64
    public let faultingModule: ModuleInfo?
    public let probableCause: String
    public let recommendation: String

    public init(exceptionType: String, exceptionDescription: String, faultingAddress: UInt64, faultingModule: ModuleInfo?, probableCause: String, recommendation: String) {
        self.exceptionType = exceptionType
        self.exceptionDescription = exceptionDescription
        self.faultingAddress = faultingAddress
        self.faultingModule = faultingModule
        self.probableCause = probableCause
        self.recommendation = recommendation
    }
}

/// Overall analysis confidence
public enum AnalysisConfidence {
    case high      // Full RBP chain available
    case medium    // Heuristic scan with good results
    case low       // Limited stack data or ambiguous results

    public var displayName: String {
        switch self {
        case .high: return "High"
        case .medium: return "Medium"
        case .low: return "Low"
        }
    }
}
