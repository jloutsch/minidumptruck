import Foundation

/// A single handle entry from the handle data stream
/// Reference: https://learn.microsoft.com/en-us/windows/win32/api/minidumpapiset/ns-minidumpapiset-minidump_handle_descriptor
public struct HandleEntry: Identifiable {
    public static let sizeV1 = 32  // MINIDUMP_HANDLE_DESCRIPTOR size
    public static let sizeV2 = 40  // MINIDUMP_HANDLE_DESCRIPTOR_2 size

    public let id = UUID()
    public let handle: UInt64
    public let typeNameRva: UInt32
    public let objectNameRva: UInt32
    public let attributes: UInt32
    public let grantedAccess: UInt32
    public let handleCount: UInt32
    public let pointerCount: UInt32

    // V2 fields
    public let objectInfoRva: UInt32?

    // Resolved strings
    public var typeName: String = ""
    public var objectName: String = ""

    public init?(from data: Data, at offset: Int, descriptorSize: Int) {
        let (end, endOverflow) = offset.addingReportingOverflow(descriptorSize)
        guard !endOverflow, end <= data.count else { return nil }

        guard let handle = data.readUInt64(at: offset),
              let typeNameRva = data.readUInt32(at: offset + 8),
              let objectNameRva = data.readUInt32(at: offset + 12),
              let attributes = data.readUInt32(at: offset + 16),
              let grantedAccess = data.readUInt32(at: offset + 20),
              let handleCount = data.readUInt32(at: offset + 24),
              let pointerCount = data.readUInt32(at: offset + 28)
        else { return nil }

        self.handle = handle
        self.typeNameRva = typeNameRva
        self.objectNameRva = objectNameRva
        self.attributes = attributes
        self.grantedAccess = grantedAccess
        self.handleCount = handleCount
        self.pointerCount = pointerCount

        // V2 has additional fields
        if descriptorSize >= Self.sizeV2 {
            self.objectInfoRva = data.readUInt32(at: offset + 32)
        } else {
            self.objectInfoRva = nil
        }
    }

    public mutating func setTypeName(_ name: String) {
        self.typeName = name
    }

    public mutating func setObjectName(_ name: String) {
        self.objectName = name
    }

    /// Format handle value as hex
    public var handleHex: String {
        String(format: "0x%llX", handle)
    }

    /// Format granted access as hex
    public var accessHex: String {
        String(format: "0x%08X", grantedAccess)
    }
}

/// Collection of handle data from HandleDataStream
/// Reference: https://learn.microsoft.com/en-us/windows/win32/api/minidumpapiset/ns-minidumpapiset-minidump_handle_data_stream
public struct HandleDataList {
    public static let headerSize = 16  // MINIDUMP_HANDLE_DATA_STREAM header size
    public static let maxEntries: UInt32 = 100_000

    public let sizeOfHeader: UInt32
    public let sizeOfDescriptor: UInt32
    public let entries: [HandleEntry]

    public var isVersion2: Bool {
        sizeOfDescriptor >= UInt32(HandleEntry.sizeV2)
    }

    public init?(from data: Data, at offset: UInt32) {
        let rva = Int(offset)

        // Read header
        guard let sizeOfHeader = data.readUInt32(at: rva),
              let sizeOfDescriptor = data.readUInt32(at: rva + 4),
              let numberOfDescriptors = data.readUInt32(at: rva + 8)
        else { return nil }
        // Reserved field at rva + 12

        self.sizeOfHeader = sizeOfHeader
        self.sizeOfDescriptor = sizeOfDescriptor

        // Validate
        guard sizeOfHeader >= UInt32(Self.headerSize),
              sizeOfDescriptor >= UInt32(HandleEntry.sizeV1),
              numberOfDescriptors <= Self.maxEntries
        else { return nil }

        var entries: [HandleEntry] = []
        let entriesOffset = rva + Int(sizeOfHeader)
        let entryCount = Int(numberOfDescriptors)
        let entrySizeInt = Int(sizeOfDescriptor)

        // Validate entries fit within file bounds (with overflow protection)
        let (bytesNeeded, mulOverflow) = entryCount.multipliedReportingOverflow(by: entrySizeInt)
        guard !mulOverflow else { return nil }
        let (entriesEnd, addOverflow) = entriesOffset.addingReportingOverflow(bytesNeeded)
        guard !addOverflow, entriesEnd <= data.count else { return nil }

        for i in 0..<entryCount {
            let entryOffset = entriesOffset + (i * entrySizeInt)

            guard var entry = HandleEntry(from: data, at: entryOffset, descriptorSize: Int(sizeOfDescriptor)) else {
                continue
            }

            // Read type name from RVA
            if entry.typeNameRva != 0 {
                if let name = data.readUTF16String(at: entry.typeNameRva) {
                    entry.setTypeName(name)
                }
            }

            // Read object name from RVA
            if entry.objectNameRva != 0 {
                if let name = data.readUTF16String(at: entry.objectNameRva) {
                    entry.setObjectName(name)
                }
            }

            entries.append(entry)
        }

        self.entries = entries
    }

    /// Get handles by type
    public func handles(ofType type: String) -> [HandleEntry] {
        entries.filter { $0.typeName.lowercased() == type.lowercased() }
    }

    /// Get count of handles by type
    public var handleTypesSummary: [(type: String, count: Int)] {
        var counts: [String: Int] = [:]
        for entry in entries {
            let type = entry.typeName.isEmpty ? "Unknown" : entry.typeName
            counts[type, default: 0] += 1
        }
        return counts.sorted { $0.value > $1.value }.map { (type: $0.key, count: $0.value) }
    }
}
