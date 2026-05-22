import Foundation

/// Pure routing decision for a file URL handed to the app from outside
/// (Finder double-click, Dock drag, `open file.dmp`, an `NSWorkspace`
/// loopback). Mirrors the App-level branch inside `.onOpenURL` so the
/// decision is unit-testable without SwiftUI state.
public enum ExternalOpenAction {
    /// The outcome is a parsed dump and should be shown directly. Caller
    /// is responsible for any confirm-before-replace UX when an existing
    /// document is already open.
    case showDocument(parsedDump: ParsedMinidump, fileSize: Int)
    /// The outcome needs UI that lives in WelcomeView (picker sheet,
    /// alert, multi-window fan-out). Caller should clear any current
    /// document and hand the outcome to WelcomeView for handling.
    case deferToWelcomeView(InputPipeline.Outcome)
}

/// Decide how the App should respond to an `InputPipeline.Outcome` that
/// arrived via `.onOpenURL`. Pure function — no side effects.
public func externalOpenAction(for outcome: InputPipeline.Outcome) -> ExternalOpenAction {
    if case .openInPlace(let parsed, let size) = outcome {
        return .showDocument(parsedDump: parsed, fileSize: size)
    }
    return .deferToWelcomeView(outcome)
}
