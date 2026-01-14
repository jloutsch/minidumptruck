import SwiftUI
import MiniDumpTruckCore

struct MiscInfoView: View {
    let miscInfo: MiscInfo

    var body: some View {
        List {
            // Process Information Section
            Section("Process Information") {
                if let pid = miscInfo.processId {
                    LabeledContent("Process ID", value: "\(pid)")
                }

                if let createTime = miscInfo.formattedCreateTime {
                    LabeledContent("Create Time", value: createTime)
                }

                if let userTime = miscInfo.processUserTime {
                    LabeledContent("User Time", value: formatTime(userTime))
                }

                if let kernelTime = miscInfo.processKernelTime {
                    LabeledContent("Kernel Time", value: formatTime(kernelTime))
                }

                if let uptime = miscInfo.processUptime {
                    LabeledContent("CPU Time", value: uptime)
                }
            }

            // Processor Information Section
            if miscInfo.processorMaxMhz != nil || miscInfo.processorCurrentMhz != nil {
                Section("Processor") {
                    if let freq = miscInfo.processorFrequency {
                        LabeledContent("Frequency", value: freq)
                    }

                    if let limit = miscInfo.processorMhzLimit {
                        LabeledContent("MHz Limit", value: "\(limit) MHz")
                    }

                    if let maxIdle = miscInfo.processorMaxIdleState {
                        LabeledContent("Max Idle State", value: "\(maxIdle)")
                    }

                    if let currentIdle = miscInfo.processorCurrentIdleState {
                        LabeledContent("Current Idle State", value: "\(currentIdle)")
                    }
                }
            }

            // Security Section
            if miscInfo.processIntegrityLevel != nil || miscInfo.protectedProcess != nil {
                Section("Security") {
                    if let integrity = miscInfo.integrityLevelDescription {
                        LabeledContent("Integrity Level", value: integrity)
                    }

                    if let execFlags = miscInfo.processExecuteFlags {
                        LabeledContent("Execute Flags", value: String(format: "0x%08X", execFlags))
                    }

                    if let protected = miscInfo.protectedProcess, protected != 0 {
                        LabeledContent("Protected Process", value: "Yes")
                    }
                }
            }

            // Timezone Section
            if miscInfo.timeZoneName != nil || miscInfo.timeZoneBias != nil {
                Section("Timezone") {
                    if let tzName = miscInfo.timeZoneName, !tzName.isEmpty {
                        LabeledContent("Timezone", value: tzName)
                    }

                    if let bias = miscInfo.timeZoneBias {
                        let hours = abs(bias) / 60
                        let minutes = abs(bias) % 60
                        let sign = bias <= 0 ? "+" : "-"
                        LabeledContent("UTC Offset", value: "\(sign)\(hours):\(String(format: "%02d", minutes))")
                    }

                    if let dlName = miscInfo.daylightName, !dlName.isEmpty {
                        LabeledContent("Daylight Name", value: dlName)
                    }
                }
            }

            // Build Information Section
            if miscInfo.buildString != nil || miscInfo.dbgBldStr != nil {
                Section("Build Information") {
                    if let buildStr = miscInfo.buildString, !buildStr.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Build String")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(buildStr)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }

                    if let dbgStr = miscInfo.dbgBldStr, !dbgStr.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Debug Build String")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(dbgStr)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                }
            }

            // Raw Data Section
            Section("Raw Data") {
                LabeledContent("Structure Size", value: "\(miscInfo.sizeOfInfo) bytes")
                LabeledContent("Flags", value: String(format: "0x%08X", miscInfo.flags.rawValue))

                // Show which flags are set
                VStack(alignment: .leading, spacing: 2) {
                    Text("Available Data:")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 8) {
                        ForEach(flagDescriptions, id: \.self) { flag in
                            Text(flag)
                                .font(.caption)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.blue.opacity(0.2))
                                .clipShape(Capsule())
                        }
                    }
                }
            }
        }
        .navigationTitle("Misc Info")
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        let totalSeconds = Int(seconds)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        } else if minutes > 0 {
            return String(format: "%d:%02d", minutes, secs)
        } else {
            return "\(secs) seconds"
        }
    }

    private var flagDescriptions: [String] {
        var flags: [String] = []
        if miscInfo.flags.contains(.processId) { flags.append("PID") }
        if miscInfo.flags.contains(.processTimes) { flags.append("Times") }
        if miscInfo.flags.contains(.processorPower) { flags.append("Power") }
        if miscInfo.flags.contains(.processIntegrity) { flags.append("Integrity") }
        if miscInfo.flags.contains(.processExecuteFlags) { flags.append("ExecFlags") }
        if miscInfo.flags.contains(.timezone) { flags.append("Timezone") }
        if miscInfo.flags.contains(.protectedProcess) { flags.append("Protected") }
        if miscInfo.flags.contains(.buildString) { flags.append("BuildStr") }
        return flags
    }
}
