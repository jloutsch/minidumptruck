import Foundation
import Testing
@testable import MiniDumpTruckCore

private func mockModule(name: String, base: UInt64, size: UInt32 = 0x10000) -> ModuleInfo {
    var data = Data()
    data.append(contentsOf: withUnsafeBytes(of: base.littleEndian) { Array($0) })
    data.append(contentsOf: withUnsafeBytes(of: size.littleEndian) { Array($0) })
    data.append(contentsOf: [UInt8](repeating: 0, count: ModuleInfo.size - 12))
    var m = ModuleInfo(from: data, at: 0)!
    m.setName(name)
    return m
}

@Suite("Symbol Display")
struct SymbolDisplayTests {
    @Test func displayPrefersSymbolWhenPresent() {
        let module = mockModule(name: "ntdll.dll", base: 0x7FF800000000)
        let frame = StackFrame(
            address: 0x7FF800009A3C4,
            module: module,
            offsetInModule: 0x9A3C4,
            symbol: ResolvedSymbol(function: "NtWaitForSingleObject", offsetInFunction: 0x14),
            frameType: .returnAddress,
            confidence: .medium
        )
        #expect(frame.displayAddress == "ntdll.dll!NtWaitForSingleObject+0x14")
    }

    @Test func displayFallsBackToModuleOffset() {
        let module = mockModule(name: "app.exe", base: 0x140000000)
        let frame = StackFrame(
            address: 0x140004A1C,
            module: module,
            offsetInModule: 0x4A1C,
            symbol: nil,
            frameType: .returnAddress,
            confidence: .low
        )
        #expect(frame.displayAddress == "app.exe+0x4a1c")
    }

    @Test func displayFallsBackToHexWithoutModule() {
        let frame = StackFrame(
            address: 0x7FF812345678,
            module: nil,
            offsetInModule: nil,
            symbol: nil,
            frameType: .returnAddress,
            confidence: .low
        )
        #expect(frame.displayAddress == "0x00007FF812345678")
    }

    @Test func defaultSymbolIsNilForExistingCallSites() {
        // Existing 5-arg initializer must still compile and default symbol to nil.
        let frame = StackFrame(
            address: 0x1000, module: nil, offsetInModule: nil,
            frameType: .instructionPointer, confidence: .high
        )
        #expect(frame.symbol == nil)
    }

    @Test func symbolRoundTripsThroughCodable() throws {
        let original = ResolvedSymbol(function: "Foo", offsetInFunction: 0x10)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ResolvedSymbol.self, from: data)
        #expect(decoded.function == "Foo")
        #expect(decoded.offsetInFunction == 0x10)
    }
}
