import Foundation
import Logging
#if canImport(os)
import os
#endif

#if canImport(os)
/// `os.Logger` backend — the default on Apple platforms.
///
/// Every message is interpolated with `privacy: .public`. `os_log` redacts
/// dynamic strings by default, so without that annotation each line would
/// come out of an already-composed message as `<private>` and the whole
/// subsystem would go quiet without any build or test failure. The call
/// sites used to carry `privacy: .public` themselves; that decision now
/// lives here.
public struct OSSymbolLogBackend: SymbolLogBackend {
    private let logger: os.Logger

    public init(subsystem: String = SymbolLog.subsystem, category: String = SymbolLog.category) {
        self.logger = os.Logger(subsystem: subsystem, category: category)
    }

    public func trace(_ message: @autoclosure @escaping () -> String) {
        logger.trace("\(message(), privacy: .public)")
    }

    public func debug(_ message: @autoclosure @escaping () -> String) {
        logger.debug("\(message(), privacy: .public)")
    }

    public func info(_ message: @autoclosure @escaping () -> String) {
        logger.info("\(message(), privacy: .public)")
    }

    public func notice(_ message: @autoclosure @escaping () -> String) {
        logger.notice("\(message(), privacy: .public)")
    }

    public func error(_ message: @autoclosure @escaping () -> String) {
        logger.error("\(message(), privacy: .public)")
    }

    public func fault(_ message: @autoclosure @escaping () -> String) {
        logger.fault("\(message(), privacy: .public)")
    }
}
#endif

/// swift-log backend — the only one available off Apple platforms, and
/// compiled on every platform so the non-Apple path cannot rot unnoticed.
///
/// Level mapping is like-for-like except `fault`, which swift-log spells
/// `critical`.
public struct SwiftLogSymbolLogBackend: SymbolLogBackend {
    private let logger: Logging.Logger

    public init(label: String = SymbolLog.label) {
        self.logger = Logging.Logger(label: label)
    }

    /// Injecting a preconfigured logger lets a caller (or a test) supply
    /// its own `LogHandler` without touching the process-global
    /// `LoggingSystem.bootstrap`.
    public init(logger: Logging.Logger) {
        self.logger = logger
    }

    public func trace(_ message: @autoclosure @escaping () -> String) {
        logger.trace("\(message())")
    }

    public func debug(_ message: @autoclosure @escaping () -> String) {
        logger.debug("\(message())")
    }

    public func info(_ message: @autoclosure @escaping () -> String) {
        logger.info("\(message())")
    }

    public func notice(_ message: @autoclosure @escaping () -> String) {
        logger.notice("\(message())")
    }

    public func error(_ message: @autoclosure @escaping () -> String) {
        logger.error("\(message())")
    }

    public func fault(_ message: @autoclosure @escaping () -> String) {
        logger.critical("\(message())")
    }
}
