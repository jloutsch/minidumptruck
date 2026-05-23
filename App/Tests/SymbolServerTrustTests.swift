import Foundation
import Testing
@testable import MiniDumpTruckCore

/// Most TLS pinning behavior can't be exercised in a unit test —
/// `SecTrustEvaluateWithError` needs a real cert chain bound to a
/// network connection. These tests pin the cheap properties: the
/// delegate is wired correctly, the policy is captured, and the
/// systemTrust fast path doesn't allocate a delegate.
@Suite("SymbolServer TLS trust policy")
struct SymbolServerTrustTests {

    @Test func systemTrustSessionHasNoDelegate() {
        let session = SymbolServer.makeSession(trustPolicy: .systemTrust)
        #expect(session.delegate == nil,
                ".systemTrust must not allocate a SymbolServerTrustDelegate")
    }

    @Test func pinAppleManagedSessionHasDelegate() {
        let session = SymbolServer.makeSession(trustPolicy: .pinAppleManaged)
        #expect(session.delegate is SymbolServerTrustDelegate,
                "non-systemTrust mode must attach the trust delegate")
    }

    @Test func pinPublicKeySessionHasDelegate() {
        let session = SymbolServer.makeSession(
            trustPolicy: .pinPublicKey(allowedSPKISHA256Hashes: [Data(repeating: 0xAB, count: 32)])
        )
        guard let delegate = session.delegate as? SymbolServerTrustDelegate else {
            Issue.record("expected SymbolServerTrustDelegate, got \(String(describing: session.delegate))")
            return
        }
        // Verify the policy round-tripped.
        if case .pinPublicKey(let hashes) = delegate.policy {
            #expect(hashes.contains(Data(repeating: 0xAB, count: 32)))
        } else {
            Issue.record("delegate's policy lost the pinPublicKey associated value")
        }
    }

    @Test func sessionHasConfiguredTimeouts() {
        let session = SymbolServer.makeSession(trustPolicy: .systemTrust)
        #expect(session.configuration.timeoutIntervalForRequest == 15)
        #expect(session.configuration.timeoutIntervalForResource == 30)
        #expect(session.configuration.waitsForConnectivity == false)
    }
}
