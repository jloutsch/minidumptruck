import Foundation

/// Errors that can occur during minidump parsing
enum MinidumpParseError: Error, LocalizedError {
    case invalidSignature
    case invalidHeader
    case invalidStreamDirectory
    case streamNotFound(StreamType)
    case parseError(String)

    var errorDescription: String? {
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

/// Parsed minidump data
struct ParsedMinidump {
    let header: MinidumpHeader
    let streamDirectory: StreamDirectory
    var systemInfo: SystemInfo?
    var exception: ExceptionInfo?
    var threadList: ThreadList?
    var moduleList: ModuleList?
    var memory64List: Memory64List?
    var memoryInfoList: MemoryInfoList?

    let data: Data  // Keep reference to file data for memory access
}

/// Main parser for Windows minidump files
struct MinidumpParser {
    /// Parse a minidump from file data
    static func parse(data: Data) throws -> ParsedMinidump {
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

            switch type {
            case .systemInfo:
                if var sysInfo = SystemInfo(from: data, at: entry.rva) {
                    // Read CSD version string if available
                    if sysInfo.csdVersionRva != 0 {
                        let version = data.readUTF16String(at: sysInfo.csdVersionRva)
                        sysInfo.setCsdVersion(version)
                    }
                    result.systemInfo = sysInfo
                }

            case .exception:
                result.exception = ExceptionInfo(from: data, at: entry.rva)

            case .threadList:
                result.threadList = ThreadList(from: data, at: entry.rva)

            case .moduleList:
                result.moduleList = ModuleList(from: data, at: entry.rva)

            case .memory64List:
                result.memory64List = Memory64List(from: data, at: entry.rva)

            case .memoryInfoList:
                result.memoryInfoList = MemoryInfoList(from: data, at: entry.rva)

            default:
                break
            }
        }

        return result
    }

    /// Read memory at a specific address from the parsed dump
    static func readMemory(from dump: ParsedMinidump, at address: UInt64, size: Int) -> Data? {
        dump.memory64List?.readMemory(at: address, size: size, from: dump.data)
    }

    /// Find which module contains a given address
    static func resolveAddress(_ address: UInt64, in dump: ParsedMinidump) -> String {
        dump.moduleList?.resolve(address: address) ?? String(format: "0x%016llX", address)
    }

    /// Get the faulting thread from an exception
    static func faultingThread(in dump: ParsedMinidump) -> ThreadInfo? {
        guard let exception = dump.exception else { return nil }
        return dump.threadList?.thread(withId: exception.threadId)
    }
}
