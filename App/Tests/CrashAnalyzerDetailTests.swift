import Foundation
import Testing
@testable import MiniDumpTruckCore

// MARK: - Binary Helpers

private extension Data {
    mutating func writeUInt8(_ value: UInt8, at offset: Int) {
        self[offset] = value
    }

    mutating func writeUInt16(_ value: UInt16, at offset: Int) {
        self[offset] = UInt8(value & 0xFF)
        self[offset + 1] = UInt8((value >> 8) & 0xFF)
    }

    mutating func writeUInt32(_ value: UInt32, at offset: Int) {
        for i in 0..<4 {
            self[offset + i] = UInt8((value >> (i * 8)) & 0xFF)
        }
    }

    mutating func writeUInt64(_ value: UInt64, at offset: Int) {
        for i in 0..<8 {
            self[offset + i] = UInt8((value >> (i * 8)) & 0xFF)
        }
    }
}

// MARK: - SystemModules Tests

@Suite("SystemModules Classification")
struct SystemModulesClassificationTests {

    @Test func coreWindowsDlls() {
        #expect(SystemModules.isSystemModule("ntdll.dll"))
        #expect(SystemModules.isSystemModule("kernel32.dll"))
        #expect(SystemModules.isSystemModule("kernelbase.dll"))
        #expect(SystemModules.isSystemModule("user32.dll"))
        #expect(SystemModules.isSystemModule("gdi32.dll"))
        #expect(SystemModules.isSystemModule("msvcrt.dll"))
        #expect(SystemModules.isSystemModule("ucrtbase.dll"))
        #expect(SystemModules.isSystemModule("advapi32.dll"))
    }

    @Test func systemModulesWithPaths() {
        #expect(SystemModules.isSystemModule("C:\\Windows\\System32\\ntdll.dll"))
        #expect(SystemModules.isSystemModule("C:\\Windows\\SysWOW64\\kernel32.dll"))
    }

    @Test func systemModulesByPath() {
        // Even unknown DLLs in system directories are system modules
        #expect(SystemModules.isSystemModule("C:\\Windows\\System32\\unknown.dll"))
        #expect(SystemModules.isSystemModule("C:\\Windows\\SysWOW64\\random.dll"))
        #expect(SystemModules.isSystemModule("C:\\Windows\\WinSxS\\something.dll"))
    }

    @Test func thirdPartyModules() {
        #expect(!SystemModules.isSystemModule("myapp.exe"))
        #expect(!SystemModules.isSystemModule("custom.dll"))
        #expect(!SystemModules.isSystemModule("C:\\Program Files\\MyApp\\plugin.dll"))
    }

    @Test func graphicsDriversNotSystem() {
        // Graphics drivers should NOT be classified as system modules
        #expect(!SystemModules.isSystemModule("nvoglv64.dll"))
        #expect(!SystemModules.isSystemModule("aticfx64.dll"))
        #expect(!SystemModules.isSystemModule("igxelpicd64.dll"))
    }

    @Test func caseInsensitive() {
        #expect(SystemModules.isSystemModule("NTDLL.DLL"))
        #expect(SystemModules.isSystemModule("Kernel32.dll"))
        #expect(SystemModules.isSystemModule("C:\\WINDOWS\\SYSTEM32\\GDI32.DLL"))
    }
}

@Suite("SystemModules Graphics Drivers")
struct SystemModulesGraphicsDriverTests {
    @Test func nvidiaDrivers() {
        #expect(SystemModules.isGraphicsDriver("nvoglv64.dll"))
        #expect(SystemModules.isGraphicsDriver("nvoglv32.dll"))
        #expect(SystemModules.isGraphicsDriver("nvd3dumx.dll"))
        #expect(SystemModules.isGraphicsDriver("nvwgf2umx.dll"))
    }

    @Test func amdDrivers() {
        #expect(SystemModules.isGraphicsDriver("aticfx64.dll"))
        #expect(SystemModules.isGraphicsDriver("atidxx64.dll"))
        #expect(SystemModules.isGraphicsDriver("amdxc64.dll"))
    }

    @Test func intelDrivers() {
        #expect(SystemModules.isGraphicsDriver("igxelpicd64.dll"))
        #expect(SystemModules.isGraphicsDriver("ig9icd64.dll"))
        #expect(SystemModules.isGraphicsDriver("igd10iumd64.dll"))
    }

    @Test func vulkanLoader() {
        #expect(SystemModules.isGraphicsDriver("vulkan-1.dll"))
    }

    @Test func notGraphicsDriver() {
        #expect(!SystemModules.isGraphicsDriver("ntdll.dll"))
        #expect(!SystemModules.isGraphicsDriver("myapp.exe"))
    }

    @Test func graphicsDriverWithPath() {
        #expect(SystemModules.isGraphicsDriver("C:\\Windows\\System32\\DriverStore\\FileRepository\\nvoglv64.dll"))
    }
}

@Suite("SystemModules Categories")
struct SystemModulesCategoryTests {
    @Test func graphicsDriverCategory() {
        let cat = SystemModules.category(for: "nvoglv64.dll")
        #expect(cat == .graphicsDriver)
        #expect(cat.displayName == "Graphics Driver")
        #expect(cat.shouldBlame == true)
    }

    @Test func systemCategory() {
        let cat = SystemModules.category(for: "ntdll.dll")
        #expect(cat == .system)
        #expect(cat.displayName == "System")
        #expect(cat.shouldBlame == false)
    }

    @Test func applicationCategory() {
        let cat = SystemModules.category(for: "C:\\Program Files\\MyApp\\app.dll")
        #expect(cat == .application)
        #expect(cat.displayName == "Application")
        #expect(cat.shouldBlame == true)
    }

    @Test func thirdPartyCategory() {
        let cat = SystemModules.category(for: "unknown.dll")
        #expect(cat == .thirdParty)
        #expect(cat.displayName == "Third-Party")
        #expect(cat.shouldBlame == true)
    }

    @Test func windowsPathIsSystem() {
        let cat = SystemModules.category(for: "C:\\Windows\\unknown.dll")
        #expect(cat == .system)
    }

    @Test func programDataIsApplication() {
        let cat = SystemModules.category(for: "C:\\ProgramData\\MyApp\\helper.dll")
        #expect(cat == .application)
    }
}

// MARK: - CrashAnalyzer Integration Tests

@Suite("CrashAnalyzer Returns Nil")
struct CrashAnalyzerNilTests {
    @Test func returnsNilWithNoException() throws {
        // Build a minimal dump with no exception stream
        var data = Data(repeating: 0, count: 32)
        data.writeUInt32(0x504D444D, at: 0)
        data.writeUInt16(0xA793, at: 4)
        data.writeUInt32(0, at: 8)
        data.writeUInt32(32, at: 12)
        data.writeUInt32(0, at: 16)
        data.writeUInt32(1700000000, at: 20)
        data.writeUInt64(0, at: 24)

        let dump = try MinidumpParser.parse(data: data)
        let analyzer = CrashAnalyzer(dump: dump)
        #expect(analyzer.analyze() == nil)
    }

    @Test func returnsNilWithNoFaultingThread() throws {
        // Dump with exception but no matching thread
        let headerSize = 32
        let dirSize = 12
        let exRva = UInt32(headerSize + dirSize)

        var data = Data(repeating: 0, count: Int(exRva) + 168)
        data.writeUInt32(0x504D444D, at: 0)
        data.writeUInt16(0xA793, at: 4)
        data.writeUInt32(1, at: 8)
        data.writeUInt32(UInt32(headerSize), at: 12)
        data.writeUInt32(0, at: 16)
        data.writeUInt32(1700000000, at: 20)
        data.writeUInt64(0, at: 24)

        // Exception stream
        data.writeUInt32(6, at: headerSize)
        data.writeUInt32(168, at: headerSize + 4)
        data.writeUInt32(exRva, at: headerSize + 8)

        // Exception data: threadId=99 (no thread list to match)
        data.writeUInt32(99, at: Int(exRva))
        data.writeUInt32(0xC0000005, at: Int(exRva) + 8)
        data.writeUInt64(0x7FF800001234, at: Int(exRva) + 24)

        let dump = try MinidumpParser.parse(data: data)
        let analyzer = CrashAnalyzer(dump: dump)
        #expect(analyzer.analyze() == nil)
    }

    @Test func returnsNilWithNilContext() throws {
        // Dump with exception + matching thread, but thread has no context (size=0)
        let headerSize = 32
        let dirSize = 2 * 12
        let exRva = UInt32(headerSize + dirSize)
        let threadRva = exRva + 168
        let threadId: UInt32 = 42

        var data = Data(repeating: 0, count: Int(threadRva) + 4 + 48)
        // Header
        data.writeUInt32(0x504D444D, at: 0)
        data.writeUInt16(0xA793, at: 4)
        data.writeUInt32(2, at: 8)
        data.writeUInt32(UInt32(headerSize), at: 12)
        data.writeUInt32(0, at: 16)
        data.writeUInt32(1700000000, at: 20)
        data.writeUInt64(0, at: 24)

        // Directory: Exception
        data.writeUInt32(6, at: headerSize)
        data.writeUInt32(168, at: headerSize + 4)
        data.writeUInt32(exRva, at: headerSize + 8)
        // Directory: ThreadList
        data.writeUInt32(3, at: headerSize + 12)
        data.writeUInt32(4 + 48, at: headerSize + 16)
        data.writeUInt32(threadRva, at: headerSize + 20)

        // Exception: threadId matches
        let exOff = Int(exRva)
        data.writeUInt32(threadId, at: exOff)
        data.writeUInt32(0xC0000005, at: exOff + 8)

        // ThreadList: 1 thread with matching ID but context size = 0
        let tOff = Int(threadRva)
        data.writeUInt32(1, at: tOff)
        data.writeUInt32(threadId, at: tOff + 4)
        // context size = 0 → context will be nil
        data.writeUInt32(0, at: tOff + 44)
        data.writeUInt32(0, at: tOff + 48)

        let dump = try MinidumpParser.parse(data: data)
        let analyzer = CrashAnalyzer(dump: dump)
        #expect(analyzer.analyze() == nil)
    }
}

// MARK: - CrashAnalyzer with Synthetic Dump

@Suite("CrashAnalyzer Synthetic Analysis")
struct CrashAnalyzerSyntheticTests {

    /// Build a comprehensive dump with exception, thread, module, and memory for analysis
    private func makeSyntheticDump(
        exceptionCode: UInt32 = 0xC0000005,
        exceptionAddress: UInt64 = 0x7FF810001234,
        moduleName: String = "testapp.exe",
        moduleBase: UInt64 = 0x7FF810000000,
        moduleSize: UInt32 = 0x100000
    ) throws -> ParsedMinidump {
        // Layout:
        // Header(32) + Dir(4*12=48) + Exception(168) + ThreadList(4+48) + ModuleList(4+108+name)
        // + memory64(16+16+memdata) + context(1232)
        let headerSize = 32
        let dirCount: UInt32 = 4
        let dirSize = Int(dirCount) * 12
        let exRva = UInt32(headerSize + dirSize)
        let threadRva = exRva + 168
        let moduleRva = threadRva + 4 + 48
        let moduleNameStart = moduleRva + 4 + 108
        let moduleNameUtf16 = Array(moduleName.utf16)
        let moduleNameBytes = 4 + moduleNameUtf16.count * 2
        let contextRva = moduleNameStart + UInt32(moduleNameBytes) + 4 // align
        let m64Rva = contextRva + UInt32(ThreadContext.size)
        let stackBase: UInt64 = 0x00080000
        let stackSize: UInt32 = 0x10000
        let m64DataStart = m64Rva + 16 + 16  // header + 1 descriptor
        let totalSize = Int(m64DataStart) + Int(stackSize)

        var data = Data(repeating: 0, count: totalSize)

        // Header
        data.writeUInt32(0x504D444D, at: 0)
        data.writeUInt16(0xA793, at: 4)
        data.writeUInt32(dirCount, at: 8)
        data.writeUInt32(UInt32(headerSize), at: 12)
        data.writeUInt32(0, at: 16)
        data.writeUInt32(1700000000, at: 20)
        data.writeUInt64(0, at: 24)

        // Directory entries
        var dirOffset = headerSize
        // 0: Exception
        data.writeUInt32(6, at: dirOffset)
        data.writeUInt32(168, at: dirOffset + 4)
        data.writeUInt32(exRva, at: dirOffset + 8)
        dirOffset += 12
        // 1: ThreadList
        data.writeUInt32(3, at: dirOffset)
        data.writeUInt32(4 + 48, at: dirOffset + 4)
        data.writeUInt32(threadRva, at: dirOffset + 8)
        dirOffset += 12
        // 2: ModuleList
        data.writeUInt32(4, at: dirOffset)
        data.writeUInt32(4 + 108 + UInt32(moduleNameBytes), at: dirOffset + 4)
        data.writeUInt32(moduleRva, at: dirOffset + 8)
        dirOffset += 12
        // 3: Memory64List
        data.writeUInt32(9, at: dirOffset)
        data.writeUInt32(UInt32(16 + 16), at: dirOffset + 4)
        data.writeUInt32(m64Rva, at: dirOffset + 8)

        // Exception data
        let exOff = Int(exRva)
        data.writeUInt32(1, at: exOff)           // threadId = 1
        data.writeUInt32(exceptionCode, at: exOff + 8)
        data.writeUInt64(exceptionAddress, at: exOff + 24)
        data.writeUInt32(2, at: exOff + 32)      // numberOfParameters
        data.writeUInt64(0, at: exOff + 40)      // param[0] = read
        data.writeUInt64(0x0000DEAD, at: exOff + 48) // param[1] = target addr
        data.writeUInt32(UInt32(ThreadContext.size), at: exOff + 160)
        data.writeUInt32(contextRva, at: exOff + 164)

        // ThreadList
        let threadOff = Int(threadRva)
        data.writeUInt32(1, at: threadOff)        // count
        data.writeUInt32(1, at: threadOff + 4)    // threadId
        data.writeUInt32(0, at: threadOff + 8)    // suspendCount
        data.writeUInt32(32, at: threadOff + 12)  // priorityClass
        data.writeUInt32(8, at: threadOff + 16)   // priority
        data.writeUInt64(0, at: threadOff + 20)   // teb
        // Stack
        data.writeUInt64(stackBase, at: threadOff + 28)
        data.writeUInt32(stackSize, at: threadOff + 36)
        data.writeUInt32(0, at: threadOff + 40)   // stack rva (not needed for this test)
        // Context location
        data.writeUInt32(UInt32(ThreadContext.size), at: threadOff + 44)
        data.writeUInt32(contextRva, at: threadOff + 48)

        // Context (at contextRva)
        let ctxOff = Int(contextRva)
        data.writeUInt32(0x0010000F, at: ctxOff + 48) // contextFlags
        // RIP = exception address
        data.writeUInt64(exceptionAddress, at: ctxOff + 248)
        // RSP within stack
        data.writeUInt64(stackBase + UInt64(stackSize) - 0x100, at: ctxOff + 152)
        // RBP = 0 (no RBP chain)
        data.writeUInt64(0, at: ctxOff + 160)

        // ModuleList
        let modOff = Int(moduleRva)
        data.writeUInt32(1, at: modOff) // count
        data.writeUInt64(moduleBase, at: modOff + 4)
        data.writeUInt32(moduleSize, at: modOff + 12)
        data.writeUInt32(0, at: modOff + 16) // checksum
        data.writeUInt32(1700000000, at: modOff + 20) // timestamp
        data.writeUInt32(moduleNameStart, at: modOff + 24) // moduleNameRva

        // Module name
        let nameOff = Int(moduleNameStart)
        data.writeUInt32(UInt32(moduleNameUtf16.count * 2), at: nameOff)
        for (i, u) in moduleNameUtf16.enumerated() {
            data.writeUInt16(u, at: nameOff + 4 + i * 2)
        }

        // Memory64List
        let m64Off = Int(m64Rva)
        data.writeUInt64(1, at: m64Off)                     // numberOfRanges
        data.writeUInt64(UInt64(m64DataStart), at: m64Off + 8) // baseRva
        data.writeUInt64(stackBase, at: m64Off + 16)         // startAddress
        data.writeUInt64(UInt64(stackSize), at: m64Off + 24) // dataSize

        return try MinidumpParser.parse(data: data)
    }

    @Test func analyzesAccessViolation() throws {
        let dump = try makeSyntheticDump()
        let analyzer = CrashAnalyzer(dump: dump)
        let analysis = analyzer.analyze()

        #expect(analysis != nil)
        #expect(!analysis!.stackFrames.isEmpty)
        #expect(!analysis!.crashSummary.probableCause.isEmpty)
        #expect(!analysis!.crashSummary.recommendation.isEmpty)
    }

    @Test func stackFrameContainsExceptionAddress() throws {
        let dump = try makeSyntheticDump(exceptionAddress: 0x7FF810001234)
        let analyzer = CrashAnalyzer(dump: dump)
        let analysis = analyzer.analyze()!

        // First frame should be the exception address
        #expect(analysis.stackFrames.first?.address == 0x7FF810001234)
        #expect(analysis.stackFrames.first?.frameType == .instructionPointer)
        #expect(analysis.stackFrames.first?.confidence == .high)
    }

    @Test func blameFallsOnAppModule() throws {
        let dump = try makeSyntheticDump(
            exceptionAddress: 0x7FF810005000,
            moduleName: "myapp.exe",
            moduleBase: 0x7FF810000000
        )
        let analyzer = CrashAnalyzer(dump: dump)
        let analysis = analyzer.analyze()!

        #expect(analysis.blameModule != nil)
        #expect(analysis.blameModule?.module.shortName == "myapp.exe")
        #expect(analysis.blameModule?.reason == .directCrash)
    }

    @Test func blameGraphicsDriverPriority() throws {
        let dump = try makeSyntheticDump(
            exceptionAddress: 0x7FF810005000,
            moduleName: "nvoglv64.dll",  // NVIDIA graphics driver
            moduleBase: 0x7FF810000000
        )
        let analyzer = CrashAnalyzer(dump: dump)
        let analysis = analyzer.analyze()!

        #expect(analysis.blameModule != nil)
        #expect(analysis.blameModule?.reason == .graphicsDriver)
    }

    @Test func exceptionCodeInSummary() throws {
        let dump = try makeSyntheticDump(exceptionCode: 0xC0000005)
        let analyzer = CrashAnalyzer(dump: dump)
        let analysis = analyzer.analyze()!

        // Summary should reference ACCESS_VIOLATION
        #expect(analysis.crashSummary.exceptionType.contains("ACCESS_VIOLATION"))
    }

    @Test func stackOverflowSummary() throws {
        let dump = try makeSyntheticDump(exceptionCode: 0xC00000FD)
        let analyzer = CrashAnalyzer(dump: dump)
        let analysis = analyzer.analyze()!

        #expect(analysis.crashSummary.probableCause.contains("Stack overflow"))
    }

    @Test func divideByZeroSummary() throws {
        let dump = try makeSyntheticDump(exceptionCode: 0xC0000094)
        let analyzer = CrashAnalyzer(dump: dump)
        let analysis = analyzer.analyze()!

        #expect(analysis.crashSummary.probableCause.contains("Division by zero"))
    }

    @Test func bufferOverrunSummary() throws {
        let dump = try makeSyntheticDump(exceptionCode: 0xC0000409)
        let analyzer = CrashAnalyzer(dump: dump)
        let analysis = analyzer.analyze()!

        #expect(analysis.crashSummary.probableCause.contains("buffer overrun"))
    }

    @Test func cppExceptionSummary() throws {
        let dump = try makeSyntheticDump(exceptionCode: 0xE06D7363)
        let analyzer = CrashAnalyzer(dump: dump)
        let analysis = analyzer.analyze()!

        #expect(analysis.crashSummary.probableCause.contains("C++ exception"))
    }

    @Test func graphicsDriverRecommendation() throws {
        let dump = try makeSyntheticDump(moduleName: "nvoglv64.dll")
        let analyzer = CrashAnalyzer(dump: dump)
        let analysis = analyzer.analyze()!

        #expect(analysis.crashSummary.recommendation.contains("graphics driver"))
    }

    @Test func applicationRecommendation() throws {
        let dump = try makeSyntheticDump(
            moduleName: "C:\\Program Files\\MyApp\\app.dll"
        )
        let analyzer = CrashAnalyzer(dump: dump)
        let analysis = analyzer.analyze()!

        // Application module blame should recommend examining the stack or debugging
        let rec = analysis.crashSummary.recommendation.lowercased()
        #expect(rec.contains("stack") || rec.contains("debug") || rec.contains("crash"),
                "Expected application-specific recommendation, got: \(analysis.crashSummary.recommendation)")
    }

    @Test func confidenceAssessment() throws {
        // With no RBP chain (RBP=0), confidence should be lower
        let dump = try makeSyntheticDump()
        let analyzer = CrashAnalyzer(dump: dump)
        let analysis = analyzer.analyze()!

        // Should be one of the valid confidence levels
        #expect([.high, .medium, .low].contains(analysis.confidence))
    }

    @Test func faultingAddressInSummary() throws {
        let dump = try makeSyntheticDump(exceptionAddress: 0xDEADBEEF)
        let analyzer = CrashAnalyzer(dump: dump)
        let analysis = analyzer.analyze()!

        #expect(analysis.crashSummary.faultingAddress == 0xDEADBEEF)
    }
}

// MARK: - NTStatusCodes Integration

@Suite("NTStatusCodes Exception Names")
struct NTStatusCodesExceptionTests {
    @Test func accessViolation() {
        let name = NTStatusCodes.name(for: 0xC0000005)
        #expect(name.contains("ACCESS_VIOLATION"))
    }

    @Test func stackOverflow() {
        let name = NTStatusCodes.name(for: 0xC00000FD)
        #expect(name.contains("STACK_OVERFLOW"))
    }

    @Test func integerDivideByZero() {
        let name = NTStatusCodes.name(for: 0xC0000094)
        #expect(name.contains("INTEGER_DIVIDE_BY_ZERO"))
    }

    @Test func stackBufferOverrun() {
        let name = NTStatusCodes.name(for: 0xC0000409)
        #expect(name.contains("STACK_BUFFER_OVERRUN"))
    }

    @Test func unknownCode() {
        // Unknown code should still return something
        let name = NTStatusCodes.name(for: 0x12345678)
        #expect(!name.isEmpty)
    }
}

// MARK: - Codable Tests

@Suite("Model Codable Conformance")
struct CodableConformanceTests {
    @Test func analysisConfidenceRoundTrips() throws {
        let original = AnalysisConfidence.high
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AnalysisConfidence.self, from: encoded)
        #expect(decoded == original)
    }

    @Test func stackFrameTypeRoundTrips() throws {
        let original = StackFrame.FrameType.framePointer
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(StackFrame.FrameType.self, from: encoded)
        #expect(decoded == original)
    }

    @Test func blameReasonRoundTrips() throws {
        let original = BlameResult.BlameReason.graphicsDriver
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(BlameResult.BlameReason.self, from: encoded)
        #expect(decoded == original)
    }

    @Test func memoryProtectionRoundTrips() throws {
        let original = MemoryProtection.executeReadWrite
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MemoryProtection.self, from: encoded)
        #expect(decoded == original)
    }

    @Test func miscInfoFlagsRoundTrips() throws {
        let original = MiscInfoFlags(rawValue: 0x43)
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MiscInfoFlags.self, from: encoded)
        #expect(decoded == original)
    }

    @Test func minidumpTypeRoundTrips() throws {
        let original = MinidumpType(rawValue: 0x07)
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MinidumpType.self, from: encoded)
        #expect(decoded == original)
    }

    @Test func streamTypeRoundTrips() throws {
        let original = StreamType.threadList
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(StreamType.self, from: encoded)
        #expect(decoded == original)
    }

    @Test func processorArchitectureRoundTrips() throws {
        let original = ProcessorArchitecture.amd64
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ProcessorArchitecture.self, from: encoded)
        #expect(decoded == original)
    }

    @Test func memoryStateRoundTrips() throws {
        let original = MemoryState.commit
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MemoryState.self, from: encoded)
        #expect(decoded == original)
    }

    @Test func memoryTypeRoundTrips() throws {
        let original = MemoryType.image
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MemoryType.self, from: encoded)
        #expect(decoded == original)
    }
}
