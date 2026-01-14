import Foundation

/// Windows Minidump file header (32 bytes)
/// Reference: https://learn.microsoft.com/en-us/windows/win32/api/minidumpapiset/ns-minidumpapiset-minidump_header
public struct MinidumpHeader {
    public static let signature: UInt32 = 0x504D444D  // "MDMP" in little-endian
    public static let size = 32

    public let version: UInt16
    public let implementationVersion: UInt16
    public let numberOfStreams: UInt32
    public let streamDirectoryRva: UInt32
    public let checksum: UInt32
    public let timeDateStamp: UInt32
    public let flags: UInt64

    public var timestamp: Date {
        Date(timeIntervalSince1970: TimeInterval(timeDateStamp))
    }

    public var flagsDescription: [String] {
        MinidumpType.descriptions(for: flags)
    }

    public init?(from data: Data) {
        guard data.count >= Self.size else { return nil }

        // Verify signature
        guard let sig = data.readUInt32(at: 0), sig == Self.signature else { return nil }

        guard let version = data.readUInt16(at: 4),
              let implementationVersion = data.readUInt16(at: 6),
              let numberOfStreams = data.readUInt32(at: 8),
              let streamDirectoryRva = data.readUInt32(at: 12),
              let checksum = data.readUInt32(at: 16),
              let timeDateStamp = data.readUInt32(at: 20),
              let flags = data.readUInt64(at: 24)
        else { return nil }

        self.version = version
        self.implementationVersion = implementationVersion
        self.numberOfStreams = numberOfStreams
        self.streamDirectoryRva = streamDirectoryRva
        self.checksum = checksum
        self.timeDateStamp = timeDateStamp
        self.flags = flags
    }
}

/// MINIDUMP_TYPE flags
public struct MinidumpType: OptionSet {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public static let normal: MinidumpType            = []
    public static let withDataSegs                   = MinidumpType(rawValue: 0x00000001)
    public static let withFullMemory                 = MinidumpType(rawValue: 0x00000002)
    public static let withHandleData                 = MinidumpType(rawValue: 0x00000004)
    public static let filterMemory                   = MinidumpType(rawValue: 0x00000008)
    public static let scanMemory                     = MinidumpType(rawValue: 0x00000010)
    public static let withUnloadedModules            = MinidumpType(rawValue: 0x00000020)
    public static let withIndirectlyReferencedMemory = MinidumpType(rawValue: 0x00000040)
    public static let filterModulePaths              = MinidumpType(rawValue: 0x00000080)
    public static let withProcessThreadData          = MinidumpType(rawValue: 0x00000100)
    public static let withPrivateReadWriteMemory     = MinidumpType(rawValue: 0x00000200)
    public static let withoutOptionalData            = MinidumpType(rawValue: 0x00000400)
    public static let withFullMemoryInfo             = MinidumpType(rawValue: 0x00000800)
    public static let withThreadInfo                 = MinidumpType(rawValue: 0x00001000)
    public static let withCodeSegs                   = MinidumpType(rawValue: 0x00002000)
    public static let withoutAuxiliaryState          = MinidumpType(rawValue: 0x00004000)
    public static let withFullAuxiliaryState         = MinidumpType(rawValue: 0x00008000)
    public static let withPrivateWriteCopyMemory     = MinidumpType(rawValue: 0x00010000)
    public static let ignoreInaccessibleMemory       = MinidumpType(rawValue: 0x00020000)
    public static let withTokenInformation           = MinidumpType(rawValue: 0x00040000)
    public static let withModuleHeaders              = MinidumpType(rawValue: 0x00080000)
    public static let filterTriage                   = MinidumpType(rawValue: 0x00100000)
    public static let withAvxXStateContext           = MinidumpType(rawValue: 0x00200000)
    public static let withIptTrace                   = MinidumpType(rawValue: 0x00400000)
    public static let scanInaccessiblePartialPages   = MinidumpType(rawValue: 0x00800000)

    public static func descriptions(for flags: UInt64) -> [String] {
        var result: [String] = []
        let type = MinidumpType(rawValue: flags)

        if type.contains(.withDataSegs) { result.append("WithDataSegs") }
        if type.contains(.withFullMemory) { result.append("WithFullMemory") }
        if type.contains(.withHandleData) { result.append("WithHandleData") }
        if type.contains(.filterMemory) { result.append("FilterMemory") }
        if type.contains(.scanMemory) { result.append("ScanMemory") }
        if type.contains(.withUnloadedModules) { result.append("WithUnloadedModules") }
        if type.contains(.withIndirectlyReferencedMemory) { result.append("WithIndirectlyReferencedMemory") }
        if type.contains(.filterModulePaths) { result.append("FilterModulePaths") }
        if type.contains(.withProcessThreadData) { result.append("WithProcessThreadData") }
        if type.contains(.withPrivateReadWriteMemory) { result.append("WithPrivateReadWriteMemory") }
        if type.contains(.withoutOptionalData) { result.append("WithoutOptionalData") }
        if type.contains(.withFullMemoryInfo) { result.append("WithFullMemoryInfo") }
        if type.contains(.withThreadInfo) { result.append("WithThreadInfo") }
        if type.contains(.withCodeSegs) { result.append("WithCodeSegs") }
        if type.contains(.withoutAuxiliaryState) { result.append("WithoutAuxiliaryState") }
        if type.contains(.withFullAuxiliaryState) { result.append("WithFullAuxiliaryState") }
        if type.contains(.withPrivateWriteCopyMemory) { result.append("WithPrivateWriteCopyMemory") }
        if type.contains(.ignoreInaccessibleMemory) { result.append("IgnoreInaccessibleMemory") }
        if type.contains(.withTokenInformation) { result.append("WithTokenInformation") }
        if type.contains(.withModuleHeaders) { result.append("WithModuleHeaders") }
        if type.contains(.filterTriage) { result.append("FilterTriage") }
        if type.contains(.withAvxXStateContext) { result.append("WithAvxXStateContext") }
        if type.contains(.withIptTrace) { result.append("WithIptTrace") }
        if type.contains(.scanInaccessiblePartialPages) { result.append("ScanInaccessiblePartialPages") }

        return result.isEmpty ? ["Normal"] : result
    }
}
