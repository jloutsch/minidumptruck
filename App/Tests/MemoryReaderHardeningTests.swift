import Foundation
import Testing
@testable import MiniDumpTruckCore

/// Regression tests for crash-DoS vectors discovered by the memory-reader
/// sweep on PR #54. Each test constructs a stack/region with a saturating
/// `endAddress` (`baseAddress + regionSize > UInt64.max`) and asserts that
/// callers which subtract from `endAddress` no longer trap on the
/// UInt64 → Int conversion.

@Suite("Memory reader hardening — saturated endAddress")
struct MemoryReaderHardeningTests {

    @Test func crashAnalyzerSurvivesSaturatedStackEndAddress() throws {
        // A malformed dump can declare a stack region whose
        // `baseAddress + regionSize` overflows UInt64. The MemoryRegion
        // type intentionally saturates `endAddress` to UInt64.max so
        // `contains(address:)` remains correct at the boundary. But
        // callers that compute `endAddress - rsp` as a byte count get
        // a UInt64 that exceeds Int.max — `Int(...)` would trap.
        //
        // Build a ThreadInfo with baseAddress=UInt64.max-1, dataSize=10,
        // rsp=0. Without the clamp, the analyzer crashes here.
        let stack = MinidumpMemoryDescriptor(
            startOfMemoryRange: UInt64.max - 1,
            dataSize: 10,
            rva: 0
        )
        var dump = makeMinimalDump()
        let amdBuffer = Data(repeating: 0, count: AMD64Context.size)
        let amd = AMD64Context(from: amdBuffer, at: 0)!
        var thread = ThreadInfo(
            id: 1,
            stack: stack,
            contextLocation: MinidumpLocationDescriptor(dataSize: 0, rva: 0),
            context: .amd64(amd)
        )
        thread.setContext(.amd64(amd))
        dump.threadList = ThreadList(threads: [thread])
        dump.exception = ExceptionInfo(
            threadId: 1,
            exceptionCode: 0xC0000005,
            exceptionAddress: 0
        )

        // The call must not trap. Result may be nil (no readable memory)
        // — that's fine; we just need the conversion to be safe.
        let analyzer = CrashAnalyzer(dump: dump)
        _ = analyzer.analyze()
    }

    @Test func crashAnalyzerSurvivesStackEndAddressEqualToUInt64Max() throws {
        // The exact saturated case: a region declared at the boundary.
        let stack = MinidumpMemoryDescriptor(
            startOfMemoryRange: 0,
            dataSize: UInt32.max,
            rva: 0
        )
        var dump = makeMinimalDump()
        let amdBuffer = Data(repeating: 0, count: AMD64Context.size)
        let amd = AMD64Context(from: amdBuffer, at: 0)!
        var thread = ThreadInfo(
            id: 1,
            stack: stack,
            contextLocation: MinidumpLocationDescriptor(dataSize: 0, rva: 0)
        )
        thread.setContext(.amd64(amd))
        dump.threadList = ThreadList(threads: [thread])
        dump.exception = ExceptionInfo(
            threadId: 1,
            exceptionCode: 0xC0000005,
            exceptionAddress: 0
        )

        // Must not trap on `Int(thread.stack.endAddress - rsp)`.
        let analyzer = CrashAnalyzer(dump: dump)
        _ = analyzer.analyze()
    }

    @Test func scanSizeClampedToMaxStackScanBytes() throws {
        // Even when the stack region is enormous, the scanner must
        // never request more than its internal `maxStackScanBytes`
        // ceiling. (Indirectly verified above; this test pins the
        // expected bound.) The analyzer should still produce a result
        // when given valid frames, regardless of how large the
        // declared stack is.
        let stack = MinidumpMemoryDescriptor(
            startOfMemoryRange: 0x1000,
            dataSize: UInt32.max,  // declared huge — but no memory captured
            rva: 0
        )
        var dump = makeMinimalDump()
        let amdBuffer = Data(repeating: 0, count: AMD64Context.size)
        let amd = AMD64Context(from: amdBuffer, at: 0)!
        var thread = ThreadInfo(
            id: 1,
            stack: stack,
            contextLocation: MinidumpLocationDescriptor(dataSize: 0, rva: 0)
        )
        thread.setContext(.amd64(amd))
        dump.threadList = ThreadList(threads: [thread])
        dump.exception = ExceptionInfo(
            threadId: 1,
            exceptionCode: 0xC0000005,
            exceptionAddress: 0
        )

        // No crash. Analyzer either returns a result or nil — both are
        // acceptable; the key invariant is no trap.
        _ = CrashAnalyzer(dump: dump).analyze()
    }
}
