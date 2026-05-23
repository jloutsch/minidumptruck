import Foundation
import Testing
@testable import MiniDumpTruckCore

@Suite("RuntimeFunctionTable lookup")
struct RuntimeFunctionTableTests {

    private func table(_ entries: [(begin: UInt32, end: UInt32)]) -> RuntimeFunctionTable {
        RuntimeFunctionTable(functions: entries.map {
            RuntimeFunction(beginRVA: $0.begin, endRVA: $0.end, unwindInfoRVA: 0xCAFE)
        })
    }

    @Test func lookupEmptyTableReturnsNil() {
        let t = table([])
        #expect(t.lookup(0x1000) == nil)
    }

    @Test func lookupExactBeginRVA() {
        let t = table([(0x1000, 0x1100)])
        let hit = t.lookup(0x1000)
        #expect(hit?.beginRVA == 0x1000)
        #expect(hit?.endRVA == 0x1100)
    }

    @Test func lookupInsideRangeMatches() {
        let t = table([(0x1000, 0x1100)])
        #expect(t.lookup(0x1080)?.beginRVA == 0x1000)
    }

    @Test func lookupExactEndRVAReturnsNil() {
        // endRVA is exclusive — the function does NOT cover its end
        // address.
        let t = table([(0x1000, 0x1100)])
        #expect(t.lookup(0x1100) == nil)
    }

    @Test func lookupBeforeFirstRangeReturnsNil() {
        let t = table([(0x2000, 0x2100)])
        #expect(t.lookup(0x1000) == nil)
    }

    @Test func lookupAcrossMultipleEntries() {
        let t = table([
            (0x1000, 0x1100),
            (0x2000, 0x2100),
            (0x3000, 0x3100),
        ])
        #expect(t.lookup(0x1050)?.beginRVA == 0x1000)
        #expect(t.lookup(0x2050)?.beginRVA == 0x2000)
        #expect(t.lookup(0x3050)?.beginRVA == 0x3000)
        #expect(t.lookup(0x1500) == nil,
                "gap between ranges must not match either side")
    }

    @Test func constructorSortsByBeginRVA() {
        // Unsorted input must be canonicalized so binary search works.
        let t = table([
            (0x3000, 0x3100),
            (0x1000, 0x1100),
            (0x2000, 0x2100),
        ])
        #expect(t.lookup(0x1050)?.beginRVA == 0x1000)
        #expect(t.lookup(0x2050)?.beginRVA == 0x2000)
        #expect(t.lookup(0x3050)?.beginRVA == 0x3000)
    }

    @Test func binarySearchHandlesLargeTable() {
        // 10k entries at 0x100 intervals. Binary search should resolve
        // any address in microseconds.
        var entries: [(UInt32, UInt32)] = []
        for i in 0..<10_000 {
            let begin = UInt32(0x10_0000 + i * 0x100)
            entries.append((begin, begin + 0x80))
        }
        let t = table(entries)
        // Random-ish lookups
        #expect(t.lookup(0x10_0000)?.beginRVA == 0x10_0000)
        #expect(t.lookup(0x10_0040)?.beginRVA == 0x10_0000,
                "lookup inside range hits the start entry")
        // Address at offset 0x80..0x100 falls in the gap between
        // adjacent function bodies — no match.
        #expect(t.lookup(0x10_00A0) == nil)
        let mid = 0x10_0000 + UInt32(5000 * 0x100)
        #expect(t.lookup(mid)?.beginRVA == mid)
    }

    @Test func parseInvalidLengthReturnsNil() {
        // 11 bytes — not a multiple of RuntimeFunction.size (12).
        let bad = Data(repeating: 0, count: 11)
        #expect(RuntimeFunctionTable(data: bad) == nil)
    }

    @Test func parseEmptyDataReturnsEmptyTable() {
        let table = RuntimeFunctionTable(data: Data())
        #expect(table?.functions.isEmpty == true)
    }
}
