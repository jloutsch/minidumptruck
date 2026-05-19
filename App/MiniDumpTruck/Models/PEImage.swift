import Foundation

/// Parsed export table of a loaded PE image, read from process memory.
/// Slice 1 of symbolication: named, non-forwarded exports only.
public struct PEExportTable: Sendable {
    /// DoS bound: maximum named exports parsed from one module.
    public static let maxExports = 200_000
    /// DoS bound: maximum symbol-name byte length scanned.
    public static let maxNameLength = 4096

    /// (functionRVA, name) sorted ascending by functionRVA.
    private let entries: [(rva: UInt32, name: String)]

    public init?(reader: MemoryReading, imageBase: UInt64, imageSize: UInt32) {
        // Bounds helper: every RVA read must sit inside the image.
        func abs32(_ rva: UInt32) -> UInt64? {
            guard rva < imageSize else { return nil }
            let (a, of) = imageBase.addingReportingOverflow(UInt64(rva))
            return of ? nil : a
        }

        // Absolute-address bounds helper: validates [addr, addr+need) ⊆ [imageBase, imageEnd).
        let imageEnd: UInt64? = {
            let (e, of) = imageBase.addingReportingOverflow(UInt64(imageSize))
            return of ? nil : e
        }()
        guard let imageEnd else { return nil }

        func inImage(_ addr: UInt64, _ need: Int) -> Bool {
            guard addr >= imageBase else { return false }
            let (top, of) = addr.addingReportingOverflow(UInt64(need))
            return !of && top <= imageEnd
        }

        // DOS header
        guard reader.readUInt16(at: imageBase) == 0x5A4D else { return nil }
        guard let eLfanew = reader.readUInt32(at: imageBase &+ 0x3C),
              let ntBase = abs32(eLfanew) else { return nil }

        // NT signature "PE\0\0"
        guard reader.readUInt32(at: ntBase) == 0x00004550 else { return nil }

        // Optional header magic decides where the data directory starts.
        let optStart = ntBase &+ 4 &+ 20
        guard inImage(optStart, 2) else { return nil }
        guard let magic = reader.readUInt16(at: optStart) else { return nil }
        let dirArrayOffset: UInt64
        switch magic {
        case 0x010B: dirArrayOffset = optStart &+ 96   // PE32
        case 0x020B: dirArrayOffset = optStart &+ 112  // PE32+
        default: return nil
        }

        // DataDirectory[0] = export directory (VirtualAddress, Size)
        guard inImage(dirArrayOffset, 8) else { return nil }
        guard let exportRVA = reader.readUInt32(at: dirArrayOffset),
              let exportSize = reader.readUInt32(at: dirArrayOffset &+ 4),
              exportRVA != 0, exportSize != 0,
              let edBase = abs32(exportRVA) else { return nil }

        guard inImage(edBase &+ 24, 16) else { return nil }
        guard let numberOfNames = reader.readUInt32(at: edBase &+ 24),
              let addrOfFunctions = reader.readUInt32(at: edBase &+ 28),
              let addrOfNames = reader.readUInt32(at: edBase &+ 32),
              let addrOfOrdinals = reader.readUInt32(at: edBase &+ 36),
              numberOfNames > 0,
              numberOfNames <= UInt32(Self.maxExports) else { return nil }

        let (exportEnd, exEndOf) = exportRVA.addingReportingOverflow(exportSize)
        if exEndOf { return nil }

        var collected: [(rva: UInt32, name: String)] = []

        for i in 0..<numberOfNames {
            guard let namesSlot = abs32(addrOfNames &+ i &* 4),
                  let ordSlot = abs32(addrOfOrdinals &+ i &* 2),
                  let nameRVA = reader.readUInt32(at: namesSlot),
                  let ordinal = reader.readUInt16(at: ordSlot),
                  let funcSlot = abs32(addrOfFunctions &+ UInt32(ordinal) &* 4),
                  let funcRVA = reader.readUInt32(at: funcSlot) else { continue }

            // Forwarder: function RVA points inside the export directory range.
            if funcRVA >= exportRVA && funcRVA < exportEnd { continue }

            guard let nameAddr = abs32(nameRVA),
                  let name = Self.cString(reader: reader, at: nameAddr,
                                          maxLen: Self.maxNameLength),
                  !name.isEmpty else { continue }

            collected.append((rva: funcRVA, name: name))
        }

        guard !collected.isEmpty else { return nil }
        collected.sort { $0.rva < $1.rva }
        self.entries = collected
    }

    /// Nearest exported function at or below `offset`. Returns name and byte delta.
    public func symbol(forImageOffset offset: UInt64) -> (name: String, delta: UInt64)? {
        guard offset <= UInt64(UInt32.max) else { return nil }
        let target = UInt32(offset)
        // Binary search for greatest entry with rva <= target.
        var lo = 0, hi = entries.count - 1, found = -1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if entries[mid].rva <= target { found = mid; lo = mid + 1 }
            else { hi = mid - 1 }
        }
        guard found >= 0 else { return nil }
        let e = entries[found]
        return (e.name, UInt64(target - e.rva))
    }

    private static func cString(reader: MemoryReading, at address: UInt64,
                                maxLen: Int) -> String? {
        guard let data = reader.read(at: address, size: maxLen), !data.isEmpty else {
            return nil
        }
        let bytes = Array(data)
        guard let nul = bytes.firstIndex(of: 0) else {
            return String(bytes: bytes, encoding: .utf8)
        }
        return String(bytes: bytes[0..<nul], encoding: .utf8)
    }
}
