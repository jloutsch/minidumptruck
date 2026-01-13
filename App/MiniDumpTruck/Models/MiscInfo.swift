import Foundation

/// MINIDUMP_MISC_INFO flags
public struct MiscInfoFlags: OptionSet {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let processId        = MiscInfoFlags(rawValue: 0x00000001)
    public static let processTimes     = MiscInfoFlags(rawValue: 0x00000002)
    public static let processorPower   = MiscInfoFlags(rawValue: 0x00000004)
    public static let processIntegrity = MiscInfoFlags(rawValue: 0x00000010)
    public static let processExecuteFlags = MiscInfoFlags(rawValue: 0x00000020)
    public static let timezone         = MiscInfoFlags(rawValue: 0x00000040)
    public static let protectedProcess = MiscInfoFlags(rawValue: 0x00000080)
    public static let buildString      = MiscInfoFlags(rawValue: 0x00000100)
    public static let processPrivileges = MiscInfoFlags(rawValue: 0x00000200)
}

/// Miscellaneous process information from MiscInfoStream
/// Reference: https://learn.microsoft.com/en-us/windows/win32/api/minidumpapiset/ns-minidumpapiset-minidump_misc_info
public struct MiscInfo {
    public static let minSize = 24  // MINIDUMP_MISC_INFO minimum size

    public let sizeOfInfo: UInt32
    public let flags: MiscInfoFlags

    // Process identification (flags & processId)
    public let processId: UInt32?

    // Process times (flags & processTimes)
    public let processCreateTime: Date?
    public let processUserTime: TimeInterval?   // In seconds
    public let processKernelTime: TimeInterval? // In seconds

    // Processor power info (flags & processorPower) - MISC_INFO_2
    public let processorMaxMhz: UInt32?
    public let processorCurrentMhz: UInt32?
    public let processorMhzLimit: UInt32?
    public let processorMaxIdleState: UInt32?
    public let processorCurrentIdleState: UInt32?

    // Process integrity (flags & processIntegrity) - MISC_INFO_3
    public let processIntegrityLevel: UInt32?
    public let processExecuteFlags: UInt32?

    // Protected process (flags & protectedProcess) - MISC_INFO_3
    public let protectedProcess: UInt32?

    // Timezone (flags & timezone) - MISC_INFO_3
    public let timeZoneId: UInt32?
    public let timeZoneBias: Int32?
    public let timeZoneName: String?
    public let daylightName: String?

    // Build string (flags & buildString) - MISC_INFO_4
    public let buildString: String?
    public let dbgBldStr: String?

    // Process privileges (flags & processPrivileges) - MISC_INFO_5
    public let processPrivileges: UInt64?

    public init?(from data: Data, at offset: Int) {
        let rva = Int(offset)

        // Read size first to determine version
        guard let sizeOfInfo = data.readUInt32(at: rva) else { return nil }
        self.sizeOfInfo = sizeOfInfo

        guard sizeOfInfo >= UInt32(Self.minSize),
              rva + Int(sizeOfInfo) <= data.count else { return nil }

        guard let flagsRaw = data.readUInt32(at: rva + 4) else { return nil }
        self.flags = MiscInfoFlags(rawValue: flagsRaw)

        // Process ID (offset 8)
        if flags.contains(.processId), let pid = data.readUInt32(at: rva + 8) {
            self.processId = pid
        } else {
            self.processId = nil
        }

        // Process times (offset 12-20)
        if flags.contains(.processTimes) {
            if let createTime = data.readUInt32(at: rva + 12), createTime != 0 {
                self.processCreateTime = Date(timeIntervalSince1970: TimeInterval(createTime))
            } else {
                self.processCreateTime = nil
            }

            if let userTime = data.readUInt32(at: rva + 16) {
                // User time is in seconds
                self.processUserTime = TimeInterval(userTime)
            } else {
                self.processUserTime = nil
            }

            if let kernelTime = data.readUInt32(at: rva + 20) {
                // Kernel time is in seconds
                self.processKernelTime = TimeInterval(kernelTime)
            } else {
                self.processKernelTime = nil
            }
        } else {
            self.processCreateTime = nil
            self.processUserTime = nil
            self.processKernelTime = nil
        }

        // MISC_INFO_2 fields (processor power) - starts at offset 24
        if sizeOfInfo >= 44 && flags.contains(.processorPower) {
            self.processorMaxMhz = data.readUInt32(at: rva + 24)
            self.processorCurrentMhz = data.readUInt32(at: rva + 28)
            self.processorMhzLimit = data.readUInt32(at: rva + 32)
            self.processorMaxIdleState = data.readUInt32(at: rva + 36)
            self.processorCurrentIdleState = data.readUInt32(at: rva + 40)
        } else {
            self.processorMaxMhz = nil
            self.processorCurrentMhz = nil
            self.processorMhzLimit = nil
            self.processorMaxIdleState = nil
            self.processorCurrentIdleState = nil
        }

        // MISC_INFO_3 fields - starts at offset 44
        if sizeOfInfo >= 232 {
            if flags.contains(.processIntegrity) {
                self.processIntegrityLevel = data.readUInt32(at: rva + 44)
            } else {
                self.processIntegrityLevel = nil
            }

            if flags.contains(.processExecuteFlags) {
                self.processExecuteFlags = data.readUInt32(at: rva + 48)
            } else {
                self.processExecuteFlags = nil
            }

            if flags.contains(.protectedProcess) {
                self.protectedProcess = data.readUInt32(at: rva + 52)
            } else {
                self.protectedProcess = nil
            }

            if flags.contains(.timezone) {
                self.timeZoneId = data.readUInt32(at: rva + 56)
                // TIME_ZONE_INFORMATION structure at offset 60
                // Read as UInt32 and convert to Int32 to handle negative biases
                if let biasRaw = data.readUInt32(at: rva + 60) {
                    self.timeZoneBias = Int32(bitPattern: biasRaw)
                } else {
                    self.timeZoneBias = nil
                }

                // Standard name at offset 64 (64 bytes, 32 WCHARs)
                self.timeZoneName = data.readFixedUTF16String(at: rva + 64, maxBytes: 64)

                // Daylight name at offset 196 (after SYSTEMTIME structures)
                self.daylightName = data.readFixedUTF16String(at: rva + 196, maxBytes: 64)
            } else {
                self.timeZoneId = nil
                self.timeZoneBias = nil
                self.timeZoneName = nil
                self.daylightName = nil
            }
        } else {
            self.processIntegrityLevel = nil
            self.processExecuteFlags = nil
            self.protectedProcess = nil
            self.timeZoneId = nil
            self.timeZoneBias = nil
            self.timeZoneName = nil
            self.daylightName = nil
        }

        // MISC_INFO_4 fields (build strings) - starts at offset 232
        if sizeOfInfo >= 1128 && flags.contains(.buildString) {
            // BuildString at offset 232 (520 bytes, 260 WCHARs)
            self.buildString = data.readFixedUTF16String(at: rva + 232, maxBytes: 520)
            // DbgBldStr at offset 752 (80 bytes, 40 WCHARs)
            self.dbgBldStr = data.readFixedUTF16String(at: rva + 752, maxBytes: 80)
        } else {
            self.buildString = nil
            self.dbgBldStr = nil
        }

        // MISC_INFO_5 fields (process privileges)
        if sizeOfInfo >= 1144 && flags.contains(.processPrivileges) {
            // Actually at different offset, but let's handle basic case
            self.processPrivileges = nil
        } else {
            self.processPrivileges = nil
        }
    }

    /// Human-readable process uptime
    public var processUptime: String? {
        guard let userTime = processUserTime,
              let kernelTime = processKernelTime else { return nil }

        let totalSeconds = Int(userTime + kernelTime)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%d:%02d", minutes, seconds)
        }
    }

    /// Formatted process create time
    public var formattedCreateTime: String? {
        guard let createTime = processCreateTime else { return nil }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter.string(from: createTime)
    }

    /// Processor frequency description
    public var processorFrequency: String? {
        guard let current = processorCurrentMhz else { return nil }
        if let max = processorMaxMhz {
            return "\(current) MHz (max: \(max) MHz)"
        }
        return "\(current) MHz"
    }

    /// Integrity level description
    public var integrityLevelDescription: String? {
        guard let level = processIntegrityLevel else { return nil }
        switch level {
        case 0x0000: return "Untrusted"
        case 0x1000: return "Low"
        case 0x2000: return "Medium"
        case 0x2100: return "Medium Plus"
        case 0x3000: return "High"
        case 0x4000: return "System"
        case 0x5000: return "Protected Process"
        default: return "Level \(level)"
        }
    }
}
