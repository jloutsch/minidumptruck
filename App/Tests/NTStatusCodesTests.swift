import Foundation
import Testing
@testable import MiniDumpTruckCore

@Suite("NTStatusCodes Tests")
struct NTStatusCodesTests {

    // MARK: - Known Code Lookups

    @Test func statusSuccess() {
        #expect(NTStatusCodes.name(for: 0x00000000) == "STATUS_SUCCESS")
        #expect(NTStatusCodes.description(for: 0x00000000) == "The operation completed successfully.")
    }

    @Test func accessViolation() {
        #expect(NTStatusCodes.name(for: 0xC0000005) == "STATUS_ACCESS_VIOLATION")
        #expect(NTStatusCodes.description(for: 0xC0000005).contains("memory"))
    }

    @Test func stackOverflow() {
        #expect(NTStatusCodes.name(for: 0xC00000FD) == "STATUS_STACK_OVERFLOW")
    }

    @Test func integerDivideByZero() {
        #expect(NTStatusCodes.name(for: 0xC0000094) == "STATUS_INTEGER_DIVIDE_BY_ZERO")
    }

    @Test func heapCorruption() {
        #expect(NTStatusCodes.name(for: 0xC0000374) == "STATUS_HEAP_CORRUPTION")
    }

    @Test func breakpoint() {
        #expect(NTStatusCodes.name(for: 0x80000003) == "STATUS_BREAKPOINT")
    }

    @Test func singleStep() {
        #expect(NTStatusCodes.name(for: 0x80000004) == "STATUS_SINGLE_STEP")
    }

    // MARK: - Unknown Codes

    @Test func unknownCodeReturnsHex() {
        let unknownCode: UInt32 = 0xDEADBEEF
        #expect(NTStatusCodes.name(for: unknownCode) == "0xDEADBEEF")
    }

    @Test func unknownCodeDescription() {
        let unknownCode: UInt32 = 0xDEADBEEF
        #expect(NTStatusCodes.description(for: unknownCode) == "Unknown exception code.")
    }

    // MARK: - Severity Tests

    @Test func severitySuccess() {
        // 0x00xxxxxx = Success (bits 31-30 = 00)
        #expect(NTStatusCodes.severity(for: 0x00000000) == 0)
        #expect(NTStatusCodes.severityString(for: 0x00000000) == "Success")
        #expect(NTStatusCodes.isError(0x00000000) == false)
    }

    @Test func severityInformational() {
        // 0x40xxxxxx = Informational (bits 31-30 = 01)
        #expect(NTStatusCodes.severity(for: 0x40000000) == 1)
        #expect(NTStatusCodes.severityString(for: 0x40000000) == "Informational")
        #expect(NTStatusCodes.isError(0x40000000) == false)
    }

    @Test func severityWarning() {
        // 0x80xxxxxx = Warning (bits 31-30 = 10)
        #expect(NTStatusCodes.severity(for: 0x80000003) == 2)
        #expect(NTStatusCodes.severityString(for: 0x80000003) == "Warning")
        #expect(NTStatusCodes.isError(0x80000003) == false)
    }

    @Test func severityError() {
        // 0xC0xxxxxx = Error (bits 31-30 = 11)
        #expect(NTStatusCodes.severity(for: 0xC0000005) == 3)
        #expect(NTStatusCodes.severityString(for: 0xC0000005) == "Error")
        #expect(NTStatusCodes.isError(0xC0000005) == true)
    }

    // MARK: - Edge Cases

    @Test func maxUInt32() {
        let maxCode: UInt32 = 0xFFFFFFFF
        #expect(NTStatusCodes.severity(for: maxCode) == 3)
        #expect(NTStatusCodes.isError(maxCode) == true)
    }

    @Test func commonExceptionCodes() {
        // Test a sample of common exception codes that should be in the database
        let commonCodes: [UInt32] = [
            0xC0000005,  // ACCESS_VIOLATION
            0xC0000094,  // INTEGER_DIVIDE_BY_ZERO
            0xC0000096,  // PRIVILEGED_INSTRUCTION
            0xC00000FD,  // STACK_OVERFLOW
            0xC0000135,  // DLL_NOT_FOUND
            0xC0000142,  // DLL_INIT_FAILED
        ]

        for code in commonCodes {
            let name = NTStatusCodes.name(for: code)
            // Should not return hex format for known codes
            #expect(!name.hasPrefix("0x"), "Code \(String(format: "0x%08X", code)) should be known")
        }
    }

    // MARK: - RPC Codes

    @Test func rpcCodes() {
        #expect(NTStatusCodes.name(for: 0xC0020001) == "RPC_NT_INVALID_STRING_BINDING")
        #expect(NTStatusCodes.name(for: 0xC0020047) == "RPC_S_COMM_FAILURE")
    }

    // MARK: - Security Codes

    @Test func securityCodes() {
        #expect(NTStatusCodes.name(for: 0xC000006D) == "STATUS_LOGON_FAILURE")
        #expect(NTStatusCodes.name(for: 0xC0000022) == "STATUS_ACCESS_DENIED")
    }
}
