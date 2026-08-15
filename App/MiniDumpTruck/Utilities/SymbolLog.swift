import Foundation

/// Platform-neutral logging seam for the symbol-resolution pipeline.
///
/// The pipeline used to call `os.Logger` directly, which only exists on
/// Apple platforms. Every call site now goes through this protocol, so the
/// backend can be an `os.Logger` on macOS and swift-log everywhere else.
///
/// Messages are taken as `@autoclosure` so a disabled level never pays for
/// building the string — the same deal `os_log`'s format-string form gives.
/// The closure is `@escaping` because both backends defer evaluation past
/// their own level check.
public protocol SymbolLogBackend: Sendable {
    func trace(_ message: @autoclosure @escaping () -> String)
    func debug(_ message: @autoclosure @escaping () -> String)
    func info(_ message: @autoclosure @escaping () -> String)
    func notice(_ message: @autoclosure @escaping () -> String)
    func error(_ message: @autoclosure @escaping () -> String)
    func fault(_ message: @autoclosure @escaping () -> String)
}

/// Centralized logging identity for the symbol-resolution pipeline.
///
/// Subsystem: `com.minidumptruck` (matches the bundle identifier).
/// Categories: `symbols` for cache / server / parser events.
///
/// Visible to users via Console.app filtered on `subsystem ==
/// "com.minidumptruck"`. Power users debugging "why aren't symbols
/// resolving" can answer the question without reaching for a debugger.
/// On platforms without `os`, the same events go to swift-log under the
/// label `com.minidumptruck.symbols`.
public enum SymbolLog {
    /// Console.app filters key off this exact string. Do not rename.
    public static let subsystem = "com.minidumptruck"
    /// Console.app category for the symbol pipeline. Do not rename.
    public static let category = "symbols"

    /// swift-log has no subsystem/category split, so the two are joined
    /// into a single label.
    public static var label: String { "\(subsystem).\(category)" }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var storage: any SymbolLogBackend = makeDefaultBackend()

    /// The backend every call site logs through. Settable so tests can
    /// substitute a capturing backend; production never assigns it.
    public static var shared: any SymbolLogBackend {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            storage = newValue
        }
    }

    /// `os.Logger` where it exists, swift-log otherwise.
    public static func makeDefaultBackend() -> any SymbolLogBackend {
        #if canImport(os)
        return OSSymbolLogBackend()
        #else
        return SwiftLogSymbolLogBackend()
        #endif
    }
}
