import Foundation
import Testing
@testable import MiniDumpTruckCore

@Suite("SymbolServer", .serialized)
struct SymbolServerTests {

    private static let testBase = URL(string: "https://msdl.test/symbols")!

    private func validKey(_ name: String = "ntdll.pdb") -> PDBIdentity {
        // Single-character repeating GUIDs are intentional for secret
        // scanners; production GUIDs come straight from CodeView.
        PDBIdentity(pdbName: name,
                    guid: String(repeating: "a", count: 32),
                    age: 1)!
    }

    @Test func urlMatchesMSDLPathConvention() async {
        let server = SymbolServer(baseURL: Self.testBase, urlSession: StubURLProtocol.session())
        let key = validKey()
        let url = await server.url(for: key)
        // Convention: <base>/<pdb>/<GUID><AGE>/<pdb>
        #expect(url?.absoluteString == "https://msdl.test/symbols/ntdll.pdb/\(String(repeating: "A", count: 32))1/ntdll.pdb")
    }

    @Test func disabledServerThrowsOfflineWithoutHittingNetwork() async {
        let session = StubURLProtocol.session()
        StubURLProtocol.setHandler(forHost: "msdl.test"){ _ in
            Issue.record("network must not be hit when server is disabled")
            return (HTTPURLResponse(url: Self.testBase, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
        }
        defer { StubURLProtocol.reset(host: "msdl.test") }
        let server = SymbolServer(baseURL: Self.testBase, urlSession: session)
        await server.setEnabledForTest(false)

        do {
            _ = try await server.fetch(validKey())
            Issue.record("expected .offline")
        } catch SymbolServer.FetchError.offline {
            // expected
        } catch {
            Issue.record("expected .offline, got \(error)")
        }
    }

    @Test func successfulFetchReturnsBytes() async throws {
        let payload = Data("hello pdb".utf8)
        StubURLProtocol.setHandler(forHost: "msdl.test"){ request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
             payload)
        }
        defer { StubURLProtocol.reset(host: "msdl.test") }
        let server = SymbolServer(baseURL: Self.testBase, urlSession: StubURLProtocol.session())
        let data = try await server.fetch(validKey())
        #expect(data == payload)
    }

    @Test func notFoundThrowsTypedError() async {
        StubURLProtocol.setHandler(forHost: "msdl.test"){ request in
            (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
        }
        defer { StubURLProtocol.reset(host: "msdl.test") }
        let server = SymbolServer(baseURL: Self.testBase, urlSession: StubURLProtocol.session())
        do {
            _ = try await server.fetch(validKey())
            Issue.record("expected .notFound")
        } catch SymbolServer.FetchError.notFound {
            // expected
        } catch {
            Issue.record("expected .notFound, got \(error)")
        }
    }

    @Test func nonStandardStatusThrowsHTTPError() async {
        StubURLProtocol.setHandler(forHost: "msdl.test"){ request in
            (HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!, Data())
        }
        defer { StubURLProtocol.reset(host: "msdl.test") }
        let server = SymbolServer(baseURL: Self.testBase, urlSession: StubURLProtocol.session())
        do {
            _ = try await server.fetch(validKey())
            Issue.record("expected .httpError(503)")
        } catch SymbolServer.FetchError.httpError(let code) {
            #expect(code == 503)
        } catch {
            Issue.record("got unexpected error: \(error)")
        }
    }

    @Test func fetchCachedHitReturnsCachedBytesWithoutNetwork() async throws {
        let payload = Data("cached".utf8)
        let cacheRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MDT-symserver-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let cache = SymbolCache(root: cacheRoot)
        let key = validKey("cached.pdb")
        try await cache.store(payload, for: key)

        StubURLProtocol.setHandler(forHost: "msdl.test"){ _ in
            Issue.record("network must not be hit on cache hit")
            return (HTTPURLResponse(url: Self.testBase, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
        }
        defer { StubURLProtocol.reset(host: "msdl.test") }
        let server = SymbolServer(baseURL: Self.testBase, urlSession: StubURLProtocol.session())

        let bytes = await server.fetchCached(key, cache: cache)
        #expect(bytes == payload)
    }

    @Test func fetchCachedMissDownloadsAndStores() async throws {
        let payload = Data("downloaded".utf8)
        let cacheRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MDT-symserver-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let cache = SymbolCache(root: cacheRoot)
        let key = validKey("downloaded.pdb")

        StubURLProtocol.setHandler(forHost: "msdl.test"){ request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, payload)
        }
        defer { StubURLProtocol.reset(host: "msdl.test") }
        let server = SymbolServer(baseURL: Self.testBase, urlSession: StubURLProtocol.session())

        let bytes = await server.fetchCached(key, cache: cache)
        #expect(bytes == payload)
        let onDisk = await cache.data(for: key)
        #expect(onDisk == payload, "downloaded bytes must be persisted to cache")
    }

    @Test func fetchCachedReturnsNilOnNetworkFailure() async {
        let cacheRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MDT-symserver-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let cache = SymbolCache(root: cacheRoot)

        StubURLProtocol.setHandler(forHost: "msdl.test"){ _ in
            (HTTPURLResponse(url: Self.testBase, statusCode: 503, httpVersion: nil, headerFields: nil)!, Data())
        }
        defer { StubURLProtocol.reset(host: "msdl.test") }
        let server = SymbolServer(baseURL: Self.testBase, urlSession: StubURLProtocol.session())

        let bytes = await server.fetchCached(validKey(), cache: cache)
        #expect(bytes == nil, "fetchCached must swallow errors and return nil")
    }
}

// Test-only setter for SymbolServer.isEnabled. The production API
// dropped setEnabled; tests still need an actor-isolated mutation
// helper because Swift won't let an actor's property be assigned from
// outside without a method (the property is `var`, not `nonisolated`,
// and direct assignment via the `await` keyword on a property setter
// requires a setter to exist).
private extension SymbolServer {
    func setEnabledForTest(_ value: Bool) {
        self.isEnabled = value
    }
}
