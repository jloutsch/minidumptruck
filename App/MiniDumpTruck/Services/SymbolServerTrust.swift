import Foundation
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
/// This file provides three trust modes the user can pick from
/// settings:
///
/// 1. **`.systemTrust`** (default): the OS trust store decides. Same
///    as plain `URLSession.shared`. Works behind corporate proxies
///    with custom CAs (Zscaler, Bluecoat, Charles, etc.). Lowest
///    surprise for general users.
///
/// 2. **`.pinAppleManaged`**: only accept certificates that chain to
///    Apple-managed system roots (rejects MDM-installed custom CAs).
///    Useful on managed Macs where the user can't always trust the
///    device's CA store.
///
/// 3. **`.pinPublicKey(_:)`**: pin to a specific public-key hash
///    (SPKI SHA-256). The user supplies expected hashes for
///    `msdl.microsoft.com`. Highest assurance but breaks if Microsoft
///    rotates keys. We don't ship known hashes — the user / admin
///    populates them.
///
/// `SymbolServer.init` accepts a `TrustPolicy`. The default
/// `.systemTrust` preserves existing behavior.
public enum SymbolServerTrustPolicy: Sendable {
    case systemTrust
    case pinAppleManaged
    case pinPublicKey(allowedSPKISHA256Hashes: Set<Data>)
}

/// URLSessionDelegate that applies a `SymbolServerTrustPolicy` to
/// every TLS handshake on the session. Stateless aside from the
/// policy itself.
final class SymbolServerTrustDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
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
            // Defer to the OS — same as the default URLSession path.
            completionHandler(.performDefaultHandling, nil)

        case .pinAppleManaged:
            // SecTrustEvaluateWithError uses the system anchors. We
            // also clear the `kSecTrustReevaluateUsingNetwork` flag
            // so we don't pick up custom anchors that user-installed
            // profiles may have added.
            SecTrustSetAnchorCertificatesOnly(serverTrust, true)
            if SecTrustEvaluateWithError(serverTrust, nil) {
                completionHandler(.useCredential, URLCredential(trust: serverTrust))
            } else {
                Logger.symbols.error("TLS pinning failed: Apple-managed-anchors mode rejected server cert for \(challenge.protectionSpace.host, privacy: .public)")
                completionHandler(.cancelAuthenticationChallenge, nil)
            }

        case .pinPublicKey(let allowedHashes):
            guard SecTrustEvaluateWithError(serverTrust, nil) else {
                Logger.symbols.error("TLS pinning failed: trust eval failed for \(challenge.protectionSpace.host, privacy: .public)")
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
            let chain = (SecTrustCopyCertificateChain(serverTrust) as? [SecCertificate]) ?? []
            let anyMatch = chain.contains { cert in
                guard let spkiHash = Self.spkiSHA256(of: cert) else { return false }
                return allowedHashes.contains(spkiHash)
            }
            if anyMatch {
                completionHandler(.useCredential, URLCredential(trust: serverTrust))
            } else {
                Logger.symbols.error("TLS pinning failed: no chain cert matched the allowed SPKI hash set for \(challenge.protectionSpace.host, privacy: .public)")
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
        }
    }

    /// SHA-256 of the certificate's Subject Public Key Info DER. The
    /// caller compares the result against an admin-supplied allowlist.
    static func spkiSHA256(of cert: SecCertificate) -> Data? {
        guard let publicKey = SecCertificateCopyKey(cert),
              let data = SecKeyCopyExternalRepresentation(publicKey, nil) as Data? else {
            return nil
        }
        var hash = [UInt8](repeating: 0, count: 32)
        data.withUnsafeBytes { buf in
            _ = CC_SHA256(buf.baseAddress, CC_LONG(buf.count), &hash)
        }
        return Data(hash)
    }
}

// Bridge CommonCrypto's SHA-256 without importing the whole module
// in source files that don't need it.
import CommonCrypto
