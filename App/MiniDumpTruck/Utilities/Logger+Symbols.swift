import Foundation
import os

/// Centralized `os_log` subsystem for the symbol-resolution pipeline.
///
/// Subsystem: `com.minidumptruck` (matches the bundle identifier).
/// Categories: `symbols` for cache / server / parser events.
///
/// Visible to users via Console.app filtered on `subsystem ==
/// "com.minidumptruck"`. Power users debugging "why aren't symbols
/// resolving" can answer the question without reaching for a debugger.
extension Logger {
    public static let symbols = Logger(
        subsystem: "com.minidumptruck",
        category: "symbols"
    )
}
