import Foundation

/// Version information structure (VS_FIXEDFILEINFO - 52 bytes)
public struct ModuleVersion {
    public let signature: UInt32  // 0xFEEF04BD
    public let structVersion: UInt32
    public let fileVersionHigh: UInt32
    public let fileVersionLow: UInt32
    public let productVersionHigh: UInt32
    public let productVersionLow: UInt32
    public let fileFlagsMask: UInt32
    public let fileFlags: UInt32
    public let fileOS: UInt32
    public let fileType: UInt32
    public let fileSubtype: UInt32
    public let fileDateHigh: UInt32
    public let fileDateLow: UInt32

    public var fileVersion: String {
        let major = (fileVersionHigh >> 16) & 0xFFFF
        let minor = fileVersionHigh & 0xFFFF
        let build = (fileVersionLow >> 16) & 0xFFFF
        let revision = fileVersionLow & 0xFFFF
        return "\(major).\(minor).\(build).\(revision)"
    }

    public var productVersion: String {
        let major = (productVersionHigh >> 16) & 0xFFFF
        let minor = productVersionHigh & 0xFFFF
        let build = (productVersionLow >> 16) & 0xFFFF
        let revision = productVersionLow & 0xFFFF
        return "\(major).\(minor).\(build).\(revision)"
    }

    public var fileTypeDescription: String {
        switch fileType {
        case 1: return "Application"
        case 2: return "DLL"
        case 3: return "Driver"
        case 4: return "Font"
        case 5: return "VXD"
        case 7: return "Static Library"
        default: return "Unknown"
        }
    }

    public init?(from data: Data, at offset: Int) {
        guard let signature = data.readUInt32(at: offset),
              signature == 0xFEEF04BD,
              let structVersion = data.readUInt32(at: offset + 4),
              let fileVersionHigh = data.readUInt32(at: offset + 8),
              let fileVersionLow = data.readUInt32(at: offset + 12),
              let productVersionHigh = data.readUInt32(at: offset + 16),
              let productVersionLow = data.readUInt32(at: offset + 20),
              let fileFlagsMask = data.readUInt32(at: offset + 24),
              let fileFlags = data.readUInt32(at: offset + 28),
              let fileOS = data.readUInt32(at: offset + 32),
              let fileType = data.readUInt32(at: offset + 36),
              let fileSubtype = data.readUInt32(at: offset + 40),
              let fileDateHigh = data.readUInt32(at: offset + 44),
              let fileDateLow = data.readUInt32(at: offset + 48)
        else { return nil }

        self.signature = signature
        self.structVersion = structVersion
        self.fileVersionHigh = fileVersionHigh
        self.fileVersionLow = fileVersionLow
        self.productVersionHigh = productVersionHigh
        self.productVersionLow = productVersionLow
        self.fileFlagsMask = fileFlagsMask
        self.fileFlags = fileFlags
        self.fileOS = fileOS
        self.fileType = fileType
        self.fileSubtype = fileSubtype
        self.fileDateHigh = fileDateHigh
        self.fileDateLow = fileDateLow
    }
}

/// Module information from ModuleListStream (108 bytes per module)
public struct ModuleInfo: Identifiable {
    public static let size = 108

    public let id = UUID()
    public let baseAddress: UInt64
    public let sizeOfImage: UInt32
    public let checksum: UInt32
    public let timeDateStamp: UInt32
    public let moduleNameRva: UInt32
    public let version: ModuleVersion?
    public let cvRecordLocation: MinidumpLocationDescriptor?
    public let miscRecordLocation: MinidumpLocationDescriptor?

    public var name: String = ""  // Populated after parsing
    public var timestamp: Date { Date(timeIntervalSince1970: TimeInterval(timeDateStamp)) }

    public var endAddress: UInt64 {
        baseAddress + UInt64(sizeOfImage)
    }

    public var shortName: String {
        // Extract just the filename from the full path
        // Handle both Windows backslashes and Unix forward slashes
        let lowercased = name.lowercased()
        if let lastBackslash = lowercased.lastIndex(of: "\\") {
            return String(name[name.index(after: lastBackslash)...])
        }
        if let lastSlash = lowercased.lastIndex(of: "/") {
            return String(name[name.index(after: lastSlash)...])
        }
        return name
    }

    public init?(from data: Data, at offset: Int) {
        guard let baseAddress = data.readUInt64(at: offset),
              let sizeOfImage = data.readUInt32(at: offset + 8),
              let checksum = data.readUInt32(at: offset + 12),
              let timeDateStamp = data.readUInt32(at: offset + 16),
              let moduleNameRva = data.readUInt32(at: offset + 20)
        else { return nil }

        self.baseAddress = baseAddress
        self.sizeOfImage = sizeOfImage
        self.checksum = checksum
        self.timeDateStamp = timeDateStamp
        self.moduleNameRva = moduleNameRva

        // Version info at offset 24 (52 bytes)
        self.version = ModuleVersion(from: data, at: offset + 24)

        // CV record at offset 76
        self.cvRecordLocation = MinidumpLocationDescriptor(from: data, at: offset + 76)

        // Misc record at offset 84
        self.miscRecordLocation = MinidumpLocationDescriptor(from: data, at: offset + 84)

        // Reserved fields at offset 92-107 (not needed)
    }

    public mutating func setName(_ name: String) {
        self.name = name
    }

    /// Check if an address falls within this module's range
    public func contains(address: UInt64) -> Bool {
        address >= baseAddress && address < endAddress
    }

    /// Get offset of an address within this module
    public func offset(for address: UInt64) -> UInt64? {
        guard contains(address: address) else { return nil }
        return address - baseAddress
    }
}

/// Collection of modules from ModuleListStream
public struct ModuleList {
    /// Maximum allowed modules to prevent DoS from malformed dumps
    public static let maxModules: UInt32 = 50_000

    public let modules: [ModuleInfo]

    public init?(from data: Data, at rva: UInt32) {
        let offset = Int(rva)

        // Validate RVA is within file bounds
        guard offset >= 0, offset + 4 <= data.count else { return nil }

        guard let count = data.readUInt32(at: offset) else { return nil }

        // Validate module count to prevent DoS
        guard count <= Self.maxModules else { return nil }

        var modules: [ModuleInfo] = []
        let moduleCount = Int(count)

        // Validate module array is within file bounds (with overflow protection)
        let (bytesNeeded, mulOverflow) = moduleCount.multipliedReportingOverflow(by: ModuleInfo.size)
        guard !mulOverflow else { return nil }
        let (offsetPlusHeader, addOverflow1) = offset.addingReportingOverflow(4)
        guard !addOverflow1 else { return nil }
        let (modulesEnd, addOverflow2) = offsetPlusHeader.addingReportingOverflow(bytesNeeded)
        guard !addOverflow2, modulesEnd <= data.count else { return nil }

        for i in 0..<moduleCount {
            let moduleOffset = offset + 4 + (i * ModuleInfo.size)
            guard var module = ModuleInfo(from: data, at: moduleOffset) else { continue }

            // Read module name from RVA
            if let name = data.readUTF16String(at: module.moduleNameRva) {
                module.setName(name)
            }

            modules.append(module)
        }

        self.modules = modules
    }

    /// Find the module containing a given address
    public func module(containing address: UInt64) -> ModuleInfo? {
        modules.first { $0.contains(address: address) }
    }

    /// Resolve an address to module + offset string
    public func resolve(address: UInt64) -> String {
        if let module = module(containing: address),
           let offset = module.offset(for: address) {
            return "\(module.shortName)+0x\(String(offset, radix: 16))"
        }
        return String(format: "0x%016llX", address)
    }
}
