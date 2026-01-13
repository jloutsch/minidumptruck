import Foundation

/// Common Windows NTSTATUS exception codes
/// Reference: https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-erref/596a1078-e883-4972-9bbc-49e60bebca55
public enum NTStatusCodes {
    private static let codes: [UInt32: (name: String, description: String)] = [
        // SUCCESS (0x00000000 - 0x3FFFFFFF)
        0x00000000: ("STATUS_SUCCESS", "The operation completed successfully."),
        0x00000102: ("STATUS_TIMEOUT", "The wait operation timed out."),
        0x00000103: ("STATUS_PENDING", "The operation is pending."),

        // INFORMATIONAL (0x40000000 - 0x7FFFFFFF)
        0x40000000: ("STATUS_OBJECT_NAME_EXISTS", "The object name already exists."),
        0x40000015: ("STATUS_FATAL_APP_EXIT", "Fatal application exit."),

        // WARNING (0x80000000 - 0xBFFFFFFF)
        0x80000001: ("STATUS_GUARD_PAGE_VIOLATION", "A guard page was accessed."),
        0x80000002: ("STATUS_DATATYPE_MISALIGNMENT", "A data type misalignment occurred."),
        0x80000003: ("STATUS_BREAKPOINT", "A breakpoint was hit."),
        0x80000004: ("STATUS_SINGLE_STEP", "Single step exception."),
        0x80000005: ("STATUS_BUFFER_OVERFLOW", "The buffer overflowed."),
        0x80000026: ("STATUS_LONGJUMP", "A long jump was executed."),
        0x80000029: ("STATUS_UNWIND_CONSOLIDATE", "Unwind consolidate exception."),

        // ERROR - General (0xC0000000 - 0xC000FFFF)
        0xC0000001: ("STATUS_UNSUCCESSFUL", "The operation was unsuccessful."),
        0xC0000002: ("STATUS_NOT_IMPLEMENTED", "Not implemented."),
        0xC0000005: ("STATUS_ACCESS_VIOLATION", "The instruction referenced memory that could not be read or written."),
        0xC0000006: ("STATUS_IN_PAGE_ERROR", "The page could not be read from disk."),
        0xC0000008: ("STATUS_INVALID_HANDLE", "An invalid handle was specified."),
        0xC000000D: ("STATUS_INVALID_PARAMETER", "An invalid parameter was passed."),
        0xC0000017: ("STATUS_NO_MEMORY", "Not enough memory to complete the operation."),
        0xC000001D: ("STATUS_ILLEGAL_INSTRUCTION", "An illegal instruction was executed."),
        0xC0000022: ("STATUS_ACCESS_DENIED", "Access denied."),
        0xC0000025: ("STATUS_NONCONTINUABLE_EXCEPTION", "A non-continuable exception occurred."),
        0xC000006D: ("STATUS_LOGON_FAILURE", "Logon failure."),
        0xC000007B: ("STATUS_INVALID_IMAGE_FORMAT", "Invalid image format."),
        0xC000008C: ("STATUS_ARRAY_BOUNDS_EXCEEDED", "Array bounds were exceeded."),
        0xC000008D: ("STATUS_FLOAT_DENORMAL_OPERAND", "Floating point denormal operand."),
        0xC000008E: ("STATUS_FLOAT_DIVIDE_BY_ZERO", "Floating point division by zero."),
        0xC000008F: ("STATUS_FLOAT_INEXACT_RESULT", "Floating point inexact result."),
        0xC0000090: ("STATUS_FLOAT_INVALID_OPERATION", "Floating point invalid operation."),
        0xC0000091: ("STATUS_FLOAT_OVERFLOW", "Floating point overflow."),
        0xC0000092: ("STATUS_FLOAT_STACK_CHECK", "Floating point stack check."),
        0xC0000093: ("STATUS_FLOAT_UNDERFLOW", "Floating point underflow."),
        0xC0000094: ("STATUS_INTEGER_DIVIDE_BY_ZERO", "Integer division by zero."),
        0xC0000095: ("STATUS_INTEGER_OVERFLOW", "Integer overflow."),
        0xC0000096: ("STATUS_PRIVILEGED_INSTRUCTION", "A privileged instruction was executed."),
        0xC00000FD: ("STATUS_STACK_OVERFLOW", "A stack overflow occurred."),

        // ERROR - DLL/Image
        0xC0000135: ("STATUS_DLL_NOT_FOUND", "The specified DLL was not found."),
        0xC0000138: ("STATUS_ORDINAL_NOT_FOUND", "The specified ordinal was not found in the DLL."),
        0xC0000139: ("STATUS_ENTRYPOINT_NOT_FOUND", "The entry point was not found in the DLL."),
        0xC000013A: ("STATUS_CONTROL_C_EXIT", "Application terminated by Ctrl+C."),
        0xC0000142: ("STATUS_DLL_INIT_FAILED", "DLL initialization routine failed."),
        0xC0000144: ("STATUS_UNHANDLED_EXCEPTION", "Unhandled exception."),
        0xC0000194: ("STATUS_POSSIBLE_DEADLOCK", "A potential deadlock condition was detected."),

        // ERROR - Stack/Heap
        0xC0000374: ("STATUS_HEAP_CORRUPTION", "A heap has been corrupted."),
        0xC0000409: ("STATUS_STACK_BUFFER_OVERRUN", "The system detected an overrun of a stack-based buffer."),
        0xC0000417: ("STATUS_INVALID_CRUNTIME_PARAMETER", "Invalid C runtime parameter."),
        0xC0000420: ("STATUS_ASSERTION_FAILURE", "An assertion failure occurred."),

        // ERROR - Control Flow Guard
        0xC0000602: ("STATUS_FAIL_FAST_EXCEPTION", "A fail-fast exception occurred."),

        // C++/CLR/Language Exceptions
        0xE06D7363: ("CPP_EXCEPTION", "A C++ exception was thrown (MSVC)."),
        0xE0434352: ("CLR_EXCEPTION", "A .NET CLR exception was thrown."),
        0xE0434F4D: ("COM_EXCEPTION", "A COM exception was thrown."),

        // Debug Exceptions
        0x40010005: ("DBG_CONTROL_C", "Debugger received Ctrl+C."),
        0x40010008: ("DBG_CONTROL_BREAK", "Debugger received Ctrl+Break."),

        // RPC Exceptions
        0xC0020001: ("RPC_NT_INVALID_STRING_BINDING", "RPC invalid string binding."),
        0xC0020047: ("RPC_S_COMM_FAILURE", "RPC communication failure."),
    ]

    /// Get the name for an NTSTATUS code
    public static func name(for code: UInt32) -> String {
        codes[code]?.name ?? String(format: "0x%08X", code)
    }

    /// Get the description for an NTSTATUS code
    public static func description(for code: UInt32) -> String {
        codes[code]?.description ?? "Unknown exception code."
    }

    /// Get severity level (0 = Success, 1 = Informational, 2 = Warning, 3 = Error)
    public static func severity(for code: UInt32) -> Int {
        Int((code >> 30) & 0x3)
    }

    /// Human-readable severity
    public static func severityString(for code: UInt32) -> String {
        switch severity(for: code) {
        case 0: return "Success"
        case 1: return "Informational"
        case 2: return "Warning"
        case 3: return "Error"
        default: return "Unknown"
        }
    }

    /// Check if code represents an error
    public static func isError(_ code: UInt32) -> Bool {
        severity(for: code) == 3
    }
}
