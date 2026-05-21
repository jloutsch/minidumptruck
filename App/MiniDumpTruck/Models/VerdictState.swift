import Foundation

/// Discrete states for the SummaryView verdict card. Derived from raw
/// inputs (analysis progress, parsed exception, parse warnings) so the
/// state-selection logic is testable independently of the SwiftUI view.
public enum VerdictState: Sendable {
    /// Analysis is in flight.
    case analyzing
    /// Analysis complete with a verdict to render.
    case analyzed(CrashAnalysis)
    /// Parsing succeeded, no exception present, no parse warnings —
    /// genuine "clean dump" verdict.
    case noException
    /// Parsing produced warnings, so the absence of an exception cannot
    /// be trusted — we don't know whether the dump is clean or corrupt.
    case indeterminate
    /// Transient: an exception was parsed but analysis hasn't started
    /// yet. In practice this should only render for the single frame
    /// before `.task` begins.
    case exceptionPending(ExceptionInfo)

    public static func from(
        isAnalyzing: Bool,
        analysis: CrashAnalysis?,
        exception: ExceptionInfo?,
        hasParseWarnings: Bool
    ) -> VerdictState {
        if isAnalyzing { return .analyzing }
        if let analysis { return .analyzed(analysis) }
        if let exception { return .exceptionPending(exception) }
        return hasParseWarnings ? .indeterminate : .noException
    }

    /// Payload-free tag for tests that only care about state precedence.
    public enum Kind: Sendable, Equatable, CaseIterable {
        case analyzing, analyzed, noException, indeterminate, exceptionPending
    }

    public var kind: Kind {
        switch self {
        case .analyzing: return .analyzing
        case .analyzed: return .analyzed
        case .noException: return .noException
        case .indeterminate: return .indeterminate
        case .exceptionPending: return .exceptionPending
        }
    }
}
