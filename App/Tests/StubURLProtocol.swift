// Custom URLProtocol that returns canned responses for any URL request.
// Used by SymbolServer tests to exercise the fetch pipeline without
// network egress. Each test installs its own per-request handler.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class StubURLProtocol: URLProtocol, @unchecked Sendable {

    /// Per-host handlers. Tests in different `@Suite`s may run in
    /// parallel; if both wrote to a single static handler they'd
    /// race. Routing by host means SymbolServerTests can use
    /// `msdl.test` and SymbolicationServiceTests can use
    /// `msdl-svc.test` without stepping on each other.
    private static let handlerLock = NSLock()
    nonisolated(unsafe) private static var handlersByHost: [String: @Sendable (URLRequest) -> (HTTPURLResponse, Data)] = [:]

    /// Per-test request -> response mapping. Backwards-compat shim:
    /// assigning `handler` registers it under the catch-all "*" host
    /// so existing tests that don't care about host scoping keep
    /// working. New tests should call `setHandler(forHost:)`.
    static var handler: (@Sendable (URLRequest) -> (HTTPURLResponse, Data))? {
        get { handlerLock.withLock { handlersByHost["*"] } }
        set {
            handlerLock.withLock {
                if let newValue { handlersByHost["*"] = newValue }
                else { handlersByHost.removeValue(forKey: "*") }
            }
        }
    }

    static func setHandler(forHost host: String,
                           _ handler: @Sendable @escaping (URLRequest) -> (HTTPURLResponse, Data)) {
        handlerLock.withLock { handlersByHost[host] = handler }
    }

    /// Clear handlers between tests. Per-host-specific or all.
    static func reset(host: String? = nil) {
        handlerLock.withLock {
            if let host { handlersByHost.removeValue(forKey: host) }
            else { handlersByHost.removeAll() }
        }
    }

    private static func resolve(for request: URLRequest) -> (@Sendable (URLRequest) -> (HTTPURLResponse, Data))? {
        guard let host = request.url?.host else {
            return handlerLock.withLock { handlersByHost["*"] }
        }
        return handlerLock.withLock { handlersByHost[host] ?? handlersByHost["*"] }
    }

    /// Build a URLSession that routes through this protocol. Each
    /// session gets its own URLSessionConfiguration so tests don't
    /// share state through URLSession.shared.
    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 10
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.resolve(for: request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        let (response, data) = handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
