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

    @Test func frameTypeHelpTextsAreUniqueAndCiteRecoveryMethod() {
        let cases = StackFrame.FrameType.allCases
        let helps = cases.map(\.helpText)
        for h in helps { #expect(!h.isEmpty) }
        #expect(Set(helps).count == cases.count, "help text must be unique per case")

        // Each case's help must mention its discriminating recovery
        // mechanism — guards against accidental case-pair swap.
        #expect(StackFrame.FrameType.instructionPointer.helpText.localizedCaseInsensitiveContains("instruction pointer"))
        #expect(StackFrame.FrameType.framePointer.helpText.localizedCaseInsensitiveContains("RBP"))
        #expect(StackFrame.FrameType.returnAddress.helpText.localizedCaseInsensitiveContains("stack"))
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

    @Test func frameConfidenceHelpTextsMatchAnalyzerSemantics() {
        // Wording must reflect what CrashAnalyzer actually does — the
        // first round of this PR shipped tooltips that referenced
        // "known call instructions" (not implemented) and incorrect
        // medium/low semantics. Lock the accurate vocabulary here so a
        // future edit either updates both sides together or fails this
        // test.
        let high = StackFrame.FrameConfidence.high.helpText
        #expect(high.localizedCaseInsensitiveContains("RBP") || high.localizedCaseInsensitiveContains("exception"))
        #expect(!high.localizedCaseInsensitiveContains("call instruction"),
                "do not claim call-instruction analysis — analyzer does not disassemble")

        let medium = StackFrame.FrameConfidence.medium.helpText
        #expect(medium.localizedCaseInsensitiveContains("system module"))

        let low = StackFrame.FrameConfidence.low.helpText
        #expect(low.localizedCaseInsensitiveContains("user") || low.localizedCaseInsensitiveContains("third-party"))

        let helps = StackFrame.FrameConfidence.allCases.map(\.helpText)
        for h in helps { #expect(!h.isEmpty) }
        #expect(Set(helps).count == helps.count)
    }

    @Test func frameConfidenceLabelsAreNonEmptyAndUnique() {
        let cases = StackFrame.FrameConfidence.allCases
        #expect(Set(cases.map(\.shortLabel)).count == cases.count)
        #expect(Set(cases.map(\.accessibilityLabel)).count == cases.count)
    }
}
