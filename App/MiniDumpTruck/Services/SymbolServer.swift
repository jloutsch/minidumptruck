import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Fetches PDBs from a Microsoft symbol server (default: msdl.microsoft.com).
///
/// URL scheme: `<base>/<pdb-name>/<GUID><AGE>/<pdb-name>`. MSDL is
/// public and unauthenticated. Some older PDBs are also served as
/// CAB-compressed variants with the last filename character replaced
/// by underscore (`ntdll.pd_`); for the slice-2 scope we attempt the
/// uncompressed URL only and surface a clear failure for the rest.
///
/// Network failures, 404s, and timeouts are non-fatal — the caller
/// gracefully degrades to module+offset display. Slice 2's wedge user
/// (Mac support engineer with intermittent network access) needs the
/// fetch to be best-effort, never a blocker.
public actor SymbolServer {
    public static let microsoftPublicURL = URL(string: "https://msdl.microsoft.com/download/symbols")!

    public enum FetchError: Error, Sendable {
        case notFound          // 404 — PDB not on this server
        case networkFailure(any Error & Sendable)
        case httpError(Int)    // any non-200 non-404
        case malformedURL
        case offline           // request blocked by `isEnabled = false`
    }

    private let baseURL: URL
    private let urlSession: URLSession

    /// Toggle: when false, all `fetch` calls return `.offline`. Users
    /// can disable auto-download in app settings; tests can disable to
    /// avoid network egress. Assign through the actor:
    /// `await server.isEnabled = false`.
    public var isEnabled: Bool = true

    /// Default URLSession with per-request and overall resource
    /// timeouts. A slow-loris MitM (or a degraded MSDL) shouldn't be
    /// able to keep all 8 concurrent fetch slots stalled for minutes.
    /// Trust evaluation uses `.systemTrust` — matches the OS default.
    private static let defaultSession: URLSession = makeSession(trustPolicy: .systemTrust)

    /// Build a URLSession with a TLS trust policy applied to every
    /// handshake. See `SymbolServerTrustPolicy` for the threat model
    /// and the available modes.
    ///
    /// Refuses to build a session for a `.isVacuous` policy
    /// (e.g. `.pinCertificateSHA256(allowedHashes: [])`) so a
    /// misconfigured admin sees the bug at session creation rather
    /// than as "all symbol fetches mysteriously fail."
    public static func makeSession(trustPolicy: SymbolServerTrustPolicy) -> URLSession {
        precondition(!trustPolicy.isVacuous,
                     "SymbolServerTrustPolicy must allow at least one cert; received an empty allowedHashes set which would reject every TLS handshake.")
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        // Deliberately no waits-for-connectivity assignment here: fail-fast
        // (not waiting) is already the Darwin default, and on Linux the
        // property is get-only in swift-corelibs-foundation, so assigning it
        // does not compile there. The timeouts above govern slow-network
        // behavior; the fail-fast contract is asserted by
        // `sessionHasConfiguredTimeouts`.
        if case .systemTrust = trustPolicy {
            // No delegate needed — saves a SessionDelegate instance.
            return URLSession(configuration: config)
        }
        let delegate = SymbolServerTrustDelegate(policy: trustPolicy)
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    public init(baseURL: URL = SymbolServer.microsoftPublicURL,
                urlSession: URLSession? = nil) {
        self.baseURL = baseURL
        self.urlSession = urlSession ?? SymbolServer.defaultSession
    }

    /// Build the canonical MSDL URL for a PDB identity. Public for
    /// tests + diagnostic logging.
    public nonisolated func url(for key: PDBIdentity) -> URL? {
        // `appendingPathComponent` is path-segment-safe (URL-encodes
        // special characters). PDB names should be plain ASCII but
        // we don't want to assume.
        baseURL
            .appendingPathComponent(key.pdbName)
            .appendingPathComponent(key.cacheKey)
            .appendingPathComponent(key.pdbName)
    }

    /// Download PDB bytes for the given identity. Throws `FetchError`
    /// on any failure; the caller should treat all failures as
    /// "no symbols, degrade gracefully" rather than user-visible
    /// errors.
    public func fetch(_ key: PDBIdentity) async throws -> Data {
        guard isEnabled else {
            SymbolLog.shared.info("server disabled, skipping fetch \(key.pdbName)")
            throw FetchError.offline
        }
        guard let url = url(for: key) else { throw FetchError.malformedURL }

        SymbolLog.shared.info("fetching \(key.pdbName) from \(url.host ?? "?")")
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await urlSession.data(from: url)
        } catch {
            SymbolLog.shared.error("network failure for \(key.pdbName): \(ErrorSanitization.reason(for: error))")
            throw FetchError.networkFailure(error as any Error & Sendable)
        }

        guard let http = response as? HTTPURLResponse else {
            SymbolLog.shared.error("non-HTTP response for \(key.pdbName)")
            throw FetchError.httpError(0)
        }
        switch http.statusCode {
        case 200:
            SymbolLog.shared.info("fetched \(key.pdbName) (\(data.count) bytes)")
            return data
        case 404:
            SymbolLog.shared.notice("MSDL 404 for \(key.pdbName) — PDB not available on this server")
            throw FetchError.notFound
        default:
            SymbolLog.shared.error("HTTP \(http.statusCode) for \(key.pdbName)")
            throw FetchError.httpError(http.statusCode)
        }
    }

    /// Fetch through a cache: cache hit returns immediately, miss
    /// downloads and stores. Returns nil on any failure so callers
    /// can degrade.
    public func fetchCached(_ key: PDBIdentity, cache: SymbolCache) async -> Data? {
        if let cached = await cache.data(for: key) {
            return cached
        }
        do {
            let data = try await fetch(key)
            try? await cache.store(data, for: key)
            return data
        } catch {
            // fetch() already logged the specific reason; the caller
            // just sees nil and degrades to module+offset.
            return nil
        }
    }
}
