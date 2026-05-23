import Foundation

/// Result of crash analysis
public struct CrashAnalysis: Sendable, Codable {
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

/// A resolved function symbol for an address (export-table derived in slice 1).
public struct ResolvedSymbol: Sendable, Codable, Equatable {
    public let function: String
    public let offsetInFunction: UInt64

    public init(function: String, offsetInFunction: UInt64) {
        self.function = function
        self.offsetInFunction = offsetInFunction
    }
}

/// Single stack frame
public struct StackFrame: Identifiable, Sendable, Codable {
    private enum CodingKeys: String, CodingKey {
        case address, module, offsetInModule, symbol, frameType, confidence
    }

    public let id = UUID()
    public let address: UInt64
    public let module: ModuleInfo?
    public let offsetInModule: UInt64?
    public let symbol: ResolvedSymbol?
    public let frameType: FrameType
    public let confidence: FrameConfidence

    public enum FrameType: String, Sendable, Codable, CaseIterable {
        case instructionPointer  // RIP / exception address
        case returnAddress       // From stack scan
        case framePointer        // From RBP chain

        /// Compact label shown next to the role icon (e.g. on stack rows).
        public var shortLabel: String {
            switch self {
            case .instructionPointer: return "IP"
            case .returnAddress: return "Ret"
            case .framePointer: return "FP"
            }
        }

        /// VoiceOver-friendly description of the frame role.
        public var accessibilityLabel: String {
            switch self {
            case .instructionPointer: return "Instruction pointer"
            case .returnAddress: return "Return address"
            case .framePointer: return "Frame pointer"
            }
        }

        /// Educational tooltip text: what this role means and how the
        /// analyzer recovered it. Wording must match the actual analyzer
        /// behavior in `CrashAnalyzer.walkStack` — drift between tooltip
        /// and behavior misleads DFIR responders.
        public var helpText: String {
            switch self {
            case .instructionPointer:
                return "Instruction pointer — the CPU address recorded for this thread at dump time (exception address, or RIP if no exception). For synchronous crashes this is the faulting instruction."
            case .framePointer:
                return "Frame pointer — recovered by walking the RBP chain (x64 standard prologue). Most reliable frame source: each entry was definitely a real call."
            case .returnAddress:
                return "Return address — recovered by scanning the stack for 8-byte aligned values that land inside a loaded module. Heuristic: may include stale return addresses from prior calls."
            }
        }
    }

    public enum FrameConfidence: String, Sendable, Codable, CaseIterable {
        case high    // Exception address, RIP, or RBP-chain frame
        case medium  // Stack-scan hit inside a system module
        case low     // Stack-scan hit inside a non-system module

        /// Single-letter glyph for the per-frame confidence pill.
        public var shortLabel: String {
            switch self {
            case .high: return "H"
            case .medium: return "M"
            case .low: return "L"
            }
        }

        /// VoiceOver-friendly description.
        public var accessibilityLabel: String {
            switch self {
            case .high: return "High confidence"
            case .medium: return "Medium confidence"
            case .low: return "Low confidence"
            }
        }

        /// Educational tooltip text. Wording mirrors how
        /// `CrashAnalyzer.walkStack` actually assigns confidence —
        /// editing here without updating the analyzer (or vice versa)
        /// will mislead DFIR responders.
        public var helpText: String {
            switch self {
            case .high:
                return "High confidence — recorded by the OS at crash time (exception address / RIP) or recovered via the RBP chain. Trust this frame's position."
            case .medium:
                return "Medium confidence — stack-scan hit inside a known system module (kernel, ntdll, win32k, etc.). Likely a real prior call, but position relative to other frames may be off."
            case .low:
                return "Low confidence — stack-scan hit inside a user/third-party module. May be a stale return address or unrelated value that happens to fall inside an executable region. Cross-reference with adjacent frames before drawing conclusions."
            }
        }
    }

    public var displayAddress: String {
        if let module = module, let symbol = symbol {
            return "\(module.shortName)!\(symbol.function)+0x\(String(symbol.offsetInFunction, radix: 16))"
        }
        if let module = module, let offset = offsetInModule {
            return "\(module.shortName)+0x\(String(offset, radix: 16))"
        }
        return address.hexAddress
    }

    public init(address: UInt64, module: ModuleInfo?, offsetInModule: UInt64?, symbol: ResolvedSymbol? = nil, frameType: FrameType, confidence: FrameConfidence) {
        self.address = address
        self.module = module
        self.offsetInModule = offsetInModule
        self.symbol = symbol
        self.frameType = frameType
        self.confidence = confidence
    }
}

/// Blame analysis result
public struct BlameResult: Sendable, Codable {
    public let module: ModuleInfo
    public let frame: StackFrame
    public let reason: BlameReason

    public enum BlameReason: String, Sendable, Codable {
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
public struct CrashSummary: Sendable, Codable {
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
public enum AnalysisConfidence: String, Sendable, Codable {
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
