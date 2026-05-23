import Foundation

/// Errors that can occur during minidump parsing
public enum MinidumpParseError: Error, LocalizedError, Sendable {
    case invalidSignature
    case invalidHeader
    case invalidStreamDirectory
    case streamNotFound(StreamType)
    case parseError(String)

    public var errorDescription: String? {
        switch self {
        case .invalidSignature:
            return "Invalid minidump signature. Expected 'MDMP'."
        case .invalidHeader:
            return "Failed to parse minidump header."
        case .invalidStreamDirectory:
            return "Failed to parse stream directory."
        case .streamNotFound(let type):
            return "Required stream '\(type.displayName)' not found."
        case .parseError(let message):
            return "Parse error: \(message)"
        }
    }
}

/// A warning generated during parsing when a stream fails to parse
public struct ParseWarning: Sendable, Identifiable, Codable {
    private enum CodingKeys: String, CodingKey {
        case streamType, offset, message
    }

    public let id = UUID()
    public let streamType: StreamType?
    public let offset: UInt32?
    public let message: String

    public init(streamType: StreamType? = nil, offset: UInt32? = nil, message: String) {
        self.streamType = streamType
        self.offset = offset
        self.message = message
    }
}

/// Parsed minidump data
public struct ParsedMinidump: Sendable {
    public let header: MinidumpHeader
    public let streamDirectory: StreamDirectory
    public var systemInfo: SystemInfo?
    public var exception: ExceptionInfo?
    public var threadList: ThreadList?
    public var moduleList: ModuleList?
    public var memoryList: MemoryList?
    public var memory64List: Memory64List?
    public var memoryInfoList: MemoryInfoList?
    public var miscInfo: MiscInfo?
    public var unloadedModuleList: UnloadedModuleList?
    public var threadNames: ThreadNameList?
    public var handleData: HandleDataList?
    public var parseWarnings: [ParseWarning] = []

    public let data: Data  // Keep reference to file data for memory access

    public init(header: MinidumpHeader, streamDirectory: StreamDirectory, data: Data) {
        self.header = header
        self.streamDirectory = streamDirectory
        self.data = data
    }
}

/// Main parser for Windows minidump files
public struct MinidumpParser {
    /// Parse a minidump from file data
    public static func parse(data: Data) throws -> ParsedMinidump {
        // Parse header
        guard let header = MinidumpHeader(from: data) else {
            // Check signature specifically
            if let sig = data.readUInt32(at: 0), sig != MinidumpHeader.signature {
                throw MinidumpParseError.invalidSignature
            }
            throw MinidumpParseError.invalidHeader
        }

        // Parse stream directory
        guard let streamDirectory = StreamDirectory(from: data, header: header) else {
            throw MinidumpParseError.invalidStreamDirectory
        }

        var result = ParsedMinidump(
            header: header,
            streamDirectory: streamDirectory,
            data: data
        )

        // Parse each known stream type
        for entry in streamDirectory.entries {
            guard let type = entry.type else { continue }

            // ParseWarning already carries `offset = entry.rva`, so the
            // message itself only needs to name what failed.
            func warn(_ name: String) {
                result.parseWarnings.append(ParseWarning(
                    streamType: type,
                    offset: entry.rva,
                    message: "Failed to parse \(name) stream"
                ))
            }

            switch type {
            case .systemInfo:
                if var sysInfo = SystemInfo(from: data, at: entry.rva) {
                    // Read CSD version string if available
                    if sysInfo.csdVersionRva != 0 {
                        let version = data.readUTF16String(at: sysInfo.csdVersionRva)
                        sysInfo.setCsdVersion(version)
                    }
                    result.systemInfo = sysInfo
                } else {
                    warn("System Info")
                }

            case .exception:
                if let exception = ExceptionInfo(from: data, at: entry.rva) {
                    result.exception = exception
                } else {
                    warn("Exception")
                }

            case .threadList:
                if let threadList = ThreadList(from: data, at: entry.rva) {
                    result.threadList = threadList
                } else {
                    warn("Thread List")
                }

            case .moduleList:
                if let moduleList = ModuleList(from: data, at: entry.rva) {
                    result.moduleList = moduleList
                } else {
                    warn("Module List")
                }

            case .memoryList:
                if let memoryList = MemoryList(from: data, at: entry.rva) {
                    result.memoryList = memoryList
                } else {
                    warn("Memory List")
                }

            case .memory64List:
                if let memory64List = Memory64List(from: data, at: entry.rva) {
                    result.memory64List = memory64List
                } else {
                    warn("Memory64 List")
                }

            case .memoryInfoList:
                if let memoryInfoList = MemoryInfoList(from: data, at: entry.rva) {
                    result.memoryInfoList = memoryInfoList
                } else {
                    warn("Memory Info List")
                }

            case .miscInfo:
                if let miscInfo = MiscInfo(from: data, at: Int(entry.rva)) {
                    result.miscInfo = miscInfo
                } else {
                    warn("Misc Info")
                }

            case .unloadedModuleList:
                if let unloadedModuleList = UnloadedModuleList(from: data, at: entry.rva) {
                    result.unloadedModuleList = unloadedModuleList
                } else {
                    warn("Unloaded Module List")
                }

            case .threadNames:
                if let threadNames = ThreadNameList(from: data, at: entry.rva) {
                    result.threadNames = threadNames
                } else {
                    warn("Thread Names")
                }

            case .handleData:
                if let handleData = HandleDataList(from: data, at: entry.rva) {
                    result.handleData = handleData
                } else {
                    warn("Handle Data")
                }

            default:
                break
            }
        }

        return result
    }

    /// Read memory at a specific address from the parsed dump
    /// Tries Memory64List first (full-memory dumps), then falls back to MemoryList (standard dumps)
    public static func readMemory(from dump: ParsedMinidump, at address: UInt64, size: Int) -> Data? {
        if let result = dump.memory64List?.readMemory(at: address, size: size, from: dump.data) {
            return result
        }
        return dump.memoryList?.readMemory(at: address, size: size, from: dump.data)
    }

    /// Find which module contains a given address
    public static func resolveAddress(_ address: UInt64, in dump: ParsedMinidump) -> String {
        dump.moduleList?.resolve(address: address) ?? address.hexAddress
    }

    /// Get the faulting thread from an exception
    public static func faultingThread(in dump: ParsedMinidump) -> ThreadInfo? {
        guard let exception = dump.exception else { return nil }
        return dump.threadList?.thread(withId: exception.threadId)
    }
}
