import SwiftUI
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
            VStack(alignment: .leading, spacing: 0) {
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
                Text(frame.displayAddress)
                    .fontDesign(.monospaced)
                    .foregroundStyle(frame.module != nil ? .primary : .secondary)

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

    private func frameTypeIndicator(_ type: StackFrame.FrameType) -> some View {
        let (icon, color): (String, Color) = {
            switch type {
            case .instructionPointer:
                return ("arrow.right.circle.fill", .red)
            case .framePointer:
                return ("arrow.up.circle.fill", .green)
            case .returnAddress:
                return ("circle.fill", .blue)
            }
        }()

        return Image(systemName: icon)
            .foregroundStyle(color)
            .frame(width: 20)
    }

    private func confidenceIndicator(_ confidence: StackFrame.FrameConfidence) -> some View {
        let (text, color): (String, Color) = {
            switch confidence {
            case .high: return ("H", .green)
            case .medium: return ("M", .orange)
            case .low: return ("L", .gray)
            }
        }()

        return Text(text)
            .font(.caption2)
            .fontWeight(.bold)
            .foregroundStyle(color)
            .frame(width: 16, height: 16)
            .background(color.opacity(0.2))
            .clipShape(Circle())
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

        // Run analysis (could be moved to background thread if needed)
        let analyzer = CrashAnalyzer(dump: dump)
        analysis = analyzer.analyze()

        isAnalyzing = false
    }
}
