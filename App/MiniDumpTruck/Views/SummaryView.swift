import SwiftUI
import MiniDumpTruckCore

struct SummaryView: View {
    let document: MinidumpDocument
    @Bindable var viewModel: DumpViewModel
    @State private var analysis: CrashAnalysis?
    @State private var isAnalyzing = false

    private enum CardMetrics {
        static let cornerRadius: CGFloat = 8
        static let accentBarWidth: CGFloat = 4
        static let contentPadding: CGFloat = 14
    }

    private var verdictState: VerdictState {
        VerdictState.from(
            isAnalyzing: isAnalyzing,
            analysis: analysis,
            exception: document.exception,
            hasParseWarnings: !document.parseWarnings.isEmpty
        )
    }

    /// Stable identity for state reset when the user opens a new dump
    /// in the same view tree.
    private var documentIdentity: AnyHashable {
        AnyHashable([
            AnyHashable(document.fileSize),
            AnyHashable(document.header?.timestamp ?? .distantPast),
            AnyHashable(document.header?.checksum ?? 0)
        ])
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                verdictCard

                Divider()

                headerSection

                if !document.parseWarnings.isEmpty {
                    Divider()
                    warningsSection
                }

                Divider()

                if let exception = document.exception {
                    exceptionSection(exception)
                    Divider()
                }

                if let analysis = analysis {
                    diagnosisSection(analysis)
                    Divider()
                }

                if let systemInfo = document.systemInfo {
                    systemSection(systemInfo)
                    Divider()
                }

                statsSection
            }
            .padding()
        }
        .navigationTitle("Crash Summary")
        .textSelection(.enabled)
        .task(id: documentIdentity) {
            // Reset state when the bound document changes so we never
            // show a stale verdict for a freshly opened dump.
            analysis = nil
            isAnalyzing = false
            await runAnalysis()
        }
    }

    private func runAnalysis() async {
        guard let dump = document.parsedDump, dump.exception != nil else { return }
        isAnalyzing = true
        let tables = viewModel.pdbTables
        let result = await Task.detached(priority: .userInitiated) {
            CrashAnalyzer(dump: dump, pdbTables: tables).analyze()
        }.value
        analysis = result
        isAnalyzing = false
    }

    // MARK: - Verdict card

    @ViewBuilder
    private var verdictCard: some View {
        switch verdictState {
        case .analyzing:
            verdictCardChrome(
                accent: .gray,
                accessibilityLabel: "Verdict: analyzing"
            ) {
                HStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Analyzing crash…")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
            }
        case .analyzed(let analysis):
            verdictCardAnalyzed(analysis)
        case .noException:
            verdictCardChrome(
                accent: .green,
                accessibilityLabel: "Verdict: clean dump, no crash exception"
            ) {
                Label("Dump loaded — no crash exception present", systemImage: "checkmark.circle.fill")
                    .font(.title3)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.green)
            }
        case .indeterminate:
            verdictCardChrome(
                accent: .orange,
                accessibilityLabel: "Verdict: indeterminate, parse warnings present"
            ) {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Indeterminate — parse warnings present", systemImage: "exclamationmark.triangle.fill")
                        .font(.title3)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.orange)
                    Text("This dump may be incomplete or corrupted. See parse warnings below before trusting the absence of an exception.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        case .exceptionPending(let exception):
            verdictCardChrome(
                accent: .red,
                accessibilityLabel: "Verdict: \(exception.exceptionName), analysis pending"
            ) {
                Label(exception.exceptionName, systemImage: "exclamationmark.triangle.fill")
                    .font(.title2)
                    .fontWeight(.semibold)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.red)
            }
        }
    }

    private func verdictCardAnalyzed(_ analysis: CrashAnalysis) -> some View {
        let exceptionName = document.exception?.exceptionName ?? "Crash Diagnosis"
        return verdictCardChrome(
            accent: .red,
            accessibilityLabel: "Verdict: \(exceptionName), \(analysis.confidence.displayName) confidence"
        ) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Label(exceptionName, systemImage: "exclamationmark.triangle.fill")
                        .font(.title2)
                        .fontWeight(.semibold)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                    Spacer()
                    ConfidenceChip(confidence: analysis.confidence)
                }

                if let blame = analysis.blameModule {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(Self.sanitized(blame.module.shortName))
                            .font(.callout)
                            .fontWeight(.medium)
                            .fontDesign(.monospaced)
                            .foregroundStyle(Color.accentColor)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text("—")
                            .foregroundStyle(.secondary)
                        Text(Self.sanitized(blame.reasonDescription))
                            .font(.callout)
                            .lineLimit(2)
                    }
                }

                Button {
                    viewModel.selectedSection = .analyze
                } label: {
                    Label("View full analysis", systemImage: "arrow.right")
                        .font(.callout)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Color.accentColor)
            }
        }
    }

    @ViewBuilder
    private func verdictCardChrome<Content: View>(
        accent: Color,
        accessibilityLabel: String,
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(accent)
                .frame(width: CardMetrics.accentBarWidth)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(CardMetrics.contentPadding)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: CardMetrics.cornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: CardMetrics.cornerRadius)
                .strokeBorder(Color.secondary.opacity(0.15), lineWidth: 0.5)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private static func sanitized(_ s: String) -> String {
        s.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }

    // MARK: - Other sections

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let header = document.header {
                HStack(spacing: 10) {
                    Image(systemName: "doc.text")
                        .font(.title3)
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Windows Minidump")
                            .font(.headline)

                        HStack(spacing: 12) {
                            Text(header.timestamp.formatted())
                            Text(ByteCountFormatter.string(fromByteCount: Int64(document.fileSize), countStyle: .file))
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }

                if !header.flagsDescription.isEmpty {
                    Text("Flags: \(header.flagsDescription.joined(separator: ", "))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func exceptionSection(_ exception: ExceptionInfo) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Exception", systemImage: "exclamationmark.triangle")
                .font(.headline)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.red)

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Type:")
                            .fontWeight(.medium)
                        Text(exception.exceptionName)
                            .foregroundStyle(.red)
                    }

                    Text(exception.exceptionDescription)
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    if let details = exception.accessViolationDetails {
                        Text(details)
                            .font(.callout)
                            .padding(.top, 4)
                    }

                    Divider()

                    HStack {
                        Text("Address:")
                            .fontWeight(.medium)
                        Text(String(format: "0x%016llX", exception.exceptionAddress))
                            .fontDesign(.monospaced)

                        if let module = document.module(containing: exception.exceptionAddress) {
                            Text("(\(module.shortName))")
                                .foregroundStyle(.secondary)
                        }
                    }

                    HStack {
                        Text("Thread ID:")
                            .fontWeight(.medium)
                        Text("\(exception.threadId)")

                        Button("View Thread") {
                            if let thread = document.threads.first(where: { $0.id == exception.threadId }) {
                                viewModel.selectThread(thread)
                            }
                        }
                        .buttonStyle(.link)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func diagnosisSection(_ analysis: CrashAnalysis) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Crash Diagnosis", systemImage: "wand.and.stars")
                    .font(.headline)
                    .foregroundStyle(.purple)

                Spacer()

                ConfidenceChip(confidence: analysis.confidence)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Probable Cause")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Text(analysis.crashSummary.probableCause)
                            .foregroundStyle(.secondary)
                    }

                    if let blame = analysis.blameModule {
                        Divider()
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Blamed Module")
                                .font(.subheadline)
                                .fontWeight(.medium)
                            HStack(spacing: 8) {
                                Text(blame.module.shortName)
                                    .fontDesign(.monospaced)
                                    .foregroundStyle(.blue)
                                Text(blame.reasonDescription)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Recommendation")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Text(analysis.crashSummary.recommendation)
                            .foregroundStyle(.secondary)
                    }

                    Button("View Full Crash Analysis") {
                        viewModel.selectedSection = .analyze
                    }
                    .buttonStyle(.link)
                    .font(.callout)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func systemSection(_ systemInfo: SystemInfo) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("System Information", systemImage: "desktopcomputer")
                .font(.headline)

            GroupBox {
                Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
                    GridRow {
                        Text("OS:")
                            .fontWeight(.medium)
                        Text("\(systemInfo.windowsVersionName) (\(systemInfo.osVersionString))")
                    }

                    GridRow {
                        Text("Architecture:")
                            .fontWeight(.medium)
                        Text(systemInfo.processorArchitecture.displayName)
                    }

                    GridRow {
                        Text("Processors:")
                            .fontWeight(.medium)
                        Text("\(systemInfo.numberOfProcessors)")
                    }

                    if let csd = systemInfo.csdVersion, !csd.isEmpty {
                        GridRow {
                            Text("Service Pack:")
                                .fontWeight(.medium)
                            Text(csd)
                        }
                    }

                    GridRow {
                        Text("CPU Vendor:")
                            .fontWeight(.medium)
                        Text(systemInfo.cpuInfo.vendorString)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var warningsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Parse Warnings (\(document.parseWarnings.count))", systemImage: "exclamationmark.triangle")
                .font(.headline)
                .foregroundStyle(.orange)

            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(document.parseWarnings) { warning in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .font(.caption)
                            VStack(alignment: .leading, spacing: 2) {
                                if let streamType = warning.streamType {
                                    Text(streamType.displayName)
                                        .fontWeight(.medium)
                                        .font(.callout)
                                }
                                Text(warning.message)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var statsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Statistics", systemImage: "chart.bar")
                .font(.headline)

            GroupBox {
                Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
                    GridRow {
                        Text("Threads:")
                            .fontWeight(.medium)
                        Text("\(document.threads.count)")
                    }

                    GridRow {
                        Text("Modules:")
                            .fontWeight(.medium)
                        Text("\(document.modules.count)")
                    }

                    GridRow {
                        Text("Memory Regions:")
                            .fontWeight(.medium)
                        Text("\(document.memoryRegions.count)")
                    }

                    if let directory = document.streamDirectory {
                        GridRow {
                            Text("Streams:")
                                .fontWeight(.medium)
                            Text("\(directory.entries.count)")
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
