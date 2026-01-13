import Foundation

/// Memory protection flags
struct MemoryProtection: OptionSet {
    let rawValue: UInt32

    static let noAccess          = MemoryProtection(rawValue: 0x01)
    static let readonly          = MemoryProtection(rawValue: 0x02)
    static let readWrite         = MemoryProtection(rawValue: 0x04)
    static let writeCopy         = MemoryProtection(rawValue: 0x08)
    static let execute           = MemoryProtection(rawValue: 0x10)
    static let executeRead       = MemoryProtection(rawValue: 0x20)
    static let executeReadWrite  = MemoryProtection(rawValue: 0x40)
    static let executeWriteCopy  = MemoryProtection(rawValue: 0x80)
    static let guard_            = MemoryProtection(rawValue: 0x100)
    static let noCache           = MemoryProtection(rawValue: 0x200)
    static let writeCombine      = MemoryProtection(rawValue: 0x400)

    var shortDescription: String {
        var parts: [String] = []

        if contains(.executeReadWrite) { parts.append("RWX") }
        else if contains(.executeRead) { parts.append("RX") }
        else if contains(.execute) { parts.append("X") }
        else if contains(.readWrite) { parts.append("RW") }
        else if contains(.readonly) { parts.append("R") }
        else if contains(.noAccess) { parts.append("-") }
        else if contains(.writeCopy) { parts.append("WC") }
        else if contains(.executeWriteCopy) { parts.append("XWC") }

        if contains(.guard_) { parts.append("G") }
        if contains(.noCache) { parts.append("NC") }
        if contains(.writeCombine) { parts.append("WCB") }

        return parts.isEmpty ? "?" : parts.joined(separator: "+")
    }
}

/// Memory state values
enum MemoryState: UInt32 {
    case commit  = 0x1000
    case reserve = 0x2000
    case free    = 0x10000

    var displayName: String {
        switch self {
        case .commit: return "Commit"
        case .reserve: return "Reserve"
        case .free: return "Free"
        }
    }
}

/// Memory type values
enum MemoryType: UInt32 {
    case image   = 0x1000000
    case mapped  = 0x40000
    case `private` = 0x20000

    var displayName: String {
        switch self {
        case .image: return "Image"
        case .mapped: return "Mapped"
        case .private: return "Private"
        }
    }
}

/// Memory region from Memory64ListStream
struct MemoryRegion: Identifiable {
    let id = UUID()
    let baseAddress: UInt64
    let regionSize: UInt64
    let dataRva: UInt64?  // File offset to memory contents

    var endAddress: UInt64 { baseAddress + regionSize }

    /// Check if an address falls within this region
    func contains(address: UInt64) -> Bool {
        address >= baseAddress && address < endAddress
    }
}

/// Memory info from MemoryInfoListStream (more detailed than MemoryRegion)
struct MemoryInfo: Identifiable {
    let id = UUID()
    let baseAddress: UInt64
    let allocationBase: UInt64
    let allocationProtect: MemoryProtection
    let regionSize: UInt64
    let state: MemoryState
    let protect: MemoryProtection
    let type: MemoryType

    var endAddress: UInt64 { baseAddress + regionSize }

    init?(from data: Data, at offset: Int) {
        guard let baseAddress = data.readUInt64(at: offset),
              let allocationBase = data.readUInt64(at: offset + 8),
              let allocationProtect = data.readUInt32(at: offset + 16),
              // Skip 4 bytes padding
              let regionSize = data.readUInt64(at: offset + 24),
              let state = data.readUInt32(at: offset + 32),
              let protect = data.readUInt32(at: offset + 36),
              let type = data.readUInt32(at: offset + 40)
        else { return nil }

        self.baseAddress = baseAddress
        self.allocationBase = allocationBase
        self.allocationProtect = MemoryProtection(rawValue: allocationProtect)
        self.regionSize = regionSize
        self.state = MemoryState(rawValue: state) ?? .free
        self.protect = MemoryProtection(rawValue: protect)
        self.type = MemoryType(rawValue: type) ?? .private
    }
}

/// Collection of memory regions from Memory64ListStream
struct Memory64List {
    /// Maximum allowed memory regions to prevent DoS from malformed dumps
    static let maxRegions: UInt64 = 100_000

    let regions: [MemoryRegion]
    let baseRva: UInt64  // File offset where memory data starts

    init?(from data: Data, at rva: UInt32) {
        let offset = Int(rva)

        // Validate RVA is within file bounds
        guard offset >= 0, offset + 16 <= data.count else { return nil }

        // Number of memory ranges (8 bytes)
        guard let numberOfRanges = data.readUInt64(at: offset) else { return nil }

        // Validate region count to prevent DoS
        guard numberOfRanges <= Self.maxRegions else { return nil }

        // Base RVA where memory data starts (8 bytes)
        guard let baseRva = data.readUInt64(at: offset + 8) else { return nil }

        self.baseRva = baseRva

        var regions: [MemoryRegion] = []
        var dataOffset = baseRva
        let rangeCount = Int(numberOfRanges)

        // Validate descriptor area is within file bounds
        let descriptorsEnd = offset + 16 + (rangeCount * 16)
        guard descriptorsEnd <= data.count else { return nil }

        // Each descriptor is 16 bytes: StartOfMemoryRange (8) + DataSize (8)
        for i in 0..<rangeCount {
            let descriptorOffset = offset + 16 + (i * 16)
            guard let startAddress = data.readUInt64(at: descriptorOffset),
                  let dataSize = data.readUInt64(at: descriptorOffset + 8)
            else { continue }

            let region = MemoryRegion(
                baseAddress: startAddress,
                regionSize: dataSize,
                dataRva: dataOffset
            )
            regions.append(region)

            // Safe overflow check for dataOffset
            let (newOffset, overflow) = dataOffset.addingReportingOverflow(dataSize)
            if overflow { break }
            dataOffset = newOffset
        }

        self.regions = regions
    }

    /// Find region containing the given address
    func region(containing address: UInt64) -> MemoryRegion? {
        regions.first { $0.contains(address: address) }
    }

    /// Read memory at an address from the dump file data
    func readMemory(at address: UInt64, size: Int, from data: Data) -> Data? {
        guard let region = region(containing: address),
              let dataRva = region.dataRva else { return nil }

        let offsetInRegion = address - region.baseAddress
        let fileOffset = Int(dataRva + offsetInRegion)
        let availableSize = Int(region.regionSize - offsetInRegion)
        let readSize = min(size, availableSize)

        return data.subdata(at: fileOffset, count: readSize)
    }
}

/// Collection of memory info entries from MemoryInfoListStream
struct MemoryInfoList {
    static let entrySize = 48
    /// Maximum allowed entries to prevent DoS from malformed dumps
    static let maxEntries: UInt64 = 1_000_000

    let entries: [MemoryInfo]

    init?(from data: Data, at rva: UInt32) {
        let offset = Int(rva)

        // Validate RVA is within file bounds
        guard offset >= 0, offset + 16 <= data.count else { return nil }

        // SizeOfHeader (4 bytes)
        guard let sizeOfHeader = data.readUInt32(at: offset) else { return nil }
        // SizeOfEntry (4 bytes)
        guard let sizeOfEntry = data.readUInt32(at: offset + 4) else { return nil }
        // NumberOfEntries (8 bytes)
        guard let numberOfEntries = data.readUInt64(at: offset + 8) else { return nil }

        // Validate entry count to prevent DoS
        guard numberOfEntries <= Self.maxEntries else { return nil }

        var entries: [MemoryInfo] = []
        let entryCount = Int(numberOfEntries)
        let entrySizeInt = Int(sizeOfEntry)

        // Validate entries fit within file bounds
        let entriesEnd = offset + Int(sizeOfHeader) + (entryCount * entrySizeInt)
        guard entriesEnd <= data.count else { return nil }

        for i in 0..<entryCount {
            let entryOffset = offset + Int(sizeOfHeader) + (i * entrySizeInt)
            if let entry = MemoryInfo(from: data, at: entryOffset) {
                entries.append(entry)
            }
        }

        self.entries = entries
    }
}
