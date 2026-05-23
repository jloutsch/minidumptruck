import Foundation

/// One entry in a PE module's exception directory (`.pdata`).
/// Maps an instruction address range to its `UNWIND_INFO` record.
///
/// Layout (12 bytes, all RVAs relative to the module's image base):
///
///     0  BeginAddress       u32   // first byte of the function
///     4  EndAddress         u32   // first byte AFTER the function
///     8  UnwindInfoAddress  u32   // RVA into the module's .xdata
///
/// Reference: x64 software conventions, section "Exception
/// Handling Data" (Microsoft Learn / SDK winnt.h).
public struct RuntimeFunction: Hashable, Sendable {
    public static let size = 12

    public let beginRVA: UInt32
    public let endRVA: UInt32
    public let unwindInfoRVA: UInt32

    public init(beginRVA: UInt32, endRVA: UInt32, unwindInfoRVA: UInt32) {
        self.beginRVA = beginRVA
        self.endRVA = endRVA
        self.unwindInfoRVA = unwindInfoRVA
    }

    public init?(from data: Data, at offset: Int) {
        guard let beginRVA = data.readUInt32(at: offset),
              let endRVA = data.readUInt32(at: offset + 4),
              let unwindInfoRVA = data.readUInt32(at: offset + 8) else {
            return nil
        }
        self.beginRVA = beginRVA
        self.endRVA = endRVA
        self.unwindInfoRVA = unwindInfoRVA
    }

    /// True if `rva` falls in `[beginRVA, endRVA)`.
    public func contains(_ rva: UInt32) -> Bool {
        rva >= beginRVA && rva < endRVA
    }
}

/// Sorted array of `RuntimeFunction` entries supporting binary-search
/// lookup. Constructed from the bytes the PE exception data directory
/// points at.
public struct RuntimeFunctionTable: Sendable {
    /// DoS cap. Real Windows DLLs ship with up to ~50k entries
    /// (e.g. ntdll). A malformed PE claiming millions would force us
    /// to copy and sort a huge array.
    public static let maxEntries = 250_000

    public let functions: [RuntimeFunction]

    public init(functions: [RuntimeFunction]) {
        self.functions = functions.sorted { $0.beginRVA < $1.beginRVA }
    }

    /// Parse a flat `.pdata` byte buffer into a `RuntimeFunctionTable`.
    /// `data` must contain a contiguous array of 12-byte
    /// `RUNTIME_FUNCTION` records (the format the PE exception data
    /// directory points to). Returns nil on size mismatch or DoS-cap
    /// violation.
    public init?(data: Data) {
        guard data.count.isMultiple(of: RuntimeFunction.size) else { return nil }
        let count = data.count / RuntimeFunction.size
        guard count <= Self.maxEntries else { return nil }
        var entries: [RuntimeFunction] = []
        entries.reserveCapacity(count)
        for i in 0..<count {
            guard let entry = RuntimeFunction(from: data, at: i * RuntimeFunction.size) else {
                return nil
            }
            entries.append(entry)
        }
        self.init(functions: entries)
    }

    /// Find the entry whose range contains `rva`. O(log N) binary
    /// search since the table is sorted by `beginRVA`.
    ///
    /// PE exception tables are always sorted; if a malformed PE
    /// produced an unsorted array, the constructor's `.sorted` call
    /// normalizes it (~250k comparisons one-time, then queries are
    /// fast).
    public func lookup(_ rva: UInt32) -> RuntimeFunction? {
        guard !functions.isEmpty else { return nil }
        var lo = 0
        var hi = functions.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if functions[mid].beginRVA <= rva {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        // After the loop, lo is the first index whose beginRVA > rva.
        // The candidate entry is at lo - 1.
        guard lo > 0 else { return nil }
        let candidate = functions[lo - 1]
        return candidate.contains(rva) ? candidate : nil
    }
}
