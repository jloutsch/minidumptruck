import Foundation

/// Hex formatting helpers used everywhere we display an address or 32-bit
/// value in the UI / exporters / reports. Centralized so addresses render
/// consistently (16 hex digits, zero-padded) across all output formats.
public extension UInt64 {
    /// Standard 64-bit address rendering: `0x` prefix, 16 uppercase hex
    /// digits, zero-padded. Matches WinDbg / debugger conventions and the
    /// existing convention everywhere else in the app.
    var hexAddress: String {
        String(format: "0x%016llX", self)
    }
}

public extension UInt32 {
    /// Standard 32-bit value rendering: `0x` prefix, 8 uppercase hex
    /// digits, zero-padded. Used for exception codes, flags, checksums,
    /// CPU status registers — anywhere a fixed-width 32-bit value is
    /// shown.
    var hex32: String {
        String(format: "0x%08X", self)
    }
}
