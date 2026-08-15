import Foundation
import Logging
import Testing
@testable import MiniDumpTruckCore

/// Every message these tests emit carries this prefix. `SymbolLog.shared` is
/// process-global, so while a capturing backend is installed it also receives
/// whatever other suites happen to log in parallel. Filtering on the token
/// keeps the assertions about this suite's own calls.
private let marker = "symbol-log-seam-test"

/// Records what each level was handed, so a test can assert the message text
/// and the level it arrived at.
private final class CapturingBackend: SymbolLogBackend, @unchecked Sendable {
    struct Entry: Equatable, Sendable {
        let level: String
        let message: String
    }

    private let lock = NSLock()
    private var storage: [Entry] = []

    /// Only the entries this suite emitted; parallel noise is dropped.
    var markedEntries: [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return storage.filter { $0.message.hasPrefix(marker) }
    }

    private func record(_ level: String, _ message: () -> String) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(Entry(level: level, message: message()))
    }

    func trace(_ message: @autoclosure @escaping () -> String) { record("trace", message) }
    func debug(_ message: @autoclosure @escaping () -> String) { record("debug", message) }
    func info(_ message: @autoclosure @escaping () -> String) { record("info", message) }
    func notice(_ message: @autoclosure @escaping () -> String) { record("notice", message) }
    func error(_ message: @autoclosure @escaping () -> String) { record("error", message) }
    func fault(_ message: @autoclosure @escaping () -> String) { record("fault", message) }
}

/// A `LogHandler` that captures instead of writing, so the swift-log backend
/// can be exercised without touching the process-global
/// `LoggingSystem.bootstrap`.
private struct CapturingLogHandler: LogHandler {
    final class Box: @unchecked Sendable {
        struct Entry: Sendable {
            let level: Logging.Logger.Level
            let message: String
        }

        private let lock = NSLock()
        private var storage: [Entry] = []

        var entries: [Entry] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }

        func append(_ entry: Entry) {
            lock.lock()
            defer { lock.unlock() }
            storage.append(entry)
        }
    }

    let box: Box
    var logLevel: Logging.Logger.Level = .trace
    var metadata: Logging.Logger.Metadata = [:]

    subscript(metadataKey key: String) -> Logging.Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(
        level: Logging.Logger.Level,
        message: Logging.Logger.Message,
        metadata: Logging.Logger.Metadata?,
        source: String,
        file: String,
        function: String,
        line: UInt
    ) {
        box.append(Box.Entry(level: level, message: message.description))
    }
}

/// Build a swift-log backed backend whose output lands in the returned box.
private func makeCapturingSwiftLogBackend() -> (SwiftLogSymbolLogBackend, CapturingLogHandler.Box) {
    let box = CapturingLogHandler.Box()
    let logger = Logging.Logger(label: SymbolLog.label) { _ in CapturingLogHandler(box: box) }
    return (SwiftLogSymbolLogBackend(logger: logger), box)
}

/// Serialized: these tests swap the process-global `SymbolLog.shared`, so they
/// must not run against each other.
@Suite("SymbolLog", .serialized)
struct SymbolLogTests {

    @Test("subsystem and category are the exact strings Console.app filters on")
    func identityStringsAreStable() {
        #expect(SymbolLog.subsystem == "com.minidumptruck")
        #expect(SymbolLog.category == "symbols")
    }

    @Test("swift-log label joins subsystem and category")
    func labelJoinsSubsystemAndCategory() {
        #expect(SymbolLog.label == "com.minidumptruck.symbols")
    }

    @Test("every level reaches the injected backend with its message intact")
    func allSixLevelsReachTheBackend() {
        let capture = CapturingBackend()
        let previous = SymbolLog.shared
        SymbolLog.shared = capture
        defer { SymbolLog.shared = previous }

        SymbolLog.shared.trace("\(marker) trace")
        SymbolLog.shared.debug("\(marker) debug")
        SymbolLog.shared.info("\(marker) info")
        SymbolLog.shared.notice("\(marker) notice")
        SymbolLog.shared.error("\(marker) error")
        SymbolLog.shared.fault("\(marker) fault")

        #expect(capture.markedEntries == [
            .init(level: "trace", message: "\(marker) trace"),
            .init(level: "debug", message: "\(marker) debug"),
            .init(level: "info", message: "\(marker) info"),
            .init(level: "notice", message: "\(marker) notice"),
            .init(level: "error", message: "\(marker) error"),
            .init(level: "fault", message: "\(marker) fault")
        ])
    }

    @Test("swift-log backend maps fault to critical")
    func swiftLogMapsFaultToCritical() throws {
        let (backend, box) = makeCapturingSwiftLogBackend()

        backend.fault("\(marker) boom")

        let entry = try #require(box.entries.first)
        #expect(box.entries.count == 1)
        #expect(entry.level == .critical)
        #expect(entry.message == "\(marker) boom")
    }

    @Test("swift-log backend maps the other five levels like-for-like")
    func swiftLogMapsRemainingLevelsLikeForLike() {
        let (backend, box) = makeCapturingSwiftLogBackend()

        backend.trace("\(marker) trace")
        backend.debug("\(marker) debug")
        backend.info("\(marker) info")
        backend.notice("\(marker) notice")
        backend.error("\(marker) error")

        #expect(box.entries.map(\.level) == [.trace, .debug, .info, .notice, .error])
        #expect(box.entries.map(\.message) == [
            "\(marker) trace",
            "\(marker) debug",
            "\(marker) info",
            "\(marker) notice",
            "\(marker) error"
        ])
    }

    /// The swift-log backend is compiled on every platform, including this
    /// one, so the path Linux will take cannot rot unnoticed.
    @Test("swift-log backend is available on this platform")
    func swiftLogBackendCompilesHere() {
        let backend: any SymbolLogBackend = SwiftLogSymbolLogBackend()
        #expect(backend is SwiftLogSymbolLogBackend)
    }

    #if canImport(os)
    @Test("default backend is the os.Logger backend on Apple platforms")
    func defaultBackendIsOSBackendOnApple() {
        #expect(SymbolLog.makeDefaultBackend() is OSSymbolLogBackend)
    }
    #endif
}
