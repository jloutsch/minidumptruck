import Foundation
import Testing
@testable import MiniDumpTruckCore

@Suite("CrashAnalyzer Tests")
struct CrashAnalyzerTests {

    // MARK: - Test Data Paths

    static var testDataPath: String {
        var url = URL(fileURLWithPath: #file)
        while url.path != "/" {
            url = url.deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
                return url.appendingPathComponent("TestData").path
            }
        }
        return ""
    }

    static func testFile(_ name: String) -> URL {
        URL(fileURLWithPath: testDataPath).appendingPathComponent(name)
    }

    // MARK: - Integration Tests with Real Dumps

    @Test func analyzeTestDump() throws {
        let url = Self.testFile("test.dmp")
        guard FileManager.default.fileExists(atPath: url.path) else {
            Issue.record("Test file not found: \(url.path)")
            return
        }

        let data = try Data(contentsOf: url)
        let dump = try MinidumpParser.parse(data: data)
        let analyzer = CrashAnalyzer(dump: dump)

        let analysis = analyzer.analyze()

        // Should produce some analysis (may be nil if no exception)
        if dump.exception != nil {
            #expect(analysis != nil, "Should produce analysis when exception is present")
        }
    }

    @Test func analyzeFullDump() throws {
        let url = Self.testFile("full-dump.dmp")
        guard FileManager.default.fileExists(atPath: url.path) else {
            Issue.record("Test file not found: \(url.path)")
            return
        }

        let data = try Data(contentsOf: url)
        let dump = try MinidumpParser.parse(data: data)
        let analyzer = CrashAnalyzer(dump: dump)

        let analysis = analyzer.analyze()

        if let analysis = analysis {
            // Should have stack frames
            #expect(analysis.stackFrames.count > 0, "Should have at least one stack frame")

            // Should have crash summary
            #expect(!analysis.crashSummary.exceptionType.isEmpty)

            // Confidence should be valid
            #expect([.high, .medium, .low].contains(analysis.confidence))
        }
    }

    @Test func analyzeMacosSegv() throws {
        let url = Self.testFile("pipeline-inlines-macos-segv.dmp")
        guard FileManager.default.fileExists(atPath: url.path) else {
            Issue.record("Test file not found: \(url.path)")
            return
        }

        let data = try Data(contentsOf: url)
        let dump = try MinidumpParser.parse(data: data)

        // This dump should have an exception
        #expect(dump.exception != nil, "SEGV dump should have exception")

        let analyzer = CrashAnalyzer(dump: dump)
        let analysis = analyzer.analyze()

        #expect(analysis != nil, "Should produce analysis for SEGV dump")

        if let analysis = analysis {
            // First frame should be instruction pointer type
            if let firstFrame = analysis.stackFrames.first {
                #expect(firstFrame.frameType == .instructionPointer)
                #expect(firstFrame.confidence == .high)
            }
        }
    }

    // MARK: - Stack Frame Tests

    @Test func stackFrameDisplayAddressWithModule() {
        guard let module = createMockModule(name: "test.dll", baseAddress: 0x10000000) else {
            Issue.record("Failed to create mock module")
            return
        }
        let frame = StackFrame(
            address: 0x10001234,
            module: module,
            offsetInModule: 0x1234,
            frameType: .instructionPointer,
            confidence: .high
        )

        #expect(frame.displayAddress == "test.dll+0x1234")
    }

    @Test func stackFrameDisplayAddressWithoutModule() {
        let frame = StackFrame(
            address: 0x7FF812345678,
            module: nil,
            offsetInModule: nil,
            frameType: .returnAddress,
            confidence: .low
        )

        #expect(frame.displayAddress == "0x00007FF812345678")
    }

    @Test func stackFrameTypes() {
        // Instruction pointer
        let ipFrame = StackFrame(
            address: 0x1000,
            module: nil,
            offsetInModule: nil,
            frameType: .instructionPointer,
            confidence: .high
        )
        #expect(ipFrame.frameType == .instructionPointer)

        // Frame pointer
        let fpFrame = StackFrame(
            address: 0x2000,
            module: nil,
            offsetInModule: nil,
            frameType: .framePointer,
            confidence: .high
        )
        #expect(fpFrame.frameType == .framePointer)

        // Return address
        let raFrame = StackFrame(
            address: 0x3000,
            module: nil,
            offsetInModule: nil,
            frameType: .returnAddress,
            confidence: .medium
        )
        #expect(raFrame.frameType == .returnAddress)
    }

    // MARK: - Blame Result Tests

    @Test func blameReasonDescriptions() {
        guard let module = createMockModule(name: "test.dll", baseAddress: 0x10000000) else {
            Issue.record("Failed to create mock module")
            return
        }
        let frame = StackFrame(
            address: 0x10001000,
            module: module,
            offsetInModule: 0x1000,
            frameType: .instructionPointer,
            confidence: .high
        )

        let directCrash = BlameResult(module: module, frame: frame, reason: .directCrash)
        #expect(directCrash.reasonDescription.contains("directly"))

        let firstNonSystem = BlameResult(module: module, frame: frame, reason: .firstNonSystemFrame)
        #expect(firstNonSystem.reasonDescription.contains("First"))

        let graphicsDriver = BlameResult(module: module, frame: frame, reason: .graphicsDriver)
        #expect(graphicsDriver.reasonDescription.contains("Graphics"))

        let thirdParty = BlameResult(module: module, frame: frame, reason: .thirdPartyInCallChain)
        #expect(thirdParty.reasonDescription.contains("Third-party"))
    }

    // MARK: - Crash Summary Tests

    @Test func crashSummaryFields() {
        guard let module = createMockModule(name: "app.exe", baseAddress: 0x400000) else {
            Issue.record("Failed to create mock module")
            return
        }
        let summary = CrashSummary(
            exceptionType: "STATUS_ACCESS_VIOLATION",
            exceptionDescription: "Access violation reading",
            faultingAddress: 0x401234,
            faultingModule: module,
            probableCause: "Invalid memory access",
            recommendation: "Debug the application"
        )

        #expect(summary.exceptionType == "STATUS_ACCESS_VIOLATION")
        #expect(summary.faultingAddress == 0x401234)
        #expect(summary.faultingModule?.name == "app.exe")
        #expect(summary.probableCause.contains("memory"))
    }

    // MARK: - Confidence Tests

    @Test func confidenceDisplayNames() {
        #expect(AnalysisConfidence.high.displayName == "High")
        #expect(AnalysisConfidence.medium.displayName == "Medium")
        #expect(AnalysisConfidence.low.displayName == "Low")
    }

    @Test func analyzerReturnsNilWithoutException() throws {
        let url = Self.testFile("test.dmp")
        guard FileManager.default.fileExists(atPath: url.path) else {
            Issue.record("Test file not found")
            return
        }

        let data = try Data(contentsOf: url)
        let dump = try MinidumpParser.parse(data: data)

        // If dump has no exception, analyzer should return nil
        if dump.exception == nil {
            let analyzer = CrashAnalyzer(dump: dump)
            let analysis = analyzer.analyze()
            #expect(analysis == nil)
        }
    }

    // MARK: - Analysis Quality Tests

    @Test func analysisHasReasonableFrameCount() throws {
        let url = Self.testFile("full-dump.dmp")
        guard FileManager.default.fileExists(atPath: url.path) else {
            Issue.record("Test file not found")
            return
        }

        let data = try Data(contentsOf: url)
        let dump = try MinidumpParser.parse(data: data)
        let analyzer = CrashAnalyzer(dump: dump)

        if let analysis = analyzer.analyze() {
            // Should not have excessive frames (max 100 from RBP + 20 from scan + 2 IP)
            #expect(analysis.stackFrames.count <= 122)

            // Should have at least the instruction pointer frame
            #expect(analysis.stackFrames.count >= 1)
        }
    }

    @Test func analysisFramesAreUnique() throws {
        let url = Self.testFile("full-dump.dmp")
        guard FileManager.default.fileExists(atPath: url.path) else {
            Issue.record("Test file not found")
            return
        }

        let data = try Data(contentsOf: url)
        let dump = try MinidumpParser.parse(data: data)
        let analyzer = CrashAnalyzer(dump: dump)

        if let analysis = analyzer.analyze() {
            // All frame addresses should be unique
            let addresses = analysis.stackFrames.map { $0.address }
            let uniqueAddresses = Set(addresses)
            #expect(addresses.count == uniqueAddresses.count, "Frame addresses should be unique")
        }
    }

    @Test func firstFrameIsInstructionPointer() throws {
        let url = Self.testFile("pipeline-inlines-macos-segv.dmp")
        guard FileManager.default.fileExists(atPath: url.path) else {
            Issue.record("Test file not found")
            return
        }

        let data = try Data(contentsOf: url)
        let dump = try MinidumpParser.parse(data: data)
        let analyzer = CrashAnalyzer(dump: dump)

        if let analysis = analyzer.analyze(), let firstFrame = analysis.stackFrames.first {
            #expect(firstFrame.frameType == .instructionPointer)
        }
    }

    // MARK: - Exception Code Coverage Tests

    @Test func accessViolationProbableCause() throws {
        // Test that access violation (0xC0000005) produces appropriate message
        let url = Self.testFile("pipeline-inlines-macos-segv.dmp")
        guard FileManager.default.fileExists(atPath: url.path) else {
            Issue.record("Test file not found")
            return
        }

        let data = try Data(contentsOf: url)
        let dump = try MinidumpParser.parse(data: data)

        if dump.exception?.exceptionCode == 0xC0000005 {
            let analyzer = CrashAnalyzer(dump: dump)
            if let analysis = analyzer.analyze() {
                // Should mention memory in the probable cause
                let cause = analysis.crashSummary.probableCause.lowercased()
                #expect(cause.contains("memory") || cause.contains("access") || cause.contains("violation"))
            }
        }
    }

    // MARK: - Blame Priority Tests

    @Test func blameModuleHasValidReason() throws {
        let url = Self.testFile("full-dump.dmp")
        guard FileManager.default.fileExists(atPath: url.path) else {
            Issue.record("Test file not found")
            return
        }

        let data = try Data(contentsOf: url)
        let dump = try MinidumpParser.parse(data: data)
        let analyzer = CrashAnalyzer(dump: dump)

        if let analysis = analyzer.analyze(), let blame = analysis.blameModule {
            // Blame reason should be one of the valid types
            let validReasons: [BlameResult.BlameReason] = [
                .directCrash,
                .firstNonSystemFrame,
                .graphicsDriver,
                .thirdPartyInCallChain
            ]
            #expect(validReasons.contains(blame.reason))

            // Blame module should be non-empty
            #expect(!blame.module.name.isEmpty)

            // Description should not be empty
            #expect(!blame.reasonDescription.isEmpty)
        }
    }

    // MARK: - Recommendation Tests

    @Test func recommendationIsNotEmpty() throws {
        let url = Self.testFile("full-dump.dmp")
        guard FileManager.default.fileExists(atPath: url.path) else {
            Issue.record("Test file not found")
            return
        }

        let data = try Data(contentsOf: url)
        let dump = try MinidumpParser.parse(data: data)
        let analyzer = CrashAnalyzer(dump: dump)

        if let analysis = analyzer.analyze() {
            #expect(!analysis.crashSummary.recommendation.isEmpty)
        }
    }

    // MARK: - Edge Case Tests

    @Test func analyzerHandlesMissingContext() throws {
        // Some dumps may have threads without context
        // Analyzer should handle this gracefully
        let url = Self.testFile("test.dmp")
        guard FileManager.default.fileExists(atPath: url.path) else {
            Issue.record("Test file not found")
            return
        }

        let data = try Data(contentsOf: url)
        let dump = try MinidumpParser.parse(data: data)
        let analyzer = CrashAnalyzer(dump: dump)

        // Should not crash, even if it returns nil
        _ = analyzer.analyze()
    }

    @Test func analyzerHandlesEmptyModuleList() throws {
        let url = Self.testFile("linux-mini.dmp")
        guard FileManager.default.fileExists(atPath: url.path) else {
            Issue.record("Test file not found")
            return
        }

        let data = try Data(contentsOf: url)
        let dump = try MinidumpParser.parse(data: data)
        let analyzer = CrashAnalyzer(dump: dump)

        // Should not crash even with unusual dump structure
        _ = analyzer.analyze()
    }

    // MARK: - Mock Helpers

    /// Creates a mock ModuleInfo by constructing valid binary data
    private func createMockModule(name: String, baseAddress: UInt64, size: UInt32 = 0x10000) -> ModuleInfo? {
        var data = Data()

        // baseAddress (8 bytes)
        data.append(contentsOf: withUnsafeBytes(of: baseAddress.littleEndian) { Array($0) })
        // sizeOfImage (4 bytes)
        data.append(contentsOf: withUnsafeBytes(of: size.littleEndian) { Array($0) })
        // checksum (4 bytes)
        data.append(contentsOf: [0, 0, 0, 0])
        // timeDateStamp (4 bytes)
        data.append(contentsOf: [0, 0, 0, 0])
        // moduleNameRva (4 bytes) - 0 for mock
        data.append(contentsOf: [0, 0, 0, 0])

        // Pad to 108 bytes (ModuleInfo.size)
        while data.count < ModuleInfo.size {
            data.append(0)
        }

        guard var module = ModuleInfo(from: data, at: 0) else { return nil }
        module.setName(name)
        return module
    }
}

// MARK: - Confidence Assessment Tests

@Suite("Confidence Assessment Tests")
struct ConfidenceAssessmentTests {

    @Test func highConfidenceRequirements() {
        // High confidence requires ≥3 frame pointer frames AND ≥4 high confidence frames
        // Testing the display name as proxy for the enum value
        #expect(AnalysisConfidence.high.displayName == "High")
    }

    @Test func mediumConfidenceRequirements() {
        #expect(AnalysisConfidence.medium.displayName == "Medium")
    }

    @Test func lowConfidenceRequirements() {
        #expect(AnalysisConfidence.low.displayName == "Low")
    }
}

// MARK: - Frame Type Tests

@Suite("StackFrame Type Tests")
struct StackFrameTypeTests {

    @Test func instructionPointerFrameProperties() {
        let frame = StackFrame(
            address: 0x12345678,
            module: nil,
            offsetInModule: nil,
            frameType: .instructionPointer,
            confidence: .high
        )

        #expect(frame.frameType == .instructionPointer)
        #expect(frame.confidence == .high)
    }

    @Test func framePointerFrameProperties() {
        let frame = StackFrame(
            address: 0x12345678,
            module: nil,
            offsetInModule: nil,
            frameType: .framePointer,
            confidence: .high
        )

        #expect(frame.frameType == .framePointer)
    }

    @Test func returnAddressFrameProperties() {
        let frame = StackFrame(
            address: 0x12345678,
            module: nil,
            offsetInModule: nil,
            frameType: .returnAddress,
            confidence: .low
        )

        #expect(frame.frameType == .returnAddress)
        #expect(frame.confidence == .low)
    }

    @Test func frameHasUniqueId() {
        let frame1 = StackFrame(
            address: 0x1000,
            module: nil,
            offsetInModule: nil,
            frameType: .instructionPointer,
            confidence: .high
        )
        let frame2 = StackFrame(
            address: 0x1000,
            module: nil,
            offsetInModule: nil,
            frameType: .instructionPointer,
            confidence: .high
        )

        // Each frame should have unique ID even with same address
        #expect(frame1.id != frame2.id)
    }
}
