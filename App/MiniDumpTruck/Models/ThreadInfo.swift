import Foundation

/// Memory descriptor for stack or other memory regions
public struct MinidumpMemoryDescriptor {
    public let startOfMemoryRange: UInt64
    public let dataSize: UInt32
    public let rva: UInt32  // File offset to memory contents

    public var endAddress: UInt64 {
        let (result, overflow) = startOfMemoryRange.addingReportingOverflow(UInt64(dataSize))
        return overflow ? UInt64.max : result
    }

    public init?(from data: Data, at offset: Int) {
        guard let startOfMemoryRange = data.readUInt64(at: offset),
              let dataSize = data.readUInt32(at: offset + 8),
              let rva = data.readUInt32(at: offset + 12)
        else { return nil }

        self.startOfMemoryRange = startOfMemoryRange
        self.dataSize = dataSize
        self.rva = rva
    }
}

/// Location descriptor (RVA + size)
public struct MinidumpLocationDescriptor {
    public let dataSize: UInt32
    public let rva: UInt32

    public init?(from data: Data, at offset: Int) {
        guard let dataSize = data.readUInt32(at: offset),
              let rva = data.readUInt32(at: offset + 4)
        else { return nil }

        self.dataSize = dataSize
        self.rva = rva
    }
}

/// Thread information from ThreadListStream (48 bytes per thread)
public struct ThreadInfo: Identifiable {
    public static let size = 48

    public let id: UInt32  // Thread ID
    public let suspendCount: UInt32
    public let priorityClass: UInt32
    public let priority: UInt32
    public let teb: UInt64  // Thread Environment Block address
    public let stack: MinidumpMemoryDescriptor
    public let contextLocation: MinidumpLocationDescriptor

    public var context: ThreadContext?  // Populated after parsing

    public init?(from data: Data, at offset: Int) {
        guard let threadId = data.readUInt32(at: offset),
              let suspendCount = data.readUInt32(at: offset + 4),
              let priorityClass = data.readUInt32(at: offset + 8),
              let priority = data.readUInt32(at: offset + 12),
              let teb = data.readUInt64(at: offset + 16),
              let stack = MinidumpMemoryDescriptor(from: data, at: offset + 24),
              let contextLocation = MinidumpLocationDescriptor(from: data, at: offset + 40)
        else { return nil }

        self.id = threadId
        self.suspendCount = suspendCount
        self.priorityClass = priorityClass
        self.priority = priority
        self.teb = teb
        self.stack = stack
        self.contextLocation = contextLocation
        self.context = nil
    }

    public var priorityDescription: String {
        switch priority {
        case 0: return "Idle"
        case 1...6: return "Below Normal"
        case 7...8: return "Normal"
        case 9...13: return "Above Normal"
        case 14...15: return "High"
        case 16...31: return "Realtime"
        default: return "Unknown (\(priority))"
        }
    }

    public mutating func setContext(_ ctx: ThreadContext) {
        self.context = ctx
    }
}

/// Collection of threads from ThreadListStream
public struct ThreadList {
    /// Maximum allowed threads to prevent DoS from malformed dumps
    public static let maxThreads: UInt32 = 10_000

    public let threads: [ThreadInfo]

    public init?(from data: Data, at rva: UInt32) {
        let offset = Int(rva)

        // Validate RVA is within file bounds
        guard offset >= 0, offset + 4 <= data.count else { return nil }

        guard let count = data.readUInt32(at: offset) else { return nil }

        // Validate thread count to prevent DoS
        guard count <= Self.maxThreads else { return nil }

        var threads: [ThreadInfo] = []
        let threadCount = Int(count)

        // Validate thread array is within file bounds (with overflow protection)
        let (bytesNeeded, mulOverflow) = threadCount.multipliedReportingOverflow(by: ThreadInfo.size)
        guard !mulOverflow else { return nil }
        let (offsetPlusHeader, addOverflow1) = offset.addingReportingOverflow(4)
        guard !addOverflow1 else { return nil }
        let (threadsEnd, addOverflow2) = offsetPlusHeader.addingReportingOverflow(bytesNeeded)
        guard !addOverflow2, threadsEnd <= data.count else { return nil }

        for i in 0..<threadCount {
            let threadOffset = offset + 4 + (i * ThreadInfo.size)
            guard var thread = ThreadInfo(from: data, at: threadOffset) else { continue }

            // Parse context if available
            if thread.contextLocation.dataSize > 0 {
                let ctxOffset = Int(thread.contextLocation.rva)
                if let context = ThreadContext(from: data, at: ctxOffset) {
                    thread.setContext(context)
                }
            }

            threads.append(thread)
        }

        self.threads = threads
    }

    public func thread(withId id: UInt32) -> ThreadInfo? {
        threads.first { $0.id == id }
    }
}
