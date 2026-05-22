import Foundation

/// A pure-value decision about what `WelcomeView` should do in response to
/// an `InputPipeline.Outcome`. Separated from the View so the routing is
/// unit-testable without AppKit (`NSAlert`, `NSWorkspace`) or SwiftUI state.
public enum WelcomeAction: Sendable {
    /// Open a parsed dump in the current window.
    case openDocument(parsedDump: ParsedMinidump, fileSize: Int)
    /// Open one or more extracted dump files via `NSWorkspace.shared.open`,
    /// which routes back through the App's `.onOpenURL` handler.
    case openWindows([URL])
    /// Present the multi-dump picker sheet for the user to choose entries.
    case showPicker(archive: ZipArchive, dumpEntries: [ZipEntry], zipName: String)
    /// Show a warning alert. Used for all failures from `InputPipeline`.
    case showAlert(title: String, message: String)
}

/// Maps `InputPipeline.Outcome` (what the pipeline did) to `WelcomeAction`
/// (what the View should do). Pure function; no side effects.
public enum WelcomeRouter {
    public static func route(_ outcome: InputPipeline.Outcome) -> WelcomeAction {
        switch outcome {
        case .openInPlace(let parsed, let size):
            return .openDocument(parsedDump: parsed, fileSize: size)
        case .openInWindows(let urls):
            return .openWindows(urls)
        case .needsPick(let archive, let entries, let zipName):
            return .showPicker(archive: archive, dumpEntries: entries, zipName: zipName)
        case .failed(let err):
            return .showAlert(
                title: "Cannot Open File",
                message: err.errorDescription ?? "Unknown error."
            )
        }
    }
}
