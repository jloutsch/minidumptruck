import SwiftUI
import MiniDumpTruckCore
import AppKit

struct CrashAnalysisView: View {
    let document: MinidumpDocument
    @Bindable var viewModel: DumpViewModel
    @State private var analysis: CrashAnalysis?
    @State private var isAnalyzing = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let analysis = analysis {
                    // Header with confidence badge
                    analysisHeader(analysis)

                    Divider()

                    // Blame Module Section
                    if let blame = analysis.blameModule {
                        blameSection(blame)
                        Divider()
                    }

                    // Crash Summary
                    summarySection(analysis.crashSummary)
                    Divider()

                    // Call Stack
                    stackSection(analysis.stackFrames)

                } else if isAnalyzing {
                    ProgressView("Analyzing crash...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView(
                        "No Analysis Available",
                        systemImage: "wand.and.stars",
                        description: Text("Unable to analyze this crash dump")
                    )
                }
            }
            .padding()
        }
        .navigationTitle("Crash Analysis")
        .textSelection(.enabled)
        .task {
            await runAnalysis()
        }
    }

    // MARK: - Sections

    private func analysisHeader(_ analysis: CrashAnalysis) -> some View {
        HStack {
            Image(systemName: "wand.and.stars")
                .font(.largeTitle)
                .foregroundStyle(.blue)

            VStack(alignment: .leading) {
                Text("Crash Analysis")
                    .font(.title2)
                    .fontWeight(.bold)

                HStack {
                    Text("Confidence:")
                    Text(analysis.confidence.displayName)
                        .foregroundStyle(confidenceColor(analysis.confidence))
                        .fontWeight(.medium)
                }
                .font(.subheadline)
            }

            Spacer()

            Button {
                copyReportToClipboard(analysis)
            } label: {
                Label("Copy Report", systemImage: "doc.on.doc")
            }
            .buttonStyle(.bordered)
        }
    }

    private func copyReportToClipboard(_ analysis: CrashAnalysis) {
        var report = "=== CRASH ANALYSIS REPORT ===\n\n"

        // Summary
        report += "EXCEPTION: \(analysis.crashSummary.exceptionType)\n"
        report += "ADDRESS: \(String(format: "0x%016llX", analysis.crashSummary.faultingAddress))\n"
        if let module = analysis.crashSummary.faultingModule {
            report += "MODULE: \(module.shortName)\n"
        }
        report += "\nPROBABLE CAUSE: \(analysis.crashSummary.probableCause)\n"
        report += "RECOMMENDATION: \(analysis.crashSummary.recommendation)\n"

        // Blame
        if let blame = analysis.blameModule {
            report += "\n--- BLAME ---\n"
            report += "MODULE: \(blame.module.shortName)\n"
            report += "REASON: \(blame.reasonDescription)\n"
            report += "CATEGORY: \(SystemModules.category(for: blame.module.name).displayName)\n"
        }

        // Stack
        report += "\n--- CALL STACK (\(analysis.stackFrames.count) frames) ---\n"
        for (index, frame) in analysis.stackFrames.enumerated() {
            let conf = frame.confidence == .high ? "H" : (frame.confidence == .medium ? "M" : "L")
            report += String(format: "%02d [%@] %@\n", index, conf, frame.displayAddress)
            if let module = frame.module {
                report += "       \(module.name)\n"
            }
        }

        report += "\nConfidence: \(analysis.confidence.displayName)\n"

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
    }

    private func blameSection(_ blame: BlameResult) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Label("Probable Cause", systemImage: "target")
                    .font(.headline)
                    .foregroundStyle(.red)

                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Module:")
                            .fontWeight(.medium)
                        Text(blame.module.shortName)
                            .fontDesign(.monospaced)
                            .foregroundStyle(.blue)

                        if let version = blame.module.version {
                            Text("v\(version.fileVersion)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 4) {
                        Text(SystemModules.category(for: blame.module.name).displayName)
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(.quaternary)
                            .clipShape(Capsule())
                    }
                }

                Text(blame.reasonDescription)
                    .foregroundStyle(.secondary)

                Button("View Module Details") {
                    viewModel.selectModule(blame.module)
                }
                .buttonStyle(.link)
            }
        }
    }

    private func summarySection(_ summary: CrashSummary) -> some View {
        GroupBox("Analysis Summary") {
            VStack(alignment: .leading, spacing: 12) {
                // Exception info
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                    GridRow {
                        Text("Exception:")
                            .fontWeight(.medium)
                        Text(summary.exceptionType)
                            .foregroundStyle(.red)
                    }

                    GridRow {
                        Text("Address:")
                            .fontWeight(.medium)
                        Text(String(format: "0x%016llX", summary.faultingAddress))
                            .fontDesign(.monospaced)
                    }

                    if let module = summary.faultingModule {
                        GridRow {
                            Text("Module:")
                                .fontWeight(.medium)
                            Text(module.shortName)
                        }
                    }
                }

                Divider()

                // Probable cause
                VStack(alignment: .leading, spacing: 4) {
                    Text("Probable Cause")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Text(summary.probableCause)
                        .foregroundStyle(.secondary)
                }

                // Recommendation
                VStack(alignment: .leading, spacing: 4) {
                    Text("Recommendation")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Text(summary.recommendation)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func stackSection(_ frames: [StackFrame]) -> some View {
        GroupBox("Call Stack (\(frames.count) frames)") {
            // LazyVStack: 60-200 frame stacks (deadlocks, deep recursion)
            // would otherwise render every row eagerly and stall scrolling.
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(frames.enumerated()), id: \.element.id) { index, frame in
                    stackFrameRow(frame, index: index)

                    if index < frames.count - 1 {
                        Divider()
                    }
                }
            }
        }
    }

    private func stackFrameRow(_ frame: StackFrame, index: Int) -> some View {
        HStack(alignment: .top) {
            // Frame number
            Text(String(format: "%02d", index))
                .fontDesign(.monospaced)
                .foregroundStyle(.secondary)
                .frame(width: 24)

            // Frame type indicator
            frameTypeIndicator(frame.frameType)

            // Address and module
            VStack(alignment: .leading, spacing: 2) {
                // Long symbolicated C++ template names (200+ chars) would
                // otherwise push the row off-screen with no horizontal
                // scroll. Middle truncation keeps the module! prefix and
                // the +0xNN offset both visible. `.textSelection` is set
                // on the parent ScrollView so drag-to-select works across
                // multiple frames; do not add it per-row.
                Text(frame.displayAddress)
                    .fontDesign(.monospaced)
                    .foregroundStyle(frame.module != nil ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(frame.displayAddress)

                if let module = frame.module {
                    HStack(spacing: 4) {
                        Text(module.name)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)

                        Text(SystemModules.category(for: module.name).displayName)
                            .font(.caption2)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(categoryColor(for: module))
                            .clipShape(Capsule())
                    }
                }
            }

            Spacer()

            // Confidence indicator
            confidenceIndicator(frame.confidence)
        }
        .padding(.vertical, 6)
    }

    // MARK: - Helpers

    @ScaledMetric(relativeTo: .caption2) private var frameTypeIndicatorWidth: CGFloat = 44

    private func frameTypeIndicator(_ type: StackFrame.FrameType) -> some View {
        // Display strings live on the model (see StackFrame.FrameType
        // extensions in Core) so tests can guard against label swaps.
        let icon: String
        let color: Color
        switch type {
        case .instructionPointer: icon = "arrow.right.circle.fill"; color = .red
        case .framePointer:       icon = "arrow.up.circle.fill";    color = .green
        case .returnAddress:      icon = "circle.fill";              color = .blue
        }

        return HStack(spacing: 4) {
            Image(systemName: icon)
                .foregroundStyle(color)
            Text(type.shortLabel)
                .font(.caption2)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: frameTypeIndicatorWidth, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(type.accessibilityLabel)
    }

    private func confidenceIndicator(_ confidence: StackFrame.FrameConfidence) -> some View {
        // Distinct SF Symbol per state so colorblind users (deuteranopia
        // hits the green/orange pair particularly hard) get shape
        // redundancy beyond color: ✓ for high, = for medium, ? for low.
        let icon: String
        let color: Color
        switch confidence {
        case .high:   icon = "checkmark.circle.fill";   color = .green
        case .medium: icon = "equal.circle.fill";        color = .orange
        case .low:    icon = "questionmark.circle.fill"; color = .gray
        }

        return Image(systemName: icon)
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(color)
            .imageScale(.medium)
            .accessibilityLabel(confidence.accessibilityLabel)
    }

    private func confidenceColor(_ confidence: AnalysisConfidence) -> Color {
        switch confidence {
        case .high: return .green
        case .medium: return .orange
        case .low: return .gray
        }
    }

    private func categoryColor(for module: ModuleInfo) -> Color {
        switch SystemModules.category(for: module.name) {
        case .system: return .gray.opacity(0.3)
        case .graphicsDriver: return .orange.opacity(0.3)
        case .application: return .blue.opacity(0.3)
        case .thirdParty: return .purple.opacity(0.3)
        }
    }

    private func runAnalysis() async {
        guard let dump = document.parsedDump else { return }

        isAnalyzing = true

        let result = await Task.detached(priority: .userInitiated) {
            CrashAnalyzer(dump: dump).analyze()
        }.value
        analysis = result

        isAnalyzing = false
    }
}
