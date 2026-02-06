import SwiftUI
import MiniDumpTruckCore

struct ThreadDetailView: View {
    let thread: ThreadInfo
    let document: MinidumpDocument

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Thread Info Header
                GroupBox("Thread Information") {
                    Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
                        GridRow {
                            Text("Thread ID:")
                                .fontWeight(.medium)
                            Text("\(thread.id)")
                        }

                        GridRow {
                            Text("Priority:")
                                .fontWeight(.medium)
                            Text(thread.priorityDescription)
                        }

                        GridRow {
                            Text("Priority Class:")
                                .fontWeight(.medium)
                            Text("\(thread.priorityClass)")
                        }

                        GridRow {
                            Text("Suspend Count:")
                                .fontWeight(.medium)
                            Text("\(thread.suspendCount)")
                                .foregroundStyle(thread.suspendCount > 0 ? .orange : .primary)
                        }

                        GridRow {
                            Text("TEB Address:")
                                .fontWeight(.medium)
                            Text(String(format: "0x%016llX", thread.teb))
                                .fontDesign(.monospaced)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                // Stack Information
                GroupBox("Stack") {
                    Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
                        GridRow {
                            Text("Start:")
                                .fontWeight(.medium)
                            Text(String(format: "0x%016llX", thread.stack.startOfMemoryRange))
                                .fontDesign(.monospaced)
                        }

                        GridRow {
                            Text("End:")
                                .fontWeight(.medium)
                            Text(String(format: "0x%016llX", thread.stack.endAddress))
                                .fontDesign(.monospaced)
                        }

                        GridRow {
                            Text("Size:")
                                .fontWeight(.medium)
                            Text(ByteCountFormatter.string(fromByteCount: Int64(thread.stack.dataSize), countStyle: .memory))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                // Registers
                if let context = thread.context {
                    GroupBox("Registers") {
                        VStack(alignment: .leading, spacing: 16) {
                            // Instruction pointer
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Instruction Pointer")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                HStack {
                                    Text("RIP:")
                                        .fontWeight(.bold)
                                    Text(String(format: "0x%016llX", context.rip))
                                        .fontDesign(.monospaced)
                                        .foregroundStyle(.blue)

                                    if let module = document.module(containing: context.rip) {
                                        Text("(\(module.shortName))")
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }

                            Divider()

                            // General Purpose Registers
                            VStack(alignment: .leading, spacing: 4) {
                                Text("General Purpose Registers")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                LazyVGrid(columns: [
                                    GridItem(.flexible()),
                                    GridItem(.flexible())
                                ], spacing: 4) {
                                    ForEach(context.generalRegisters.filter { $0.name != "RIP" }, id: \.name) { reg in
                                        HStack {
                                            Text("\(reg.name):")
                                                .fontWeight(.medium)
                                                .frame(width: 35, alignment: .leading)
                                            Text(String(format: "0x%016llX", reg.value))
                                                .fontDesign(.monospaced)
                                                .font(.caption)
                                            Spacer()
                                        }
                                    }
                                }
                            }

                            Divider()

                            // Stack pointer highlight
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Stack Pointer")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                HStack {
                                    Text("RSP:")
                                        .fontWeight(.bold)
                                    Text(String(format: "0x%016llX", context.rsp))
                                        .fontDesign(.monospaced)
                                        .foregroundStyle(.green)
                                }
                            }

                            Divider()

                            // Flags
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Flags")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                HStack {
                                    Text("EFLAGS:")
                                        .fontWeight(.medium)
                                    Text(String(format: "0x%08X", context.eflags))
                                        .fontDesign(.monospaced)
                                }

                                if !context.eflagsDescription.isEmpty {
                                    HStack {
                                        ForEach(context.eflagsDescription, id: \.self) { flag in
                                            Text(flag)
                                                .font(.caption)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(.quaternary)
                                                .clipShape(Capsule())
                                        }
                                    }
                                }
                            }

                            Divider()

                            // Segment registers
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Segment Registers")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                HStack(spacing: 16) {
                                    ForEach(context.segmentRegisters, id: \.name) { reg in
                                        HStack(spacing: 4) {
                                            Text("\(reg.name):")
                                                .fontWeight(.medium)
                                            Text(String(format: "0x%04X", reg.value))
                                                .fontDesign(.monospaced)
                                                .font(.caption)
                                        }
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding()
        }
        .navigationTitle("Thread \(thread.id)")
    }
}
