import SwiftUI

struct SummaryView: View {
    let document: MinidumpDocument
    @Bindable var viewModel: DumpViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                headerSection

                Divider()

                // Exception summary (if present)
                if let exception = document.exception {
                    exceptionSection(exception)
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
