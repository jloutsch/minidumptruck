import Foundation
import Testing
@testable import MiniDumpTruckCore

/// End-to-end check that `MinidumpParser` dispatches on
/// `contextLocation.dataSize` and produces a `.arm64(_)` thread context
/// for a 912-byte CONTEXT_ARM64 payload. Catches any regression in the
/// `ThreadList` plumbing that would silently fall back to AMD64.
@Suite("ARM64 minidump parses end-to-end")
struct ARM64MinidumpIntegrationTests {

    @Test func parserDispatchesToARM64ContextOnDataSize912() throws {
        let dump = try makeARM64SyntheticDump(
            pc: 0x0000_00AA_BBCC_DDEE,
            sp: 0x0000_007F_FFFF_F000,
            fp: 0x0000_007F_FFFF_F200,
            lr: 0x7FF0_0000_1234
        )

        let thread = try #require(dump.threadList?.threads.first,
                                  "synthetic dump must produce a thread")
        let ctx = try #require(thread.context,
                               "thread.context must be populated when dataSize=912")

        // Dispatch landed on the ARM64 case — not the AMD64 fallback.
        guard case .arm64(let arm) = ctx else {
            Issue.record("expected .arm64 case, got \(ctx.architectureName)")
            return
        }

        #expect(arm.pc == 0x0000_00AA_BBCC_DDEE)
        #expect(arm.sp == 0x0000_007F_FFFF_F000)
        #expect(arm.fp == 0x0000_007F_FFFF_F200)
        #expect(arm.lr == 0x7FF0_0000_1234)
        #expect(ctx.instructionPointer == arm.pc,
                "enum-level IP accessor must mirror the wrapped case")
    }

    @Test func archAgnosticAccessorsReturnARM64Names() throws {
        let dump = try makeARM64SyntheticDump(pc: 0, sp: 0, fp: 0)
        let ctx = try #require(dump.threadList?.threads.first?.context)
        #expect(ctx.architectureName == "ARM64")
        #expect(ctx.ipRegisterName == "PC")
        #expect(ctx.spRegisterName == "SP")
        #expect(ctx.fpRegisterName == "FP")
    }
}
