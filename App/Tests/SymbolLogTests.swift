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

    /// Entries mentioning `token`. Pipeline call sites build their own
    /// message text, so they can't carry the prefix marker; a per-test
    /// unique PDB name is the filter instead.
    func entries(containing token: String) -> [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return storage.filter { $0.message.contains(token) }
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

/// Fails every request with a caller-supplied `NSError`, so a test can
/// drive `SymbolServer.fetch` into its network-failure branch carrying an
/// error whose `localizedDescription` embeds an absolute path.
private final class FailingURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var storage: NSError?

    static var failure: NSError? {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }

    /// Build a session routed through this protocol. Only requests made
    /// on the returned session reach it, so no other suite is affected.
    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FailingURLProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let error = Self.failure ?? URLError(.unknown) as NSError
        client?.urlProtocol(self, didFailWithError: error)
    }

    override func stopLoading() {}
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

    /// The logged line must not echo what `Data(contentsOf:)` produced.
    /// The expected raw description is recomputed here by repeating the
    /// same failing read, so the negative assertion holds in any locale
    /// and on any macOS version rather than hard-coding an English
    /// sentence that a future OS could reword.
    @Test("cache read failures log a sanitized reason, never the raw localized description")
    func cacheReadFailureLogsSanitizedReason() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MiniDumpTruck-SanitizedLog-\(UUID().uuidString)",
                                    isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let key = try #require(PDBIdentity(pdbName: "sanitizeProbeCache.pdb",
                                           guid: String(repeating: "a", count: 32),
                                           age: 1))
        let cache = SymbolCache(root: root)
        try await cache.store(Data([0x01, 0x02, 0x03]), for: key)

        // Make the read fail with something other than "no such file",
        // which the call site deliberately logs at trace level instead.
        let fileURL = cache.url(for: key)
        try FileManager.default.setAttributes([.posixPermissions: 0o000],
                                              ofItemAtPath: fileURL.path)

        // What the call site used to log. Recomputed, not assumed.
        var rawDescription = ""
        do {
            _ = try Data(contentsOf: fileURL)
        } catch {
            rawDescription = error.localizedDescription
        }
        // Fails loudly (rather than passing vacuously) if the read
        // unexpectedly succeeded — e.g. running as root.
        try #require(!rawDescription.isEmpty)
        try #require(rawDescription != "permission denied")

        let capture = CapturingBackend()
        let previous = SymbolLog.shared
        SymbolLog.shared = capture
        defer { SymbolLog.shared = previous }

        let result = await cache.data(for: key)
        #expect(result == nil)

        let entries = capture.entries(containing: key.pdbName)
        #expect(entries.count == 1)
        let line = try #require(entries.first?.message)

        #expect(entries.first?.level == "error")
        #expect(line == "cache read failed for \(key.pdbName): permission denied")
        #expect(!line.contains(rawDescription))
        #expect(!line.contains(root.path))
        #expect(!line.contains(root.lastPathComponent))
    }

    /// `URLSession` hands a `URLProtocol`-supplied error's
    /// `localizedDescription` through verbatim, so this drives the
    /// network-failure branch with a description that genuinely embeds an
    /// absolute path — and asserts the path never reaches the log.
    @Test("network failures log a sanitized reason, never a path-bearing description")
    func networkFailureLogsSanitizedReason() async throws {
        let secretPath = "/Users/someone/Library/Caches/MiniDumpTruck-\(UUID().uuidString)/staging.pdb"
        FailingURLProtocol.failure = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorNotConnectedToInternet,
            userInfo: [NSLocalizedDescriptionKey:
                        "Could not reach the symbol server while writing \(secretPath)"]
        )
        defer { FailingURLProtocol.failure = nil }

        let key = try #require(PDBIdentity(pdbName: "sanitizeProbeServer.pdb",
                                           guid: String(repeating: "b", count: 32),
                                           age: 1))
        let server = SymbolServer(baseURL: URL(string: "https://msdl.sanitize.test/symbols")!,
                                  urlSession: FailingURLProtocol.session())

        let capture = CapturingBackend()
        let previous = SymbolLog.shared
        SymbolLog.shared = capture
        defer { SymbolLog.shared = previous }

        var underlying: (any Error)?
        do {
            _ = try await server.fetch(key)
            Issue.record("fetch unexpectedly succeeded against a always-failing protocol")
        } catch let error as SymbolServer.FetchError {
            guard case .networkFailure(let wrapped) = error else {
                throw error
            }
            underlying = wrapped
        }

        // Proves this test exercises a genuinely path-bearing
        // localizedDescription rather than assuming one.
        let raw = try #require(underlying).localizedDescription
        try #require(raw.contains(secretPath))

        let entries = capture.entries(containing: key.pdbName)
        let line = try #require(entries.first { $0.level == "error" }?.message)

        #expect(line == "network failure for \(key.pdbName): network error (\(NSURLErrorNotConnectedToInternet))")
        #expect(!line.contains(secretPath))
        #expect(!line.contains(raw))
    }
}
