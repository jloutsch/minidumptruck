import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Crypto
import os

/// TLS server-trust evaluation hooks for `SymbolServer`.
///
/// Threat model: a device with a malicious-CA-signed certificate for
/// `msdl.microsoft.com` (compromised CA, evil MDM, debugging proxy)
/// could MITM symbol downloads and serve attacker-controlled PDB
/// bytes. Our PDB parser is hardened against malformed input (bounds
/// checks, size caps, malformed-input tests), but a future parser bug
/// would become a remote code-execution primitive over MitM.
///
/// Two user-selectable trust modes:
///
/// 1. **`.systemTrust`** (default): the OS trust store decides. Same
///    as plain `URLSession.shared`. Works behind corporate proxies
///    with custom CAs (Zscaler, Bluecoat, Charles, etc.). Lowest
///    surprise for general users.
///
/// 2. **`.pinCertificateSHA256(_:)`**: pin to a specific certificate
///    by SHA-256 of its DER encoding. The admin populates the
///    allowlist with `openssl x509 -in cert.pem -outform DER |
///    openssl dgst -sha256` (or `shasum -a 256 cert.der`). Highest
///    assurance but breaks if Microsoft rotates the certificate. We
///    don't ship known hashes — the user / admin populates them.
///
/// Notes on a previously-considered `.pinAppleManaged` mode:
/// Apple's public Security framework offers no clean API to
/// distinguish OS-shipped anchors from MDM/user-installed anchors.
/// `SecTrustSetAnchorCertificatesOnly(true)` without an explicit
/// anchor list rejects every certificate, which is the opposite of
/// the intended behavior. We removed the mode rather than ship
/// something that DoSes the feature.
///
/// SymbolServer.init accepts a `TrustPolicy`. The default
/// `.systemTrust` preserves existing behavior.
public enum SymbolServerTrustPolicy: Sendable {
    case systemTrust
    case pinCertificateSHA256(allowedHashes: Set<Data>)

    public static let `default`: SymbolServerTrustPolicy = .systemTrust

    /// True when the policy will reject every certificate. Used by
    /// `makeSession` to refuse a misconfigured policy at construction
    /// time so the user doesn't see a silently-broken feature.
    public var isVacuous: Bool {
        switch self {
        case .systemTrust: return false
        case .pinCertificateSHA256(let allowed): return allowed.isEmpty
        }
    }
}

/// URLSessionDelegate that applies a `SymbolServerTrustPolicy` to
/// every TLS handshake on the session.
final class SymbolServerTrustDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    // @unchecked Sendable is required because NSObject is not
    // Sendable. The stored `policy` is a Sendable value type, and
    // the delegate has no mutable state, so the conformance is sound.
    let policy: SymbolServerTrustPolicy

    init(policy: SymbolServerTrustPolicy) {
        self.policy = policy
        super.init()
    }

    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        switch policy {
        case .systemTrust:
            completionHandler(.performDefaultHandling, nil)

        case .pinCertificateSHA256(let allowedHashes):
            guard !allowedHashes.isEmpty else {
                // makeSession should have refused this configuration,
                // but log defensively in case a caller bypasses it.
                Logger.symbols.fault("TLS pinning misconfigured: empty allowedHashes — rejecting all certs")
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
            guard SecTrustEvaluateWithError(serverTrust, nil) else {
                Logger.symbols.error("TLS pinning: trust eval failed for \(challenge.protectionSpace.host, privacy: .public)")
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
            let chain = (SecTrustCopyCertificateChain(serverTrust) as? [SecCertificate]) ?? []
            let anyMatch = chain.contains { cert in
                guard let hash = SymbolServerTrustDelegate.certificateSHA256(cert) else { return false }
                return allowedHashes.contains(hash)
            }
            if anyMatch {
                completionHandler(.useCredential, URLCredential(trust: serverTrust))
            } else {
                Logger.symbols.error("TLS pinning: no chain cert matched the allowed cert-SHA256 set for \(challenge.protectionSpace.host, privacy: .public)")
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
        }
    }

    /// SHA-256 of the certificate's DER-encoded bytes (the format
    /// `openssl x509 -outform DER` produces). The caller compares
    /// the result against an admin-supplied allowlist.
    static func certificateSHA256(_ cert: SecCertificate) -> Data? {
        let der = SecCertificateCopyData(cert) as Data
        return der.isEmpty ? nil : sha256(der)
    }

    /// SHA-256 of arbitrary bytes. Split out from `certificateSHA256`
    /// so tests can pin the hashing logic against known inputs
    /// without needing to materialize a real `SecCertificate` (which
    /// requires valid X.509 DER).
    static func sha256(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }
}
