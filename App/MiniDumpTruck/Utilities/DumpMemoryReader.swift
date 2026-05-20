import Foundation

/// Abstraction over a source of process memory addressed by virtual address.
/// Production code reads from a dump; tests use an in-memory buffer.
public protocol MemoryReading: Sendable {
    func read(at address: UInt64, size: Int) -> Data?
}

public extension MemoryReading {
    func readUInt16(at address: UInt64) -> UInt16? {
        guard let d = read(at: address, size: 2), d.count == 2 else { return nil }
        return d.readUInt16(at: 0)
    }
    func readUInt32(at address: UInt64) -> UInt32? {
        guard let d = read(at: address, size: 4), d.count == 4 else { return nil }
        return d.readUInt32(at: 0)
    }
    func readUInt64(at address: UInt64) -> UInt64? {
        guard let d = read(at: address, size: 8), d.count == 8 else { return nil }
        return d.readUInt64(at: 0)
    }
}

/// Reads process memory out of a parsed minidump. Single source of truth for
/// the Memory64List-then-MemoryList fallback, delegating to the tested
/// `MinidumpParser.readMemory`.
public struct DumpMemoryReader: MemoryReading {
    private let dump: ParsedMinidump

    public init(dump: ParsedMinidump) {
        self.dump = dump
    }

    public func read(at address: UInt64, size: Int) -> Data? {
        guard size > 0 else { return nil }
        return MinidumpParser.readMemory(from: dump, at: address, size: size)
    }
}
