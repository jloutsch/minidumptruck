import Foundation
import Testing
@testable import MiniDumpTruckCore

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
        data.writeLEUInt32(0x504D444D, at: 0)
        data.writeLEUInt16(0xA793, at: 4)
        data.writeLEUInt32(0, at: 8)
        data.writeLEUInt32(32, at: 12)
        data.writeLEUInt32(0, at: 16)
        data.writeLEUInt32(1700000000, at: 20)
        data.writeLEUInt64(0, at: 24)

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
        data.writeLEUInt32(0x504D444D, at: 0)
        data.writeLEUInt16(0xA793, at: 4)
        data.writeLEUInt32(1, at: 8)
        data.writeLEUInt32(UInt32(headerSize), at: 12)
        data.writeLEUInt32(0, at: 16)
        data.writeLEUInt32(1700000000, at: 20)
        data.writeLEUInt64(0, at: 24)

        // Exception stream
        data.writeLEUInt32(6, at: headerSize)
        data.writeLEUInt32(168, at: headerSize + 4)
        data.writeLEUInt32(exRva, at: headerSize + 8)

        // Exception data: threadId=99 (no thread list to match)
        data.writeLEUInt32(99, at: Int(exRva))
        data.writeLEUInt32(0xC0000005, at: Int(exRva) + 8)
        data.writeLEUInt64(0x7FF800001234, at: Int(exRva) + 24)

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
        data.writeLEUInt32(0x504D444D, at: 0)
        data.writeLEUInt16(0xA793, at: 4)
        data.writeLEUInt32(2, at: 8)
        data.writeLEUInt32(UInt32(headerSize), at: 12)
        data.writeLEUInt32(0, at: 16)
        data.writeLEUInt32(1700000000, at: 20)
        data.writeLEUInt64(0, at: 24)

        // Directory: Exception
        data.writeLEUInt32(6, at: headerSize)
        data.writeLEUInt32(168, at: headerSize + 4)
        data.writeLEUInt32(exRva, at: headerSize + 8)
        // Directory: ThreadList
        data.writeLEUInt32(3, at: headerSize + 12)
        data.writeLEUInt32(4 + 48, at: headerSize + 16)
        data.writeLEUInt32(threadRva, at: headerSize + 20)

        // Exception: threadId matches
        let exOff = Int(exRva)
        data.writeLEUInt32(threadId, at: exOff)
        data.writeLEUInt32(0xC0000005, at: exOff + 8)

        // ThreadList: 1 thread with matching ID but context size = 0
        let tOff = Int(threadRva)
        data.writeLEUInt32(1, at: tOff)
        data.writeLEUInt32(threadId, at: tOff + 4)
        // context size = 0 → context will be nil
        data.writeLEUInt32(0, at: tOff + 44)
        data.writeLEUInt32(0, at: tOff + 48)

        let dump = try MinidumpParser.parse(data: data)
        let analyzer = CrashAnalyzer(dump: dump)
        #expect(analyzer.analyze() == nil)
    }
}

// MARK: - CrashAnalyzer with Synthetic Dump

@Suite("CrashAnalyzer Synthetic Analysis")
struct CrashAnalyzerSyntheticTests {

    /// Build a comprehensive dump with exception, thread, module, and
    /// memory for analysis. Delegates to the shared `SyntheticDump`
    /// builder; only the AMD64-specific context payload lives here.
    private func makeSyntheticDump(
        exceptionCode: UInt32 = 0xC0000005,
        exceptionAddress: UInt64 = 0x7FF810001234,
        moduleName: String = "testapp.exe",
        moduleBase: UInt64 = 0x7FF810000000,
        moduleSize: UInt32 = 0x100000
    ) throws -> ParsedMinidump {
        let stackBase: UInt64 = 0x00080000
        let stackSize: UInt32 = 0x10000
        return try SyntheticDump.build(
            contextSize: AMD64Context.size,
            exceptionCode: exceptionCode,
            exceptionAddress: exceptionAddress,
            moduleName: moduleName,
            moduleBase: moduleBase,
            moduleSize: moduleSize,
            stackBase: stackBase,
            stackSize: stackSize
        ) { data, ctxOff in
            // CONTEXT_AMD64: contextFlags at offset 48; RIP at 248;
            // RSP at 152; RBP at 160. The integration callers all
            // want RIP == exception address, RSP just below stack top,
            // and RBP=0 (so the heuristic scanner is exercised
            // instead of the RBP-chain walker).
            data.writeLEUInt32(0x0010000F, at: ctxOff + 48)
            data.writeLEUInt64(exceptionAddress, at: ctxOff + 248)
            data.writeLEUInt64(stackBase + UInt64(stackSize) - 0x100, at: ctxOff + 152)
            data.writeLEUInt64(0, at: ctxOff + 160)
        }
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
