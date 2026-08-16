import Foundation
import Testing
@testable import MiniDumpTruckCore

@Suite("SymbolServer TLS trust policy")
struct SymbolServerTrustTests {

    @Test func systemTrustSessionHasNoDelegate() {
        let session = SymbolServer.makeSession(trustPolicy: .systemTrust)
        #expect(session.delegate == nil,
                ".systemTrust must not allocate a SymbolServerTrustDelegate")
    }

    // Darwin-only: without the Security framework `makeSession`
    // refuses a pinning policy outright (a `preconditionFailure`, which
    // would abort the whole test executable rather than fail one test),
    // so there is no session to inspect on those platforms. Do not
    // restore this test unconditionally.
    #if canImport(Security)
    @Test func pinCertificateSessionHasDelegate() {
        let session = SymbolServer.makeSession(
            trustPolicy: .pinCertificateSHA256(allowedHashes: [Data(repeating: 0xAB, count: 32)])
        )
        guard let delegate = session.delegate as? SymbolServerTrustDelegate else {
            Issue.record("expected SymbolServerTrustDelegate, got \(String(describing: session.delegate))")
            return
        }
        if case .pinCertificateSHA256(let hashes) = delegate.policy {
            #expect(hashes.contains(Data(repeating: 0xAB, count: 32)))
        } else {
            Issue.record("delegate's policy lost the pinCertificateSHA256 associated value")
        }
    }
    #endif

    @Test func sessionHasConfiguredTimeouts() {
        let session = SymbolServer.makeSession(trustPolicy: .systemTrust)
        #expect(session.configuration.timeoutIntervalForRequest == 15)
        #expect(session.configuration.timeoutIntervalForResource == 30)
        #expect(session.configuration.waitsForConnectivity == false)
    }

    @Test func emptyAllowedHashesIsVacuous() {
        // A pinning policy with no allowed hashes would reject every
        // TLS handshake. The policy must report itself vacuous so
        // makeSession can refuse it instead of silently disabling
        // every symbol fetch.
        let bad: SymbolServerTrustPolicy = .pinCertificateSHA256(allowedHashes: [])
        #expect(bad.isVacuous == true)

        let good: SymbolServerTrustPolicy = .pinCertificateSHA256(
            allowedHashes: [Data(repeating: 0x42, count: 32)]
        )
        #expect(good.isVacuous == false)

        #expect(SymbolServerTrustPolicy.systemTrust.isVacuous == false)
    }

    @Test func defaultPolicyIsSystemTrust() {
        // Pin the default — callers should be able to say `.default`
        // without depending on the exact case name. A refactor that
        // changes the default to a pinning mode would break this test.
        if case .systemTrust = SymbolServerTrustPolicy.default {
            // expected
        } else {
            Issue.record("default policy must remain .systemTrust")
        }
    }

    // MARK: - Direct delegate invocation
    //
    // SecTrust handshakes can't easily be faked in a unit test, but
    // we can still pin the delegate's logic by driving the
    // certificate-SHA256 helper against a known cert and verifying
    // its outputs.

    // MARK: - SHA-256 helper
    //
    // Materializing a valid SecCertificate requires real X.509 DER
    // bytes, which would mean shipping a cert fixture file. Instead
    // we test the underlying SHA-256 helper directly with known
    // inputs and known outputs — the wrapper that pulls DER from
    // SecCertificate is one line and uses well-tested Apple APIs.

    @Test func sha256HelperMatchesKnownVector() {
        // Empty input: SHA-256 of "" =
        //   e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
        let expected = Data([
            0xe3, 0xb0, 0xc4, 0x42, 0x98, 0xfc, 0x1c, 0x14,
            0x9a, 0xfb, 0xf4, 0xc8, 0x99, 0x6f, 0xb9, 0x24,
            0x27, 0xae, 0x41, 0xe4, 0x64, 0x9b, 0x93, 0x4c,
            0xa4, 0x95, 0x99, 0x1b, 0x78, 0x52, 0xb8, 0x55,
        ])
        #expect(SymbolServerTrustDelegate.sha256(Data()) == expected)
    }

    @Test func sha256HelperMatchesKnownVectorForNonEmptyInput() {
        // SHA-256 of "abc" =
        //   ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
        let expected = Data([
            0xba, 0x78, 0x16, 0xbf, 0x8f, 0x01, 0xcf, 0xea,
            0x41, 0x41, 0x40, 0xde, 0x5d, 0xae, 0x22, 0x23,
            0xb0, 0x03, 0x61, 0xa3, 0x96, 0x17, 0x7a, 0x9c,
            0xb4, 0x10, 0xff, 0x61, 0xf2, 0x00, 0x15, 0xad,
        ])
        #expect(SymbolServerTrustDelegate.sha256(Data("abc".utf8)) == expected)
    }

    @Test func sha256HelperProducesDistinctHashesForDistinctInputs() {
        let a = SymbolServerTrustDelegate.sha256(Data("hello".utf8))
        let b = SymbolServerTrustDelegate.sha256(Data("world".utf8))
        #expect(a != b)
        #expect(a.count == 32)
        #expect(b.count == 32)
    }
}
