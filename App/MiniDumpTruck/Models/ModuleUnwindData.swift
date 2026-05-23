import Foundation

/// Per-module unwind data: the `RUNTIME_FUNCTION` table read from
/// `.pdata` plus on-demand access to `UNWIND_INFO` records in
/// `.xdata`. Built once per module when the symbolicator first needs
/// it, then queried per-frame by the stack walker.
///
/// All RVAs are relative to the module's image base. Memory reads go
/// through the supplied `MemoryReading` so an OOM-mapped PE in dump
/// memory works transparently.
public struct ModuleUnwindData: Sendable {
    public let imageBase: UInt64
    public let imageSize: UInt32
    public let runtimeFunctions: RuntimeFunctionTable
    private let reader: MemoryReading

    public init?(reader: MemoryReading, imageBase: UInt64, imageSize: UInt32) {
        self.reader = reader
        self.imageBase = imageBase
        self.imageSize = imageSize

        // Walk the PE optional header to find DataDirectory[3] =
        // exception directory. Layout matches the export-table walk
        // in PEExportTable.init.
        guard let exceptionDir = Self.locateExceptionDirectory(
            reader: reader,
            imageBase: imageBase,
            imageSize: imageSize
        ),
        exceptionDir.size > 0,
        exceptionDir.size.isMultiple(of: UInt32(RuntimeFunction.size)),
        exceptionDir.size <= UInt32(RuntimeFunctionTable.maxEntries) * UInt32(RuntimeFunction.size)
        else { return nil }

        // Read the contiguous .pdata blob.
        let (absStart, ofStart) = imageBase.addingReportingOverflow(UInt64(exceptionDir.rva))
        guard !ofStart else { return nil }
        guard let pdataBytes = reader.read(at: absStart, size: Int(exceptionDir.size)),
              pdataBytes.count == Int(exceptionDir.size) else {
            return nil
        }
        guard let table = RuntimeFunctionTable(data: pdataBytes) else { return nil }
        self.runtimeFunctions = table
    }

    /// Cheap eligibility check: does this module's PE header advertise
    /// a non-empty exception directory? Used by the unwind cache to
    /// answer `hasAnyUnwindData` without paying the .pdata read + sort
    /// cost upfront. A `true` here does not guarantee the full
    /// `init?` will succeed (a malformed .pdata still fails), but a
    /// `false` is conclusive — no unwind data possible.
    public static func hasExceptionDirectory(
        reader: MemoryReading,
        imageBase: UInt64,
        imageSize: UInt32
    ) -> Bool {
        guard let dir = locateExceptionDirectory(
            reader: reader,
            imageBase: imageBase,
            imageSize: imageSize
        ) else { return false }
        return dir.size > 0
    }

    /// PE data-directory entry: RVA + byte size.
    private struct DataDirectoryEntry { let rva: UInt32; let size: UInt32 }

    /// Walk DOS + NT + optional header and read `DataDirectory[3]`
    /// (the exception directory). Returns nil if any header field is
    /// malformed or the directory is absent.
    private static func locateExceptionDirectory(
        reader: MemoryReading,
        imageBase: UInt64,
        imageSize: UInt32
    ) -> DataDirectoryEntry? {
        func abs32(_ rva: UInt32) -> UInt64? {
            guard rva < imageSize else { return nil }
            let (a, of) = imageBase.addingReportingOverflow(UInt64(rva))
            return of ? nil : a
        }

        // DOS magic 'MZ'.
        guard reader.readUInt16(at: imageBase) == 0x5A4D else { return nil }
        guard let eLfanew = reader.readUInt32(at: imageBase &+ 0x3C),
              let ntBase = abs32(eLfanew) else { return nil }
        // NT signature "PE\0\0".
        guard reader.readUInt32(at: ntBase) == 0x00004550 else { return nil }

        // Optional header magic chooses the directory array offset.
        let optStart = ntBase &+ 4 &+ 20
        guard let magic = reader.readUInt16(at: optStart) else { return nil }
        let dirArrayOffset: UInt64
        switch magic {
        case 0x010B: dirArrayOffset = optStart &+ 96    // PE32
        case 0x020B: dirArrayOffset = optStart &+ 112   // PE32+
        default: return nil
        }

        // DataDirectory[3] = exception directory.
        let entryOffset = dirArrayOffset &+ UInt64(3 * 8)
        guard let rva = reader.readUInt32(at: entryOffset),
              let size = reader.readUInt32(at: entryOffset &+ 4) else {
            return nil
        }
        guard rva != 0 else { return nil }
        return DataDirectoryEntry(rva: rva, size: size)
    }

    /// Read and parse the `UNWIND_INFO` record at the given RVA. The
    /// stack walker calls this once per frame after locating the
    /// covering `RUNTIME_FUNCTION` via `runtimeFunctions.lookup(_:)`.
    public func unwindInfo(at rva: UInt32) -> UnwindInfo? {
        // We don't know the record's size upfront (it depends on
        // countOfCodes + flags). Read a generous chunk and let
        // UnwindInfo.init bounds-check itself.
        let maxRecordBytes = 4 + Int(UnwindInfo.maxCodes) * 2 + 16  // header + codes + chained record / handler
        let (absStart, of) = imageBase.addingReportingOverflow(UInt64(rva))
        guard !of else { return nil }
        guard let bytes = reader.read(at: absStart, size: maxRecordBytes),
              !bytes.isEmpty else {
            return nil
        }
        return UnwindInfo(from: bytes, at: 0)
    }
}
