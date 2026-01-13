import SwiftUI
import MiniDumpTruckCore

struct ExceptionView: View {
    let exception: ExceptionInfo
    let document: MinidumpDocument
    @Bindable var viewModel: DumpViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Exception Header
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.red)

                    VStack(alignment: .leading) {
                        Text(exception.exceptionName)
                            .font(.title2)
                            .fontWeight(.bold)
                            .foregroundStyle(.red)

                        Text(exception.exceptionDescription)
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

                // Exception Details
                GroupBox("Exception Details") {
                    Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
                        GridRow {
                            Text("Code:")
                                .fontWeight(.medium)
                            Text(String(format: "0x%08X", exception.exceptionCode))
                                .fontDesign(.monospaced)
                        }

                        GridRow {
                            Text("Severity:")
                                .fontWeight(.medium)
                            Text(NTStatusCodes.severityString(for: exception.exceptionCode))
                                .foregroundStyle(NTStatusCodes.isError(exception.exceptionCode) ? .red : .primary)
                        }

                        GridRow {
                            Text("Flags:")
                                .fontWeight(.medium)
                            Text(String(format: "0x%08X", exception.exceptionFlags))
                                .fontDesign(.monospaced)
                        }

                        GridRow {
                            Text("Address:")
                                .fontWeight(.medium)
                            HStack {
                                Text(String(format: "0x%016llX", exception.exceptionAddress))
                                    .fontDesign(.monospaced)

                                if let module = document.module(containing: exception.exceptionAddress) {
                                    Button(module.shortName) {
                                        viewModel.selectModule(module)
                                    }
                                    .buttonStyle(.link)
                                }
                            }
                        }

                        GridRow {
                            Text("Thread:")
                                .fontWeight(.medium)
                            HStack {
                                Text("\(exception.threadId)")

                                if let thread = document.threads.first(where: { $0.id == exception.threadId }) {
                                    Button("View Thread") {
                                        viewModel.selectThread(thread)
                                    }
                                    .buttonStyle(.link)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                // Access Violation Details
                if let details = exception.accessViolationDetails {
                    GroupBox("Access Violation Details") {
                        Text(details)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                // Exception Parameters
                if !exception.exceptionParameters.isEmpty {
                    GroupBox("Exception Parameters") {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(exception.exceptionParameters.enumerated()), id: \.offset) { index, param in
                                HStack {
                                    Text("Parameter[\(index)]:")
                                        .fontWeight(.medium)
                                    Text(String(format: "0x%016llX", param))
                                        .fontDesign(.monospaced)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                // Faulting Thread Context
                if let thread = document.faultingThread,
                   let context = thread.context {
                    GroupBox("Faulting Thread Registers") {
                        RegisterGridView(context: context)
                    }
                }
            }
            .padding()
        }
        .navigationTitle("Exception")
        .textSelection(.enabled)
    }
}

struct RegisterGridView: View {
    let context: ThreadContext

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Instruction pointer
            HStack {
                Text("RIP:")
                    .fontWeight(.bold)
                    .frame(width: 40, alignment: .leading)
                Text(String(format: "0x%016llX", context.rip))
                    .fontDesign(.monospaced)
                    .foregroundStyle(.blue)
            }

            Divider()

            // General registers in grid
            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible()),
                GridItem(.flexible()),
                GridItem(.flexible())
            ], spacing: 8) {
                ForEach(context.generalRegisters.dropLast(), id: \.name) { reg in
                    HStack {
                        Text("\(reg.name):")
                            .fontWeight(.medium)
                            .frame(width: 35, alignment: .leading)
                        Text(String(format: "%016llX", reg.value))
                            .fontDesign(.monospaced)
                            .font(.caption)
                    }
                }
            }

            Divider()

            // Flags
            HStack {
                Text("EFLAGS:")
                    .fontWeight(.medium)
                Text(String(format: "0x%08X", context.eflags))
                    .fontDesign(.monospaced)
                Text("[\(context.eflagsDescription.joined(separator: " "))]")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
