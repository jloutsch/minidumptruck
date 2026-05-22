import SwiftUI
import MiniDumpTruckCore

extension AnalysisConfidence {
    /// Color used to tint the per-analysis confidence chip and inline
    /// "Confidence: X" text. Single source of truth — if the palette
    /// changes (e.g. accessibility revision), update here only.
    ///
    /// Note: this is intentionally an App-target SwiftUI extension, not
    /// a Core property, because `Color` lives in the `SwiftUI`
    /// framework and `MiniDumpTruckCore` deliberately has no SwiftUI
    /// dependency.
    var displayColor: Color {
        switch self {
        case .high:   return .green
        case .medium: return .orange
        case .low:    return .gray
        }
    }
}

/// Compact "High Confidence" / "Medium Confidence" / "Low Confidence"
/// pill used in `SummaryView`'s verdict card and diagnosis section.
/// Wraps the previously-duplicated chip rendering so future restyles
/// (typography, padding, dark-mode contrast) happen in one place.
struct ConfidenceChip: View {
    let confidence: AnalysisConfidence

    var body: some View {
        Text("\(confidence.displayName) Confidence")
            .font(.caption)
            .fontWeight(.medium)
            .foregroundStyle(confidence.displayColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(confidence.displayColor.opacity(0.15))
            .clipShape(Capsule())
            .layoutPriority(1)
            .accessibilityLabel("\(confidence.displayName) confidence")
    }
}
