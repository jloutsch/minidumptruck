import Foundation

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
    /// avoid network egress.
    public var isEnabled: Bool = true

    public init(baseURL: URL = SymbolServer.microsoftPublicURL,
                urlSession: URLSession = .shared) {
        self.baseURL = baseURL
        self.urlSession = urlSession
    }

    public func setEnabled(_ value: Bool) {
        self.isEnabled = value
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
        guard isEnabled else { throw FetchError.offline }
        guard let url = url(for: key) else { throw FetchError.malformedURL }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await urlSession.data(from: url)
        } catch {
            // Wrap so callers can pattern-match on FetchError without
            // caring about URLSession's specific error types.
            throw FetchError.networkFailure(error as any Error & Sendable)
        }

        guard let http = response as? HTTPURLResponse else {
            throw FetchError.httpError(0)
        }
        switch http.statusCode {
        case 200:
            return data
        case 404:
            throw FetchError.notFound
        default:
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
            return nil
        }
    }
}
