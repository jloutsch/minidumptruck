import Foundation
import Testing
@testable import MiniDumpTruckCore

/// Lock the `ThreadContext` Codable schema. The enum uses a custom
/// `arch` discriminator + `payload` envelope (not the auto-synthesized
/// Swift default), so these tests pin both the encoded shape and the
/// round-trip behavior. A future refactor that drops the discriminator
/// or reverts to default Codable would fail here before any stored
/// document silently broke.
@Suite("ThreadContext Codable round-trip")
struct ThreadContextCodableTests {

    @Test func amd64ContextRoundTripsThroughJSON() throws {
        let original: ThreadContext = makeZeroContext()
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ThreadContext.self, from: encoded)
        #expect(decoded == original,
                "AMD64 ThreadContext must round-trip through JSONEncoder/Decoder")
    }

    @Test func arm64ContextRoundTripsThroughJSON() throws {
        let original: ThreadContext = makeZeroARM64Context()
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ThreadContext.self, from: encoded)
        #expect(decoded == original,
                "ARM64 ThreadContext must round-trip through JSONEncoder/Decoder")
    }

    @Test func amd64AndARM64AreNotEqualAcrossCases() {
        let amd: ThreadContext = makeZeroContext()
        let arm: ThreadContext = makeZeroARM64Context()
        #expect(amd != arm,
                "different enum cases must compare unequal even when zero-initialized")
    }

    @Test func populatedARM64ContextRoundTripsAllFields() throws {
        // Populate every relevant field with a unique value so a future
        // Codable regression that drops a CodingKey (e.g. `vRegs` from
        // ARM64Context, or `xmm15` from AMD64Context) fails this test.
        // Zero-initialized round-trips wouldn't catch dropped Optionals
        // — the encoded form omits nil-valued Optionals and the
        // decoded form re-defaults them to nil, so the values match.
        var data = Data(repeating: 0, count: ARM64Context.size)
        data.writeLEUInt32(0x4, at: 0)             // contextFlags: FP-state set
        data.writeLEUInt32(0x4000_0000, at: 4)     // cpsr: Z flag
        for i in 0..<31 {
            data.writeLEUInt64(0xA000_0000_0000_0000 | UInt64(i),
                               at: 8 + i * 8)
        }
        data.writeLEUInt64(0x1234_5678_9ABC_DEF0, at: 256)   // sp
        data.writeLEUInt64(0xFEDC_BA98_7654_3210, at: 264)   // pc
        for i in 0..<32 {
            let lo: UInt64 = 0xC000_0000_0000_0000 | UInt64(i)
            let hi: UInt64 = 0xD000_0000_0000_0000 | UInt64(i)
            data.writeLEUInt64(lo, at: 272 + i * 16)
            data.writeLEUInt64(hi, at: 272 + i * 16 + 8)
        }
        data.writeLEUInt32(0x1234_5678, at: 784)
        data.writeLEUInt32(0x9ABC_DEF0, at: 788)
        let arm = ARM64Context(from: data, at: 0)!
        let original = ThreadContext.arm64(arm)

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ThreadContext.self, from: encoded)

        #expect(decoded == original,
                "populated ARM64 context must round-trip with all 31 X-regs, 32 V-regs, and FP control regs intact")
    }

    @Test func encodedJSONHasArchDiscriminator() throws {
        // Pin the explicit schema. If someone refactors ThreadContext's
        // Codable impl back to auto-synthesized, this test detects the
        // schema break before stored documents start failing to decode.
        let amd = makeZeroContext()
        let encodedAMD = try JSONEncoder().encode(amd)
        let jsonAMD = try JSONSerialization.jsonObject(with: encodedAMD) as? [String: Any]
        #expect(jsonAMD?["arch"] as? String == "amd64",
                "AMD64 thread context must serialize with an `arch: amd64` discriminator")
        #expect(jsonAMD?["payload"] != nil,
                "AMD64 thread context must carry payload under `payload` key")

        let arm = makeZeroARM64Context()
        let encodedARM = try JSONEncoder().encode(arm)
        let jsonARM = try JSONSerialization.jsonObject(with: encodedARM) as? [String: Any]
        #expect(jsonARM?["arch"] as? String == "arm64")
        #expect(jsonARM?["payload"] != nil)
    }

    @Test func decodesUnknownArchitectureThrows() throws {
        // A document written by a future version with a third arch
        // ("x86") must fail decode cleanly rather than silently
        // mis-classifying.
        let json = #"{"arch":"x86","payload":{}}"#.data(using: .utf8)!
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(ThreadContext.self, from: json)
        }
    }
}
