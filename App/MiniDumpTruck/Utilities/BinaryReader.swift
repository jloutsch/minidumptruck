import Foundation

/// Extension for reading binary data in little-endian format
public extension Data {
    /// Read a fixed-width integer at the specified byte offset (little-endian)
    func read<T: FixedWidthInteger>(_ type: T.Type, at offset: Int) -> T? {
        let size = MemoryLayout<T>.size
        guard offset >= 0, offset + size <= count else { return nil }

        // Use safe byte-by-byte reading to avoid alignment issues
        var value: T = 0
        for i in 0..<size {
            let byte = self[self.startIndex + offset + i]
            value |= T(byte) << (i * 8)  // Little-endian: LSB first
        }
        return value
    }

    /// Read a UInt8 at the specified offset
    func readUInt8(at offset: Int) -> UInt8? {
        read(UInt8.self, at: offset)
    }

    /// Read a UInt16 (little-endian) at the specified offset
    func readUInt16(at offset: Int) -> UInt16? {
        read(UInt16.self, at: offset)
    }

    /// Read a UInt32 (little-endian) at the specified offset
    func readUInt32(at offset: Int) -> UInt32? {
        read(UInt32.self, at: offset)
    }

    /// Read a UInt64 (little-endian) at the specified offset
    func readUInt64(at offset: Int) -> UInt64? {
        read(UInt64.self, at: offset)
    }

    /// Read a null-terminated UTF-16LE string at the RVA offset
    func readUTF16String(at rva: UInt32) -> String? {
        let offset = Int(rva)
        guard offset >= 0, offset + 4 <= count else { return nil }

        // First 4 bytes are the length in bytes, then the string data
        guard let length = readUInt32(at: offset) else { return nil }
        let stringOffset = offset + 4
        let stringLength = Int(length)

        // Safe bounds check with overflow protection
        let (end, overflow) = stringOffset.addingReportingOverflow(stringLength)
        guard !overflow, end <= count else { return nil }
        let stringData = self[stringOffset..<end]

        return String(data: stringData, encoding: .utf16LittleEndian)
    }

    /// Read a fixed-length UTF-16LE string (null-terminated within buffer)
    func readFixedUTF16String(at offset: Int, maxBytes: Int) -> String? {
        guard offset >= 0, offset + maxBytes <= count else { return nil }
        let stringData = self[offset..<(offset + maxBytes)]

        // Find null terminator
        var bytes: [UInt8] = []
        var i = 0
        while i + 1 < maxBytes {
            let low = stringData[stringData.startIndex + i]
            let high = stringData[stringData.startIndex + i + 1]
            if low == 0 && high == 0 { break }
            bytes.append(low)
            bytes.append(high)
            i += 2
        }

        return String(data: Data(bytes), encoding: .utf16LittleEndian)
    }

    /// Extract a subrange of data
    func subdata(at offset: Int, count: Int) -> Data? {
        guard offset >= 0, offset + count <= self.count else { return nil }
        return self[offset..<(offset + count)]
    }

    /// Read raw bytes at offset
    func readBytes(at offset: Int, count: Int) -> [UInt8]? {
        guard offset >= 0, offset + count <= self.count else { return nil }
        return Array(self[offset..<(offset + count)])
    }
}

/// A reader that tracks position in binary data
public struct BinaryDataReader {
    public let data: Data
    public private(set) var position: Int = 0

    public init(data: Data) {
        self.data = data
    }

    public var remaining: Int { data.count - position }
    public var isAtEnd: Bool { position >= data.count }

    public mutating func seek(to offset: Int) {
        position = max(0, min(offset, data.count))
    }

    public mutating func skip(_ count: Int) {
        position += count
    }

    public mutating func read<T: FixedWidthInteger>(_ type: T.Type) -> T? {
        guard let value = data.read(type, at: position) else { return nil }
        position += MemoryLayout<T>.size
        return value
    }

    public mutating func readUInt8() -> UInt8? { read(UInt8.self) }
    public mutating func readUInt16() -> UInt16? { read(UInt16.self) }
    public mutating func readUInt32() -> UInt32? { read(UInt32.self) }
    public mutating func readUInt64() -> UInt64? { read(UInt64.self) }

    public mutating func readBytes(_ count: Int) -> [UInt8]? {
        guard let bytes = data.readBytes(at: position, count: count) else { return nil }
        position += count
        return bytes
    }
}
