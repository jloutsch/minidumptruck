import Foundation

/// Information about a module that was unloaded before the crash
/// Reference: https://learn.microsoft.com/en-us/windows/win32/api/minidumpapiset/ns-minidumpapiset-minidump_unloaded_module
public struct UnloadedModule: Identifiable {
    public static let size = 24  // MINIDUMP_UNLOADED_MODULE: BaseOfImage(8) + SizeOfImage(4) + CheckSum(4) + TimeDateStamp(4) + ModuleNameRva(4)

    public let id = UUID()
    public let baseAddress: UInt64
    public let sizeOfImage: UInt32
    public let checksum: UInt32
    public let timeDateStamp: UInt32
    public let moduleNameRva: UInt32

    public var name: String = ""  // Populated after parsing

    public var timestamp: Date {
        Date(timeIntervalSince1970: TimeInterval(timeDateStamp))
    }

    public var endAddress: UInt64 {
        let (result, overflow) = baseAddress.addingReportingOverflow(UInt64(sizeOfImage))
        return overflow ? UInt64.max : result
    }

    public var shortName: String {
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
    }

    public mutating func setName(_ name: String) {
        self.name = name
    }

    /// Check if an address falls within this module's former range
    public func contains(address: UInt64) -> Bool {
        address >= baseAddress && address < endAddress
    }
}

/// Collection of unloaded modules from UnloadedModuleListStream
public struct UnloadedModuleList {
    public static let maxModules: UInt32 = 10_000

    public let modules: [UnloadedModule]

    public init?(from data: Data, at offset: UInt32) {
        let rva = Int(offset)

        // Read size of header (should be 16 for MINIDUMP_UNLOADED_MODULE_LIST)
        guard let sizeOfHeader = data.readUInt32(at: rva) else { return nil }

        // Read size of each entry
        guard let sizeOfEntry = data.readUInt32(at: rva + 4) else { return nil }

        // Read number of entries
        guard let numberOfEntries = data.readUInt32(at: rva + 8),
              numberOfEntries <= Self.maxModules else { return nil }

        // Validate entry size is reasonable (must be at least minimum struct size)
        guard sizeOfEntry >= UInt32(UnloadedModule.size) else { return nil }
        // Prevent infinite loop with zero entry size
        guard sizeOfEntry > 0 else { return nil }

        var modules: [UnloadedModule] = []
        let entriesOffset = rva + Int(sizeOfHeader)
        let entrySize = Int(sizeOfEntry)

        // Validate entries fit within file bounds (with overflow protection)
        let entryCount = Int(numberOfEntries)
        let (bytesNeeded, mulOverflow) = entryCount.multipliedReportingOverflow(by: entrySize)
        guard !mulOverflow else { return nil }
        let (entriesEnd, addOverflow) = entriesOffset.addingReportingOverflow(bytesNeeded)
        guard !addOverflow, entriesEnd <= data.count else { return nil }

        for i in 0..<Int(numberOfEntries) {
            let entryOffset = entriesOffset + (i * entrySize)

            guard var module = UnloadedModule(from: data, at: entryOffset) else {
                continue
            }

            // Read module name
            if module.moduleNameRva != 0 {
                if let name = data.readUTF16String(at: module.moduleNameRva) {
                    module.setName(name)
                }
            }

            modules.append(module)
        }

        self.modules = modules
    }

    /// Find an unloaded module that contained a given address
    public func module(containing address: UInt64) -> UnloadedModule? {
        modules.first { $0.contains(address: address) }
    }

    /// Check if an address was in an unloaded module (potential use-after-unload)
    public func wasUnloaded(address: UInt64) -> Bool {
        module(containing: address) != nil
    }
}
