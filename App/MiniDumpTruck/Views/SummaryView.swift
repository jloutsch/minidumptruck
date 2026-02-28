import SwiftUI
import MiniDumpTruckCore

struct SummaryView: View {
    let document: MinidumpDocument
    @Bindable var viewModel: DumpViewModel
    @State private var analysis: CrashAnalysis?
    @State private var isAnalyzing = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                headerSection

                // Parse warnings (if any)
                if !document.parseWarnings.isEmpty {
                    Divider()
                    warningsSection
                }

                Divider()

                // Exception summary (if present)
                if let exception = document.exception {
                    exceptionSection(exception)
                    Divider()
                }

                // Crash diagnosis (if analysis available)
                if isAnalyzing {
                    ProgressView("Analyzing crash...")
                        .frame(maxWidth: .infinity)
                } else if let analysis = analysis {
                    diagnosisSection(analysis)
                    Divider()
                }

                // System info
                if let systemInfo = document.systemInfo {
                    systemSection(systemInfo)
                    Divider()
                }

                // Quick stats
                statsSection
            }
            .padding()
        }
        .navigationTitle("Crash Summary")
        .textSelection(.enabled)
        .task {
            await runAnalysis()
        }
    }

    private func runAnalysis() async {
        guard let dump = document.parsedDump, dump.exception != nil else { return }
        isAnalyzing = true
        let result = await Task.detached(priority: .userInitiated) {
            CrashAnalyzer(dump: dump).analyze()
        }.value
        analysis = result
        isAnalyzing = false
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let header = document.header {
                HStack {
                    Image(systemName: "doc.text")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading) {
                        Text("Windows Minidump")
                            .font(.title2)
                            .fontWeight(.semibold)

                        Text("Created: \(header.timestamp.formatted())")
                            .foregroundStyle(.secondary)

                        Text("Size: \(ByteCountFormatter.string(fromByteCount: Int64(document.fileSize), countStyle: .file))")
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

                Text(analysis.confidence.displayName + " Confidence")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(confidenceColor(analysis.confidence))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(confidenceColor(analysis.confidence).opacity(0.15))
                    .clipShape(Capsule())
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    // Probable cause
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Probable Cause")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Text(analysis.crashSummary.probableCause)
                            .foregroundStyle(.secondary)
                    }

                    // Blamed module
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

                    // Recommendation
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Recommendation")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Text(analysis.crashSummary.recommendation)
                            .foregroundStyle(.secondary)
                    }

                    // Link to full analysis
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

    private func confidenceColor(_ confidence: AnalysisConfidence) -> Color {
        switch confidence {
        case .high: return .green
        case .medium: return .orange
        case .low: return .gray
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
