import Foundation
import Testing
@testable import MiniDumpTruckCore

/// Address the four substantive review gaps for #4 in one file:
/// (a) full end-to-end ARM64 minidump parse through MinidumpParser,
/// (b) `walkAArch64FrameChain` behavioral coverage,
/// (c) ARM64-specific exporter output assertions, and
/// (d) Codable round-trip locking the context schema.

private extension Data {
    mutating func writeLEUInt16(_ value: UInt16, at offset: Int) {
        self[offset]     = UInt8(value & 0xFF)
        self[offset + 1] = UInt8((value >> 8) & 0xFF)
    }
    mutating func writeLEUInt32(_ value: UInt32, at offset: Int) {
        for i in 0..<4 { self[offset + i] = UInt8((value >> (i * 8)) & 0xFF) }
    }
    mutating func writeLEUInt64(_ value: UInt64, at offset: Int) {
        for i in 0..<8 { self[offset + i] = UInt8((value >> (i * 8)) & 0xFF) }
    }
}

/// Build a complete synthetic ARM64 minidump:
/// header + stream directory + Exception + ThreadList + ModuleList +
/// Memory64List + a 912-byte CONTEXT_ARM64 with the supplied register
/// values.
///
/// `stackData`, when provided, is written into the Memory64 region
/// covering `[stackBase, stackBase + stackData.count)` so the FP-chain
/// walker can read frame records from it.
///
/// An Exception stream is always emitted because `CrashAnalyzer.analyze`
/// returns nil without one — and most of these tests are exercising the
/// analyzer pipeline. `exceptionAddress` defaults to `pc`.
private func makeARM64SyntheticDump(
    pc: UInt64,
    sp: UInt64,
    fp: UInt64,
    lr: UInt64 = 0,
    cpsr: UInt32 = 0,
    exceptionAddress: UInt64? = nil,
    moduleName: String = "arm.dll",
    moduleBase: UInt64 = 0x7FF0_0000_0000,
    moduleSize: UInt32 = 0x10_0000,
    stackBase: UInt64 = 0x0008_0000,
    stackSize: UInt32 = 0x1_0000,
    stackData: Data? = nil
) throws -> ParsedMinidump {
    precondition(stackData == nil || stackData!.count <= Int(stackSize),
                 "stackData must fit inside the declared stack region")
    let exAddr = exceptionAddress ?? pc

    let headerSize = 32
    let dirCount: UInt32 = 4
    let dirSize = Int(dirCount) * 12
    let exRva = UInt32(headerSize + dirSize)
    let threadRva = exRva + 168
    let moduleRva = threadRva + 4 + 48
    let moduleNameUtf16 = Array(moduleName.utf16)
    let moduleNameBytes = 4 + moduleNameUtf16.count * 2
    let moduleNameStart = moduleRva + 4 + 108
    let contextRva = moduleNameStart + UInt32(moduleNameBytes) + 4  // align
    let m64Rva = contextRva + UInt32(ARM64Context.size)
    let m64DataStart = m64Rva + 16 + 16  // header + 1 descriptor
    let totalSize = Int(m64DataStart) + Int(stackSize)

    var data = Data(repeating: 0, count: totalSize)

    // Header
    data.writeLEUInt32(0x504D444D, at: 0)             // MDMP
    data.writeLEUInt16(0xA793, at: 4)                 // version
    data.writeLEUInt32(dirCount, at: 8)
    data.writeLEUInt32(UInt32(headerSize), at: 12)
    data.writeLEUInt32(0, at: 16)
    data.writeLEUInt32(1700000000, at: 20)
    data.writeLEUInt64(0, at: 24)

    var dirOffset = headerSize
    // 0: Exception (stream 6)
    data.writeLEUInt32(6, at: dirOffset)
    data.writeLEUInt32(168, at: dirOffset + 4)
    data.writeLEUInt32(exRva, at: dirOffset + 8)
    dirOffset += 12
    // 1: ThreadList (stream 3)
    data.writeLEUInt32(3, at: dirOffset)
    data.writeLEUInt32(4 + 48, at: dirOffset + 4)
    data.writeLEUInt32(threadRva, at: dirOffset + 8)
    dirOffset += 12
    // 2: ModuleList (stream 4)
    data.writeLEUInt32(4, at: dirOffset)
    data.writeLEUInt32(4 + 108 + UInt32(moduleNameBytes), at: dirOffset + 4)
    data.writeLEUInt32(moduleRva, at: dirOffset + 8)
    dirOffset += 12
    // 3: Memory64List (stream 9)
    data.writeLEUInt32(9, at: dirOffset)
    data.writeLEUInt32(UInt32(16 + 16), at: dirOffset + 4)
    data.writeLEUInt32(m64Rva, at: dirOffset + 8)

    // Exception
    let exOff = Int(exRva)
    data.writeLEUInt32(1, at: exOff)                  // threadId = 1
    data.writeLEUInt32(0xC0000005, at: exOff + 8)     // ACCESS_VIOLATION
    data.writeLEUInt64(exAddr, at: exOff + 24)
    data.writeLEUInt32(2, at: exOff + 32)             // numberOfParameters
    data.writeLEUInt64(0, at: exOff + 40)             // param[0] = read
    data.writeLEUInt64(0xDEAD, at: exOff + 48)        // param[1] = target
    data.writeLEUInt32(UInt32(ARM64Context.size), at: exOff + 160)
    data.writeLEUInt32(contextRva, at: exOff + 164)

    // ThreadList — 1 thread, ARM64 context (dataSize=912)
    let threadOff = Int(threadRva)
    data.writeLEUInt32(1, at: threadOff)              // count
    data.writeLEUInt32(1, at: threadOff + 4)          // threadId
    data.writeLEUInt32(0, at: threadOff + 8)          // suspendCount
    data.writeLEUInt32(32, at: threadOff + 12)        // priorityClass
    data.writeLEUInt32(8, at: threadOff + 16)         // priority
    data.writeLEUInt64(0, at: threadOff + 20)         // teb
    data.writeLEUInt64(stackBase, at: threadOff + 28) // stack base
    data.writeLEUInt32(stackSize, at: threadOff + 36) // stack size
    data.writeLEUInt32(0, at: threadOff + 40)         // stack rva (memory64 covers it)
    data.writeLEUInt32(UInt32(ARM64Context.size), at: threadOff + 44)
    data.writeLEUInt32(contextRva, at: threadOff + 48)

    // CONTEXT_ARM64 — only the registers the test cares about.
    let ctxOff = Int(contextRva)
    data.writeLEUInt32(0, at: ctxOff)                 // contextFlags
    data.writeLEUInt32(cpsr, at: ctxOff + 4)
    // X29 = FP, X30 = LR
    data.writeLEUInt64(fp, at: ctxOff + 8 + 29 * 8)
    data.writeLEUInt64(lr, at: ctxOff + 8 + 30 * 8)
    data.writeLEUInt64(sp, at: ctxOff + 256)
    data.writeLEUInt64(pc, at: ctxOff + 264)

    // ModuleList
    let modOff = Int(moduleRva)
    data.writeLEUInt32(1, at: modOff)
    data.writeLEUInt64(moduleBase, at: modOff + 4)
    data.writeLEUInt32(moduleSize, at: modOff + 12)
    data.writeLEUInt32(0, at: modOff + 16)
    data.writeLEUInt32(1700000000, at: modOff + 20)
    data.writeLEUInt32(moduleNameStart, at: modOff + 24)

    let nameOff = Int(moduleNameStart)
    data.writeLEUInt32(UInt32(moduleNameUtf16.count * 2), at: nameOff)
    for (i, u) in moduleNameUtf16.enumerated() {
        data.writeLEUInt16(u, at: nameOff + 4 + i * 2)
    }

    // Memory64List
    let m64Off = Int(m64Rva)
    data.writeLEUInt64(1, at: m64Off)
    data.writeLEUInt64(UInt64(m64DataStart), at: m64Off + 8)
    data.writeLEUInt64(stackBase, at: m64Off + 16)
    data.writeLEUInt64(UInt64(stackSize), at: m64Off + 24)

    if let stackData {
        data.replaceSubrange(Int(m64DataStart)..<(Int(m64DataStart) + stackData.count),
                             with: stackData)
    }

    return try MinidumpParser.parse(data: data)
}

// MARK: - (a) End-to-end ARM64 parse through MinidumpParser

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

// MARK: - (b) walkAArch64FrameChain behavioral coverage

@Suite("CrashAnalyzer ARM64 frame-chain walker")
struct ARM64FrameChainTests {

    /// Build a stack image with two valid AAPCS64 frame records:
    ///   frame 0 at `fp0`:  [savedFP = fp1, savedLR = lr0]
    ///   frame 1 at `fp1`:  [savedFP = 0,   savedLR = lr1]
    /// Both savedLR values point into the module's range so
    /// `dump.moduleList?.module(containing:)` succeeds.
    @Test func twoDeepFrameChainProducesTwoReturnAddresses() throws {
        let stackBase: UInt64 = 0x0008_0000
        let stackSize: UInt32 = 0x1_0000
        let moduleBase: UInt64 = 0x7FF0_0000_0000
        let moduleSize: UInt32 = 0x10_0000

        // 16-byte-aligned FPs inside the stack range.
        let fp0Offset: Int = 0x0020
        let fp1Offset: Int = 0x0040
        let fp0 = stackBase + UInt64(fp0Offset)
        let fp1 = stackBase + UInt64(fp1Offset)
        let lr0 = moduleBase + 0x100  // return into module
        let lr1 = moduleBase + 0x200

        var stack = Data(repeating: 0, count: Int(stackSize))
        // Frame 0 record
        stack.writeLEUInt64(fp1, at: fp0Offset)
        stack.writeLEUInt64(lr0, at: fp0Offset + 8)
        // Frame 1 record (terminator: savedFP=0)
        stack.writeLEUInt64(0, at: fp1Offset)
        stack.writeLEUInt64(lr1, at: fp1Offset + 8)

        let dump = try makeARM64SyntheticDump(
            pc: moduleBase + 0x10,       // currently executing in module
            sp: stackBase + 0x10,
            fp: fp0,
            lr: 0,                       // exercise the FP chain, not the seed
            moduleBase: moduleBase,
            moduleSize: moduleSize,
            stackBase: stackBase,
            stackSize: stackSize,
            stackData: stack
        )

        let analysis = try #require(CrashAnalyzer(dump: dump).analyze())
        let addresses = analysis.stackFrames.map(\.address)

        #expect(addresses.contains(lr0),
                "first frame record's saved LR must surface as a stack frame")
        #expect(addresses.contains(lr1),
                "second frame record's saved LR must surface as a stack frame")
        // Ordering: lr0 should come before lr1 (innermost frame first).
        let idx0 = addresses.firstIndex(of: lr0)
        let idx1 = addresses.firstIndex(of: lr1)
        if let idx0, let idx1 {
            #expect(idx0 < idx1, "frame ordering reversed: walker is unwinding outward incorrectly")
        }
    }

    @Test func lrSeedsLeafFrameWhenChainIsEmpty() throws {
        let stackBase: UInt64 = 0x0008_0000
        let moduleBase: UInt64 = 0x7FF0_0000_0000
        let lr: UInt64 = moduleBase + 0x80

        let dump = try makeARM64SyntheticDump(
            pc: moduleBase + 0x10,
            sp: stackBase + 0x10,
            fp: 0,                       // no frame record to walk
            lr: lr,
            moduleBase: moduleBase
        )

        let analysis = try #require(CrashAnalyzer(dump: dump).analyze())
        #expect(analysis.stackFrames.map(\.address).contains(lr),
                "leaf-frame LR must seed the walk when FP is null")
    }

    @Test func misalignedFpProducesNoFrameChainFrames() throws {
        // FP = 0x0008_0008 — inside the stack but NOT 16-byte aligned.
        // AAPCS64 requires 16-byte alignment; the walker must skip it.
        let stackBase: UInt64 = 0x0008_0000
        let moduleBase: UInt64 = 0x7FF0_0000_0000
        let lr0 = moduleBase + 0x100

        var stack = Data(repeating: 0, count: 0x1_0000)
        // Plant what would be a valid record at the misaligned offset
        // so a buggy walker (no alignment check) would find it.
        stack.writeLEUInt64(0, at: 8)
        stack.writeLEUInt64(lr0, at: 16)

        let dump = try makeARM64SyntheticDump(
            pc: moduleBase + 0x10,
            sp: stackBase + 0x4,
            fp: stackBase + 8,           // misaligned
            lr: 0,
            moduleBase: moduleBase,
            stackBase: stackBase,
            stackData: stack
        )

        let analysis = try #require(CrashAnalyzer(dump: dump).analyze())
        // lr0 came in via the chain only — must NOT appear if alignment
        // check rejects misaligned FP. (Module-base IP and exception
        // address may still surface as IP-confidence frames.)
        let chainHits = analysis.stackFrames.filter { $0.address == lr0 }
        #expect(chainHits.isEmpty,
                "misaligned FP must not produce frame-chain frames")
    }

    @Test func fpOutsideStackRangeIsRejected() throws {
        let stackBase: UInt64 = 0x0008_0000
        let stackSize: UInt32 = 0x1_0000
        let moduleBase: UInt64 = 0x7FF0_0000_0000
        let lr0 = moduleBase + 0x100

        // FP points well above the captured stack range. A buggy walker
        // that skipped the range check would happily dereference it
        // (the dump-memory reader would simply return nil) — assert
        // we don't produce a frame from it.
        var stack = Data(repeating: 0, count: Int(stackSize))
        // Plant garbage that looks like a frame record, in case the
        // dump reader somehow synthesizes it.
        stack.writeLEUInt64(0, at: 0)
        stack.writeLEUInt64(lr0, at: 8)

        let dump = try makeARM64SyntheticDump(
            pc: moduleBase + 0x10,
            sp: stackBase + 0x4,
            fp: stackBase + UInt64(stackSize) + 0x1000,  // out of range
            lr: 0,
            moduleBase: moduleBase,
            stackBase: stackBase,
            stackSize: stackSize,
            stackData: stack
        )

        let analysis = try #require(CrashAnalyzer(dump: dump).analyze())
        let chainHits = analysis.stackFrames.filter { $0.address == lr0 }
        #expect(chainHits.isEmpty,
                "FP outside the captured stack range must not produce a frame")
    }
}

// MARK: - (c) Exporter output for ARM64 dumps

@Suite("Exporters render ARM64 dumps correctly")
struct ARM64ExporterTests {

    @Test func csvHeaderUsesARM64ColumnNamesForARM64Dump() throws {
        let dump = try makeARM64SyntheticDump(pc: 0xAA, sp: 0xBB, fp: 0xCC)
        let csv = CSVExporter.generateCSV(from: dump)

        // ARM64 column names appear.
        #expect(csv.contains("PC,SP,FP,X0,X1,X2,X3"),
                "ARM64 dump must surface PC/SP/FP/X0-X3 column header — got: \(csv.prefix(2000))")
        // x64-only register names are absent from the thread header row.
        #expect(!csv.contains("RIP,RSP,RBP,RAX"),
                "ARM64 dump must NOT print x64 column names in the thread section")
    }

    @Test func textReporterVerboseUsesARM64RegisterNames() throws {
        // Need a valid CONTEXT_AMD64-or-ARM64 with the FP-state flag set
        // for the verbose path; we just need the verbose section to render.
        let dump = try makeARM64SyntheticDump(pc: 0x1234, sp: 0x2222, fp: 0x3333)
        let report = TextReporter.generateReport(from: dump, analysis: nil, verbose: true)

        #expect(report.contains("PC=0x0000000000001234"),
                "verbose ARM64 report must print PC=, not RIP=")
        #expect(!report.contains("RIP="),
                "verbose ARM64 report must not print RIP=")
        #expect(report.contains("X0=") || report.contains("X1="),
                "verbose ARM64 report must include X-register row, not RAX/RBX")
        #expect(!report.contains("RAX="),
                "verbose ARM64 report must not include RAX=")
    }

    @Test func htmlExporterUsesCPSRNotRFLAGS() throws {
        let dump = try makeARM64SyntheticDump(pc: 0, sp: 0, fp: 0, cpsr: 0x4000_0000)  // Z flag
        let html = HTMLExporter.generateReport(from: dump, analysis: nil)

        // CPSR row appears, RFLAGS does not.
        #expect(html.contains("CPSR"),
                "ARM64 HTML report must include CPSR row")
        #expect(!html.contains("RFLAGS"),
                "ARM64 HTML report must not include x64 RFLAGS row")
    }
}

// MARK: - (d) Codable + Equatable round-trip

@Suite("ThreadContext Codable round-trip")
struct ThreadContextCodableTests {

    @Test func amd64ContextRoundTripsThroughJSON() throws {
        let original: ThreadContext = makeZeroContext()
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ThreadContext.self, from: encoded)
        #expect(decoded == original,
                "AMD64 ThreadContext must round-trip through JSONEncoder/Decoder")
    }

    @Test func arm64ContextRoundTripsThroughJSON() throws {
        let original: ThreadContext = makeZeroARM64Context()
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ThreadContext.self, from: encoded)
        #expect(decoded == original,
                "ARM64 ThreadContext must round-trip through JSONEncoder/Decoder")
    }

    @Test func amd64AndARM64AreNotEqualAcrossCases() {
        let amd: ThreadContext = makeZeroContext()
        let arm: ThreadContext = makeZeroARM64Context()
        #expect(amd != arm,
                "different enum cases must compare unequal even when zero-initialized")
    }
}
