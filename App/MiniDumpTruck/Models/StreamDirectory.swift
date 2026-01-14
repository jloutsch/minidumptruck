import Foundation

/// Stream type identifiers in a Windows Minidump
/// Reference: https://learn.microsoft.com/en-us/windows/win32/api/minidumpapiset/ne-minidumpapiset-minidump_stream_type
public enum StreamType: UInt32, CaseIterable {
    case unused                    = 0
    case reserved0                 = 1
    case reserved1                 = 2
    case threadList                = 3
    case moduleList                = 4
    case memoryList                = 5
    case exception                 = 6
    case systemInfo                = 7
    case threadExList              = 8
    case memory64List              = 9
    case commentA                  = 10
    case commentW                  = 11
    case handleData                = 12
    case functionTable             = 13
    case unloadedModuleList        = 14
    case miscInfo                  = 15
    case memoryInfoList            = 16
    case threadInfoList            = 17
    case handleOperationList       = 18
    case token                     = 19
    case javaScriptData            = 20
    case systemMemoryInfo          = 21
    case processVmCounters         = 22
    case iptTrace                  = 23
    case threadNames               = 24

    public var displayName: String {
        switch self {
        case .unused: return "Unused"
        case .reserved0: return "Reserved0"
        case .reserved1: return "Reserved1"
        case .threadList: return "Thread List"
        case .moduleList: return "Module List"
        case .memoryList: return "Memory List"
        case .exception: return "Exception"
        case .systemInfo: return "System Info"
        case .threadExList: return "Thread Ex List"
        case .memory64List: return "Memory64 List"
        case .commentA: return "Comment (ANSI)"
        case .commentW: return "Comment (Unicode)"
        case .handleData: return "Handle Data"
        case .functionTable: return "Function Table"
        case .unloadedModuleList: return "Unloaded Module List"
        case .miscInfo: return "Misc Info"
        case .memoryInfoList: return "Memory Info List"
        case .threadInfoList: return "Thread Info List"
        case .handleOperationList: return "Handle Operation List"
        case .token: return "Token"
        case .javaScriptData: return "JavaScript Data"
        case .systemMemoryInfo: return "System Memory Info"
        case .processVmCounters: return "Process VM Counters"
        case .iptTrace: return "IPT Trace"
        case .threadNames: return "Thread Names"
        }
    }

    public var systemImage: String {
        switch self {
        case .threadList, .threadExList, .threadInfoList, .threadNames:
            return "text.line.first.and.arrowtriangle.forward"
        case .moduleList, .unloadedModuleList:
            return "shippingbox"
        case .memoryList, .memory64List, .memoryInfoList, .systemMemoryInfo:
            return "memorychip"
        case .exception:
            return "exclamationmark.triangle"
        case .systemInfo:
            return "info.circle"
        case .handleData, .handleOperationList:
            return "link"
        case .functionTable:
            return "function"
        case .miscInfo:
            return "ellipsis.circle"
        case .token:
            return "key"
        case .processVmCounters:
            return "gauge.with.dots.needle.bottom.50percent"
        default:
            return "doc"
        }
    }
}

/// A single entry in the stream directory (12 bytes)
public struct StreamDirectoryEntry: Identifiable {
    public static let size = 12

    public let id = UUID()
    public let streamType: UInt32
    public let dataSize: UInt32
    public let rva: UInt32  // Relative Virtual Address (file offset)

    public var type: StreamType? {
        StreamType(rawValue: streamType)
    }

    public var displayName: String {
        type?.displayName ?? "Unknown (\(streamType))"
    }

    public var systemImage: String {
        type?.systemImage ?? "questionmark.circle"
    }

    public init?(from data: Data, at offset: Int) {
        guard let streamType = data.readUInt32(at: offset),
              let dataSize = data.readUInt32(at: offset + 4),
              let rva = data.readUInt32(at: offset + 8)
        else { return nil }

        self.streamType = streamType
        self.dataSize = dataSize
        self.rva = rva
    }
}

/// Collection of stream directory entries
public struct StreamDirectory {
    /// Maximum allowed streams to prevent DoS from malformed dumps
    public static let maxStreams = 1000

    public let entries: [StreamDirectoryEntry]

    public init?(from data: Data, header: MinidumpHeader) {
        let directoryOffset = Int(header.streamDirectoryRva)

        // Validate stream count to prevent DoS
        guard header.numberOfStreams <= Self.maxStreams else { return nil }
        let count = Int(header.numberOfStreams)

        // Validate directory offset is within file bounds (with overflow protection)
        let (bytesNeeded, mulOverflow) = count.multipliedReportingOverflow(by: StreamDirectoryEntry.size)
        guard !mulOverflow else { return nil }
        let (directoryEnd, addOverflow) = directoryOffset.addingReportingOverflow(bytesNeeded)
        guard !addOverflow, directoryOffset >= 0, directoryEnd <= data.count else {
            return nil
        }

        var entries: [StreamDirectoryEntry] = []

        for i in 0..<count {
            let entryOffset = directoryOffset + (i * StreamDirectoryEntry.size)
            guard let entry = StreamDirectoryEntry(from: data, at: entryOffset) else {
                return nil
            }
            entries.append(entry)
        }

        self.entries = entries
    }

    public func stream(ofType type: StreamType) -> StreamDirectoryEntry? {
        entries.first { $0.type == type }
    }

    public func streams(ofType type: StreamType) -> [StreamDirectoryEntry] {
        entries.filter { $0.type == type }
    }
}
