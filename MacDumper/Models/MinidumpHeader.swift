import Foundation

/// Windows Minidump file header (32 bytes)
/// Reference: https://learn.microsoft.com/en-us/windows/win32/api/minidumpapiset/ns-minidumpapiset-minidump_header
struct MinidumpHeader {
    static let signature: UInt32 = 0x504D444D  // "MDMP" in little-endian
    static let size = 32

    let version: UInt16
    let implementationVersion: UInt16
    let numberOfStreams: UInt32
    let streamDirectoryRva: UInt32
    let checksum: UInt32
    let timeDateStamp: UInt32
    let flags: UInt64

    var timestamp: Date {
        Date(timeIntervalSince1970: TimeInterval(timeDateStamp))
    }

    var flagsDescription: [String] {
        MinidumpType.descriptions(for: flags)
    }

    init?(from data: Data) {
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
struct MinidumpType: OptionSet {
    let rawValue: UInt64

    static let normal: MinidumpType            = []
    static let withDataSegs                   = MinidumpType(rawValue: 0x00000001)
    static let withFullMemory                 = MinidumpType(rawValue: 0x00000002)
    static let withHandleData                 = MinidumpType(rawValue: 0x00000004)
    static let filterMemory                   = MinidumpType(rawValue: 0x00000008)
    static let scanMemory                     = MinidumpType(rawValue: 0x00000010)
    static let withUnloadedModules            = MinidumpType(rawValue: 0x00000020)
    static let withIndirectlyReferencedMemory = MinidumpType(rawValue: 0x00000040)
    static let filterModulePaths              = MinidumpType(rawValue: 0x00000080)
    static let withProcessThreadData          = MinidumpType(rawValue: 0x00000100)
    static let withPrivateReadWriteMemory     = MinidumpType(rawValue: 0x00000200)
    static let withoutOptionalData            = MinidumpType(rawValue: 0x00000400)
    static let withFullMemoryInfo             = MinidumpType(rawValue: 0x00000800)
    static let withThreadInfo                 = MinidumpType(rawValue: 0x00001000)
    static let withCodeSegs                   = MinidumpType(rawValue: 0x00002000)
    static let withoutAuxiliaryState          = MinidumpType(rawValue: 0x00004000)
    static let withFullAuxiliaryState         = MinidumpType(rawValue: 0x00008000)
    static let withPrivateWriteCopyMemory     = MinidumpType(rawValue: 0x00010000)
    static let ignoreInaccessibleMemory       = MinidumpType(rawValue: 0x00020000)
    static let withTokenInformation           = MinidumpType(rawValue: 0x00040000)
    static let withModuleHeaders              = MinidumpType(rawValue: 0x00080000)
    static let filterTriage                   = MinidumpType(rawValue: 0x00100000)
    static let withAvxXStateContext           = MinidumpType(rawValue: 0x00200000)
    static let withIptTrace                   = MinidumpType(rawValue: 0x00400000)
    static let scanInaccessiblePartialPages   = MinidumpType(rawValue: 0x00800000)

    static func descriptions(for flags: UInt64) -> [String] {
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
