import Foundation

/// A single thread name entry
/// Reference: https://learn.microsoft.com/en-us/windows/win32/api/minidumpapiset/ns-minidumpapiset-minidump_thread_name
public struct ThreadNameEntry: Identifiable {
    public static let size = 16  // MINIDUMP_THREAD_NAME size

    public let id = UUID()
    public let threadId: UInt32
    public let threadNameRva: UInt64  // Actually RVA64 in the struct

    public var name: String = ""  // Populated after parsing

    public init?(from data: Data, at offset: Int) {
        guard let threadId = data.readUInt32(at: offset),
              let threadNameRva = data.readUInt64(at: offset + 8)
        else { return nil }

        self.threadId = threadId
        self.threadNameRva = threadNameRva
    }

    public mutating func setName(_ name: String) {
        self.name = name
    }
}

/// Collection of thread names from ThreadNamesStream
public struct ThreadNameList {
    public static let maxEntries: UInt32 = 50_000

    public let entries: [ThreadNameEntry]
    private let namesByThreadId: [UInt32: String]

    public init?(from data: Data, at offset: UInt32) {
        let rva = Int(offset)

        // Read number of entries
        guard let numberOfEntries = data.readUInt32(at: rva),
              numberOfEntries <= Self.maxEntries else { return nil }

        var entries: [ThreadNameEntry] = []
        var namesByThreadId: [UInt32: String] = [:]

        let entriesOffset = rva + 4  // After count field

        for i in 0..<Int(numberOfEntries) {
            let entryOffset = entriesOffset + (i * ThreadNameEntry.size)

            guard var entry = ThreadNameEntry(from: data, at: entryOffset) else {
                continue
            }

            // Read thread name from RVA
            if entry.threadNameRva != 0 && entry.threadNameRva <= UInt64(UInt32.max) {
                // The name is stored as a MINIDUMP_STRING (length + UTF-16LE data)
                if let name = data.readUTF16String(at: UInt32(truncatingIfNeeded: entry.threadNameRva)) {
                    entry.setName(name)
                    namesByThreadId[entry.threadId] = name
                }
            }

            entries.append(entry)
        }

        self.entries = entries
        self.namesByThreadId = namesByThreadId
    }

    /// Get the name for a thread by its ID
    public func name(for threadId: UInt32) -> String? {
        namesByThreadId[threadId]
    }

    /// Check if a thread has a name
    public func hasName(for threadId: UInt32) -> Bool {
        namesByThreadId[threadId] != nil
    }
}
