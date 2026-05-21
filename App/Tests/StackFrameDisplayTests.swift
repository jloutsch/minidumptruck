import Foundation
import Testing
@testable import MiniDumpTruckCore

@Suite("StackFrame display extensions")
struct StackFrameDisplayTests {

    // MARK: - FrameType

    @Test func frameTypeShortLabels() {
        #expect(StackFrame.FrameType.instructionPointer.shortLabel == "IP")
        #expect(StackFrame.FrameType.returnAddress.shortLabel == "Ret")
        #expect(StackFrame.FrameType.framePointer.shortLabel == "FP")
    }

    @Test func frameTypeAccessibilityLabels() {
        #expect(StackFrame.FrameType.instructionPointer.accessibilityLabel == "Instruction pointer")
        #expect(StackFrame.FrameType.returnAddress.accessibilityLabel == "Return address")
        #expect(StackFrame.FrameType.framePointer.accessibilityLabel == "Frame pointer")
    }

    @Test func frameTypeLabelsAreNonEmptyAndUnique() {
        // Catches accidental case-pair label swaps + the next contributor
        // who adds a 4th case without supplying display strings.
        let cases = StackFrame.FrameType.allCases
        let shortLabels = cases.map(\.shortLabel)
        let voLabels = cases.map(\.accessibilityLabel)

        for label in shortLabels {
            #expect(!label.isEmpty)
        }
        for label in voLabels {
            #expect(!label.isEmpty)
        }
        #expect(Set(shortLabels).count == cases.count, "shortLabels must be unique")
        #expect(Set(voLabels).count == cases.count, "accessibilityLabels must be unique")
    }

    // MARK: - FrameConfidence

    @Test func frameConfidenceShortLabels() {
        #expect(StackFrame.FrameConfidence.high.shortLabel == "H")
        #expect(StackFrame.FrameConfidence.medium.shortLabel == "M")
        #expect(StackFrame.FrameConfidence.low.shortLabel == "L")
    }

    @Test func frameConfidenceAccessibilityLabels() {
        #expect(StackFrame.FrameConfidence.high.accessibilityLabel == "High confidence")
        #expect(StackFrame.FrameConfidence.medium.accessibilityLabel == "Medium confidence")
        #expect(StackFrame.FrameConfidence.low.accessibilityLabel == "Low confidence")
    }

    @Test func frameConfidenceLabelsAreNonEmptyAndUnique() {
        let cases = StackFrame.FrameConfidence.allCases
        #expect(Set(cases.map(\.shortLabel)).count == cases.count)
        #expect(Set(cases.map(\.accessibilityLabel)).count == cases.count)
    }
}
