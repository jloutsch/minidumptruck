import Foundation
import Testing
@testable import MiniDumpTruckCore

@Suite("UnwindInfo parsing")
struct UnwindInfoTests {

    @Test func parsesMinimalHeaderWithZeroCodes() throws {
        // Version 1, no flags, 8-byte prologue, 0 codes.
        let bytes = Data([
            0x01,  // version=1, flags=0
            0x08,  // sizeOfProlog=8
            0x00,  // countOfCodes=0
            0x00,  // FrameRegister=0, FrameOffset=0
        ])
        let info = try #require(UnwindInfo(from: bytes, at: 0))
        #expect(info.version == 1)
        #expect(info.flags.rawValue == 0)
        #expect(info.sizeOfProlog == 8)
        #expect(info.countOfCodes == 0)
        #expect(info.codes.isEmpty)
        #expect(info.chainedFunction == nil)
    }

    @Test func parsesPushNonvolOpcode() throws {
        // version=1, prolog=2, 1 code, no frame register.
        // Opcode: codeOffset=2, op=pushNonvol (0), opInfo=5 (RBP).
        let bytes = Data([
            0x01,        // version=1, flags=0
            0x02,        // sizeOfProlog
            0x01,        // countOfCodes
            0x00,        // FrameRegister=0
            0x02,        // codeOffset = 2
            0x50,        // opInfo=5 (high nibble) | op=0 (low nibble)
        ])
        let info = try #require(UnwindInfo(from: bytes, at: 0))
        #expect(info.codes.count == 1)
        #expect(info.codes[0].codeOffset == 2)
        #expect(info.codes[0].unwindOp == UnwindOpCode.pushNonvol.rawValue)
        #expect(info.codes[0].opInfo == 5)  // RBP
    }

    @Test func rejectsVersionOutsideOneTwo() {
        // version=3 is invalid (only 1 and 2 are defined).
        let bytes = Data([0x03, 0, 0, 0])
        #expect(UnwindInfo(from: bytes, at: 0) == nil)
    }

    @Test func rejectsTruncatedHeader() {
        let bytes = Data([0x01, 0x02])  // only 2 bytes
        #expect(UnwindInfo(from: bytes, at: 0) == nil)
    }

    @Test func rejectsCountOfCodesPastBufferEnd() {
        // version=1, countOfCodes=5 but only header + 4 bytes follow
        // (1 code = 2 bytes; 5 codes needs 10 bytes, we have 4).
        let bytes = Data([0x01, 0x10, 0x05, 0x00, 0xAA, 0xBB, 0xCC, 0xDD])
        #expect(UnwindInfo(from: bytes, at: 0) == nil)
    }

    @Test func chainInfoFlagAttachesChainedRuntimeFunction() throws {
        // version=1, flags=chainInfo (0x4), 0 codes, then a chained
        // RUNTIME_FUNCTION at offset 4 (no padding needed since
        // codeCount=0 ends already at 4-byte boundary).
        var bytes = Data([
            0x01 | (0x04 << 3),  // version=1, flags=chainInfo
            0x00,                // prolog
            0x00,                // count
            0x00,                // framereg
        ])
        // Chained RUNTIME_FUNCTION: begin=0x2000, end=0x2100, unwind=0x3000
        bytes.append(Data([0x00, 0x20, 0x00, 0x00]))
        bytes.append(Data([0x00, 0x21, 0x00, 0x00]))
        bytes.append(Data([0x00, 0x30, 0x00, 0x00]))

        let info = try #require(UnwindInfo(from: bytes, at: 0))
        #expect(info.flags.contains(.chainInfo))
        #expect(info.chainedFunction?.beginRVA == 0x2000)
        #expect(info.chainedFunction?.endRVA == 0x2100)
        #expect(info.chainedFunction?.unwindInfoRVA == 0x3000)
    }

    @Test func chainInfoFlagPadsCodeArrayToFourBytes() throws {
        // version=1, flags=chainInfo, 1 opcode = 2 bytes. The code
        // array ends at offset 6, but the chained record must start
        // at a 4-byte-aligned offset = 8.
        var bytes = Data([
            0x01 | (0x04 << 3),  // chainInfo
            0x02,                // prolog
            0x01,                // 1 code
            0x00,                // framereg
            0x02,                // code: codeOffset=2
            0x50,                // op=pushNonvol, info=5
            0x00, 0x00,          // padding to 4-byte boundary
        ])
        bytes.append(Data([0xAA, 0xBB, 0xCC, 0xDD]))   // begin
        bytes.append(Data([0xEE, 0xFF, 0x00, 0x01]))   // end
        bytes.append(Data([0x11, 0x22, 0x33, 0x44]))   // unwind

        let info = try #require(UnwindInfo(from: bytes, at: 0))
        #expect(info.codes.count == 1)
        #expect(info.chainedFunction?.beginRVA == 0xDDCCBBAA)
    }

    @Test func parsingFromDataSliceWorks() throws {
        // Verify the slice-safe readUInt8 path: build a buffer with a
        // 32-byte prefix and parse from a slice starting past it.
        // A bug that used `data[0]` instead of slice-aware indexing
        // would trap here because the slice's startIndex is 32, not 0.
        var bytes = Data(repeating: 0xCC, count: 32)
        bytes.append(Data([0x01, 0x08, 0x00, 0x00]))   // valid header
        let slice = bytes.subdata(in: 32..<36)
        let info = try #require(UnwindInfo(from: slice, at: 0))
        #expect(info.version == 1)
        #expect(info.sizeOfProlog == 8)
    }
}
