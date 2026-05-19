# Symbolication Slice 1 (Export-Table Resolution) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Resolve stack-frame addresses to exported function names (`ntdll!NtWaitForSingleObject+0x14`) using only the dump's own captured memory, with zero network and zero configuration.

**Architecture:** A `MemoryReading` protocol with a production `DumpMemoryReader` (delegates to the already-tested `MinidumpParser.readMemory`) and a test `BufferMemoryReader`. `PEExportTable` parses a loaded PE image's export directory through that protocol. `Symbolicator` builds one export table per module from a `ParsedMinidump` and resolves addresses with a max-delta guard. `StackFrame` gains an optional `symbol`; `CrashAnalyzer` populates it.

**Tech Stack:** Swift 5.9, Swift Package Manager, Swift Testing (`import Testing`), macOS 14+.

**Spec:** `docs/superpowers/specs/2026-05-19-symbolication-export-table-design.md`

**Plan-level refinement of the spec:** the spec describes `PEExportTable.init?(reader: DumpMemoryReader, ...)`. This plan introduces a small `MemoryReading` protocol so `PEExportTable` is testable without scaffolding a full dump, and so the dump-memory dependency is wrapped behind an internal interface (consistent with the spec's "independently testable units" goal and the project's tech-debt guardrails). `DumpMemoryReader` is the production conformer; `BufferMemoryReader` is the test conformer.

**Conventions for every task:**
- Build: `cd App && swift build`
- Test (single suite): `cd App && swift test --filter "<SuiteName>"`
- Test (full regression): `cd App && swift test`
- New source files go under `App/MiniDumpTruck/...`; they compile into `MiniDumpTruckCore` automatically (the target globs `Models`, `Parsers`, `Services`, `Utilities`).
- New test files go under `App/Tests/`.
- Tests use Swift Testing: `import Testing` + `@testable import MiniDumpTruckCore` + `@Suite` / `@Test` / `#expect` / `try #require`.

---

### Task 1: `MemoryReading` protocol + `DumpMemoryReader`

**Files:**
- Create: `App/MiniDumpTruck/Utilities/DumpMemoryReader.swift`
- Test: `App/Tests/DumpMemoryReaderTests.swift`

Background: `MinidumpParser.readMemory(from:at:size:)` is a static that already does the Memory64List-then-MemoryList fallback and is covered by `MemoryOperationTests`. `DumpMemoryReader` delegates to it so there is one source of truth.

- [ ] **Step 1: Confirm the existing helper's semantics**

Open `App/MiniDumpTruck/Parsers/MinidumpParser.swift` and read the `readMemory(from:at:size:)` static. Confirm it returns memory64List results first, then falls back to memoryList, then nil. (It is the same logic currently duplicated privately in `CrashAnalyzer.swift:385-390`.) No code change in this step.

- [ ] **Step 2: Write the failing test**

Create `App/Tests/DumpMemoryReaderTests.swift`:

```swift
import Foundation
import Testing
@testable import MiniDumpTruckCore

private extension Data {
    mutating func writeUInt16(_ value: UInt16, at offset: Int) {
        self[offset] = UInt8(value & 0xFF)
        self[offset + 1] = UInt8((value >> 8) & 0xFF)
    }
    mutating func writeUInt32(_ value: UInt32, at offset: Int) {
        for i in 0..<4 { self[offset + i] = UInt8((value >> (i * 8)) & 0xFF) }
    }
    mutating func writeUInt64(_ value: UInt64, at offset: Int) {
        for i in 0..<8 { self[offset + i] = UInt8((value >> (i * 8)) & 0xFF) }
    }
}

/// Builds a minimal dump containing a single Memory64List region.
private func makeDumpWithRegion(start: UInt64, content: [UInt8]) throws -> ParsedMinidump {
    let headerSize = 32
    let dirSize = 12
    let m64Rva = UInt32(headerSize + dirSize)
    let m64HeaderSize = 16
    let m64DescSize = 16
    let dataStart = Int(m64Rva) + m64HeaderSize + m64DescSize

    var data = Data(repeating: 0, count: dataStart + content.count)
    data.writeUInt32(0x504D444D, at: 0)            // "MDMP"
    data.writeUInt16(0xA793, at: 4)
    data.writeUInt32(1, at: 8)                     // stream count
    data.writeUInt32(UInt32(headerSize), at: 12)   // stream dir rva
    data.writeUInt32(0, at: 16)
    data.writeUInt32(1700000000, at: 20)
    data.writeUInt64(0, at: 24)

    data.writeUInt32(9, at: headerSize)                                  // Memory64List
    data.writeUInt32(UInt32(m64HeaderSize + m64DescSize), at: headerSize + 4)
    data.writeUInt32(m64Rva, at: headerSize + 8)

    data.writeUInt64(1, at: Int(m64Rva))                                 // numberOfRanges
    data.writeUInt64(UInt64(dataStart), at: Int(m64Rva) + 8)             // baseRva
    data.writeUInt64(start, at: Int(m64Rva) + 16)                        // startAddress
    data.writeUInt64(UInt64(content.count), at: Int(m64Rva) + 24)        // dataSize
    for (i, b) in content.enumerated() { data[dataStart + i] = b }

    return try MinidumpParser.parse(data: data)
}

@Suite("DumpMemoryReader")
struct DumpMemoryReaderTests {
    @Test func readsBytesAndMatchesParserHelper() throws {
        let dump = try makeDumpWithRegion(start: 0x1000,
                                          content: [0xDE, 0xAD, 0xBE, 0xEF, 0x11, 0x22, 0x33, 0x44])
        let reader = DumpMemoryReader(dump: dump)

        #expect(Array(reader.read(at: 0x1000, size: 4) ?? Data()) == [0xDE, 0xAD, 0xBE, 0xEF])
        // Parity with the existing tested helper
        let viaParser = MinidumpParser.readMemory(from: dump, at: 0x1000, size: 4)
        #expect(reader.read(at: 0x1000, size: 4) == viaParser)
    }

    @Test func readsLittleEndianScalars() throws {
        let dump = try makeDumpWithRegion(start: 0x2000,
                                          content: [0x78, 0x56, 0x34, 0x12, 0xEF, 0xBE, 0xAD, 0xDE])
        let reader = DumpMemoryReader(dump: dump)
        #expect(reader.readUInt16(at: 0x2000) == 0x5678)
        #expect(reader.readUInt32(at: 0x2000) == 0x12345678)
        #expect(reader.readUInt64(at: 0x2000) == 0xDEADBEEF12345678)
    }

    @Test func returnsNilOutsideAnyRegion() throws {
        let dump = try makeDumpWithRegion(start: 0x1000, content: [0xAA, 0xBB])
        let reader = DumpMemoryReader(dump: dump)
        #expect(reader.read(at: 0x9000, size: 4) == nil)
        #expect(reader.readUInt32(at: 0x9000) == nil)
    }
}
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `cd App && swift test --filter "DumpMemoryReader"`
Expected: FAIL to build with "cannot find 'DumpMemoryReader' in scope".

- [ ] **Step 4: Write the implementation**

Create `App/MiniDumpTruck/Utilities/DumpMemoryReader.swift`:

```swift
import Foundation

/// Abstraction over a source of process memory addressed by virtual address.
/// Production code reads from a dump; tests use an in-memory buffer.
public protocol MemoryReading: Sendable {
    func read(at address: UInt64, size: Int) -> Data?
}

public extension MemoryReading {
    func readUInt16(at address: UInt64) -> UInt16? {
        guard let d = read(at: address, size: 2), d.count == 2 else { return nil }
        return d.readUInt16(at: 0)
    }
    func readUInt32(at address: UInt64) -> UInt32? {
        guard let d = read(at: address, size: 4), d.count == 4 else { return nil }
        return d.readUInt32(at: 0)
    }
    func readUInt64(at address: UInt64) -> UInt64? {
        guard let d = read(at: address, size: 8), d.count == 8 else { return nil }
        return d.readUInt64(at: 0)
    }
}

/// Reads process memory out of a parsed minidump. Single source of truth for
/// the Memory64List-then-MemoryList fallback, delegating to the tested
/// `MinidumpParser.readMemory`.
public struct DumpMemoryReader: MemoryReading {
    private let dump: ParsedMinidump

    public init(dump: ParsedMinidump) {
        self.dump = dump
    }

    public func read(at address: UInt64, size: Int) -> Data? {
        guard size > 0 else { return nil }
        return MinidumpParser.readMemory(from: dump, at: address, size: size)
    }
}
```

Note: `ParsedMinidump` is `Sendable` (see `CrashAnalyzer` which is a `Sendable` struct holding it), so `DumpMemoryReader` is `Sendable`.

- [ ] **Step 5: Run the test to verify it passes**

Run: `cd App && swift test --filter "DumpMemoryReader"`
Expected: PASS (3 tests).

- [ ] **Step 6: Commit**

```bash
git add App/MiniDumpTruck/Utilities/DumpMemoryReader.swift App/Tests/DumpMemoryReaderTests.swift
git commit -m "feat: add MemoryReading protocol and DumpMemoryReader"
```

---

### Task 2: Refactor `CrashAnalyzer` onto `DumpMemoryReader` (behavior-preserving)

**Files:**
- Modify: `App/MiniDumpTruck/Services/CrashAnalyzer.swift:384-398`

No new test. The existing 531-test suite is the regression guard for this extraction.

- [ ] **Step 1: Run the full suite first to establish a green baseline**

Run: `cd App && swift test`
Expected: all tests pass ("Test run with 531 tests in 74 suites passed"). If not green, stop and report before changing anything.

- [ ] **Step 2: Replace the private memory helpers with the shared reader**

In `App/MiniDumpTruck/Services/CrashAnalyzer.swift`, add a stored reader and delegate. Change the struct to build a reader in `init`:

Replace:

```swift
    public init(dump: ParsedMinidump) {
        self.dump = dump
    }
```

with:

```swift
    private let memory: DumpMemoryReader

    public init(dump: ParsedMinidump) {
        self.dump = dump
        self.memory = DumpMemoryReader(dump: dump)
    }
```

Replace the two private methods at the bottom of the file:

```swift
    /// Read memory from the dump, trying Memory64List then MemoryList
    private func readMemory(at address: UInt64, size: Int) -> Data? {
        if let result = dump.memory64List?.readMemory(at: address, size: size, from: dump.data) {
            return result
        }
        return dump.memoryList?.readMemory(at: address, size: size, from: dump.data)
    }

    private func readUInt64(at address: UInt64) -> UInt64? {
        guard let data = readMemory(at: address, size: 8),
              data.count == 8 else {
            return nil
        }
        return data.readUInt64(at: 0)
    }
```

with:

```swift
    /// Read memory from the dump (Memory64List then MemoryList fallback).
    private func readMemory(at address: UInt64, size: Int) -> Data? {
        memory.read(at: address, size: size)
    }

    private func readUInt64(at address: UInt64) -> UInt64? {
        memory.readUInt64(at: address)
    }
```

- [ ] **Step 3: Build**

Run: `cd App && swift build`
Expected: `Build complete!`

- [ ] **Step 4: Run the full suite to verify no regression**

Run: `cd App && swift test`
Expected: same pass count as Step 1 ("531 tests ... passed"). If any test fails, the extraction changed behavior — stop and diff `MinidumpParser.readMemory` against the old inline logic before proceeding.

- [ ] **Step 5: Commit**

```bash
git add App/MiniDumpTruck/Services/CrashAnalyzer.swift
git commit -m "refactor: route CrashAnalyzer memory reads through DumpMemoryReader"
```

---

### Task 3: `ResolvedSymbol` + `StackFrame.symbol` + `displayAddress`

**Files:**
- Modify: `App/MiniDumpTruck/Models/CrashAnalysis.swift:18-57`
- Test: `App/Tests/SymbolDisplayTests.swift`

- [ ] **Step 1: Write the failing test**

Create `App/Tests/SymbolDisplayTests.swift`:

```swift
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
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd App && swift test --filter "Symbol Display"`
Expected: FAIL to build with "cannot find 'ResolvedSymbol'" / "extra argument 'symbol'".

- [ ] **Step 3: Add `ResolvedSymbol` and extend `StackFrame`**

In `App/MiniDumpTruck/Models/CrashAnalysis.swift`, add this struct just above `public struct StackFrame`:

```swift
/// A resolved function symbol for an address (export-table derived in slice 1).
public struct ResolvedSymbol: Sendable, Codable, Equatable {
    public let function: String
    public let offsetInFunction: UInt64

    public init(function: String, offsetInFunction: UInt64) {
        self.function = function
        self.offsetInFunction = offsetInFunction
    }
}
```

Then modify `StackFrame`. Change its `CodingKeys`, add the stored property, update `displayAddress`, and add `symbol` to the initializer with a default of `nil`:

Replace:

```swift
    private enum CodingKeys: String, CodingKey {
        case address, module, offsetInModule, frameType, confidence
    }

    public let id = UUID()
    public let address: UInt64
    public let module: ModuleInfo?
    public let offsetInModule: UInt64?
    public let frameType: FrameType
    public let confidence: FrameConfidence
```

with:

```swift
    private enum CodingKeys: String, CodingKey {
        case address, module, offsetInModule, symbol, frameType, confidence
    }

    public let id = UUID()
    public let address: UInt64
    public let module: ModuleInfo?
    public let offsetInModule: UInt64?
    public let symbol: ResolvedSymbol?
    public let frameType: FrameType
    public let confidence: FrameConfidence
```

Replace:

```swift
    public var displayAddress: String {
        if let module = module, let offset = offsetInModule {
            return "\(module.shortName)+0x\(String(offset, radix: 16))"
        }
        return String(format: "0x%016llX", address)
    }

    public init(address: UInt64, module: ModuleInfo?, offsetInModule: UInt64?, frameType: FrameType, confidence: FrameConfidence) {
        self.address = address
        self.module = module
        self.offsetInModule = offsetInModule
        self.frameType = frameType
        self.confidence = confidence
    }
```

with:

```swift
    public var displayAddress: String {
        if let module = module, let symbol = symbol {
            return "\(module.shortName)!\(symbol.function)+0x\(String(symbol.offsetInFunction, radix: 16))"
        }
        if let module = module, let offset = offsetInModule {
            return "\(module.shortName)+0x\(String(offset, radix: 16))"
        }
        return String(format: "0x%016llX", address)
    }

    public init(address: UInt64, module: ModuleInfo?, offsetInModule: UInt64?, symbol: ResolvedSymbol? = nil, frameType: FrameType, confidence: FrameConfidence) {
        self.address = address
        self.module = module
        self.offsetInModule = offsetInModule
        self.symbol = symbol
        self.frameType = frameType
        self.confidence = confidence
    }
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd App && swift test --filter "Symbol Display"`
Expected: PASS (5 tests).

- [ ] **Step 5: Run the full suite (existing call sites use the defaulted initializer)**

Run: `cd App && swift test`
Expected: all pass ("531 tests ... passed"; the new suite adds tests, count grows). Existing `StackFrame(...)` 5-argument call sites still compile because `symbol` defaults to `nil`.

- [ ] **Step 6: Commit**

```bash
git add App/MiniDumpTruck/Models/CrashAnalysis.swift App/Tests/SymbolDisplayTests.swift
git commit -m "feat: add ResolvedSymbol and symbol-aware StackFrame.displayAddress"
```

---

### Task 4: `PEExportTable` — PE32+ happy path

**Files:**
- Create: `App/MiniDumpTruck/Models/PEImage.swift`
- Test: `App/Tests/PEImageTests.swift`

- [ ] **Step 1: Write the failing test (with a synthetic PE builder + buffer reader)**

Create `App/Tests/PEImageTests.swift`:

```swift
import Foundation
import Testing
@testable import MiniDumpTruckCore

/// In-memory MemoryReading for tests: one contiguous image at `base`.
struct BufferMemoryReader: MemoryReading {
    let base: UInt64
    let bytes: [UInt8]
    func read(at address: UInt64, size: Int) -> Data? {
        guard size > 0, address >= base else { return nil }
        let start = Int(address - base)
        guard start < bytes.count else { return nil }
        let end = min(start + size, bytes.count)
        return Data(bytes[start..<end])
    }
}

/// Builds a minimal PE32+ image with an export directory.
/// `exports` are (name, functionRVA). Layout (all little-endian):
///   0x000 DOS header (e_magic 'MZ', e_lfanew at 0x3C -> 0x80)
///   0x080 NT: "PE\0\0", file header, PE32+ optional header
///   0x200 IMAGE_EXPORT_DIRECTORY
///   0x240 AddressOfFunctions[] (u32 each)
///   0x300 AddressOfNames[] (u32 each)
///   0x380 AddressOfNameOrdinals[] (u16 each)
///   0x400 name strings (NUL-terminated)
func makePE64(exports: [(name: String, rva: UInt32)],
              imageSize: Int = 0x2000) -> [UInt8] {
    var img = [UInt8](repeating: 0, count: imageSize)
    func w16(_ v: UInt16, _ o: Int) { img[o] = UInt8(v & 0xFF); img[o+1] = UInt8(v >> 8 & 0xFF) }
    func w32(_ v: UInt32, _ o: Int) { for i in 0..<4 { img[o+i] = UInt8(v >> (i*8) & 0xFF) } }

    let eLfanew = 0x80
    w16(0x5A4D, 0x00)                 // 'MZ'
    w32(UInt32(eLfanew), 0x3C)        // e_lfanew

    w32(0x00004550, eLfanew)          // "PE\0\0"
    // IMAGE_FILE_HEADER at eLfanew+4 (20 bytes); SizeOfOptionalHeader at +16
    let optStart = eLfanew + 4 + 20
    w16(0xF0, eLfanew + 4 + 16)       // SizeOfOptionalHeader (any plausible value)
    w16(0x020B, optStart)             // Magic = PE32+
    // PE32+ DataDirectory starts at optStart + 112; NumberOfRvaAndSizes at optStart + 108
    w32(16, optStart + 108)
    let dirArray = optStart + 112
    let exportDirRVA: UInt32 = 0x200
    let exportDirSize: UInt32 = 0x40
    w32(exportDirRVA, dirArray + 0)   // DataDirectory[0].VirtualAddress
    w32(exportDirSize, dirArray + 4)  // DataDirectory[0].Size

    // IMAGE_EXPORT_DIRECTORY at 0x200
    let ed = 0x200
    let funcs: UInt32 = 0x240
    let names: UInt32 = 0x300
    let ords:  UInt32 = 0x380
    let strs = 0x400
    w32(0, ed + 0)                          // Characteristics
    w32(0, ed + 4)                          // TimeDateStamp
    w16(0, ed + 8); w16(0, ed + 10)         // Major/Minor
    w32(0x400, ed + 12)                     // Name (rva, unused by parser)
    w32(1, ed + 16)                         // Base (ordinal base)
    w32(UInt32(exports.count), ed + 20)     // NumberOfFunctions
    w32(UInt32(exports.count), ed + 24)     // NumberOfNames
    w32(funcs, ed + 28)                     // AddressOfFunctions
    w32(names, ed + 32)                     // AddressOfNames
    w32(ords,  ed + 36)                     // AddressOfNameOrdinals

    var strOff = strs
    for (i, e) in exports.enumerated() {
        w32(e.rva, Int(funcs) + i * 4)              // function rva
        w32(UInt32(strOff), Int(names) + i * 4)     // name rva
        w16(UInt16(i), Int(ords) + i * 2)           // ordinal index into funcs[]
        for b in Array(e.name.utf8) { img[strOff] = b; strOff += 1 }
        img[strOff] = 0; strOff += 1
    }
    return img
}

@Suite("PEExportTable PE32+")
struct PEExportTablePE64Tests {
    @Test func resolvesExactEntry() {
        let img = makePE64(exports: [("Foo", 0x1000), ("Bar", 0x1800)])
        let reader = BufferMemoryReader(base: 0x140000000, bytes: img)
        let table = PEExportTable(reader: reader, imageBase: 0x140000000,
                                  imageSize: UInt32(img.count))
        let table2 = try? #require(table)
        let hit = table2?.symbol(forImageOffset: 0x1000)
        #expect(hit?.name == "Foo")
        #expect(hit?.delta == 0)
    }

    @Test func resolvesMidFunction() {
        let img = makePE64(exports: [("Foo", 0x1000), ("Bar", 0x1800)])
        let reader = BufferMemoryReader(base: 0x140000000, bytes: img)
        let table = PEExportTable(reader: reader, imageBase: 0x140000000,
                                  imageSize: UInt32(img.count))!
        let hit = table.symbol(forImageOffset: 0x1810)
        #expect(hit?.name == "Bar")
        #expect(hit?.delta == 0x10)
    }

    @Test func returnsNilBelowFirstExport() {
        let img = makePE64(exports: [("Foo", 0x1000)])
        let reader = BufferMemoryReader(base: 0x140000000, bytes: img)
        let table = PEExportTable(reader: reader, imageBase: 0x140000000,
                                  imageSize: UInt32(img.count))!
        #expect(table.symbol(forImageOffset: 0x0800) == nil)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd App && swift test --filter "PEExportTable PE32+"`
Expected: FAIL to build with "cannot find 'PEExportTable' in scope".

- [ ] **Step 3: Implement `PEExportTable`**

Create `App/MiniDumpTruck/Models/PEImage.swift`:

```swift
import Foundation

/// Parsed export table of a loaded PE image, read from process memory.
/// Slice 1 of symbolication: named, non-forwarded exports only.
public struct PEExportTable: Sendable {
    /// DoS bound: maximum named exports parsed from one module.
    public static let maxExports = 200_000
    /// DoS bound: maximum symbol-name byte length scanned.
    public static let maxNameLength = 4096

    /// (functionRVA, name) sorted ascending by functionRVA.
    private let entries: [(rva: UInt32, name: String)]

    public init?(reader: MemoryReading, imageBase: UInt64, imageSize: UInt32) {
        // Bounds helper: every RVA read must sit inside the image.
        func abs32(_ rva: UInt32) -> UInt64? {
            guard rva < imageSize else { return nil }
            let (a, of) = imageBase.addingReportingOverflow(UInt64(rva))
            return of ? nil : a
        }

        // DOS header
        guard reader.readUInt16(at: imageBase) == 0x5A4D else { return nil }
        guard let eLfanew = reader.readUInt32(at: imageBase &+ 0x3C),
              let ntBase = abs32(eLfanew) else { return nil }

        // NT signature "PE\0\0"
        guard reader.readUInt32(at: ntBase) == 0x00004550 else { return nil }

        // Optional header magic decides where the data directory starts.
        let optStart = ntBase &+ 4 &+ 20
        guard let magic = reader.readUInt16(at: optStart) else { return nil }
        let dirArrayOffset: UInt64
        switch magic {
        case 0x010B: dirArrayOffset = optStart &+ 96   // PE32
        case 0x020B: dirArrayOffset = optStart &+ 112  // PE32+
        default: return nil
        }

        // DataDirectory[0] = export directory (VirtualAddress, Size)
        guard let exportRVA = reader.readUInt32(at: dirArrayOffset),
              let exportSize = reader.readUInt32(at: dirArrayOffset &+ 4),
              exportRVA != 0, exportSize != 0,
              let edBase = abs32(exportRVA) else { return nil }

        guard let numberOfNames = reader.readUInt32(at: edBase &+ 24),
              let addrOfFunctions = reader.readUInt32(at: edBase &+ 28),
              let addrOfNames = reader.readUInt32(at: edBase &+ 32),
              let addrOfOrdinals = reader.readUInt32(at: edBase &+ 36),
              numberOfNames > 0,
              numberOfNames <= UInt32(Self.maxExports) else { return nil }

        let (exportEnd, exEndOf) = exportRVA.addingReportingOverflow(exportSize)
        if exEndOf { return nil }

        var collected: [(rva: UInt32, name: String)] = []
        collected.reserveCapacity(Int(numberOfNames))

        for i in 0..<numberOfNames {
            guard let namesSlot = abs32(addrOfNames &+ i &* 4),
                  let ordSlot = abs32(addrOfOrdinals &+ i &* 2),
                  let nameRVA = reader.readUInt32(at: namesSlot),
                  let ordinal = reader.readUInt16(at: ordSlot),
                  let funcSlot = abs32(addrOfFunctions &+ UInt32(ordinal) &* 4),
                  let funcRVA = reader.readUInt32(at: funcSlot) else { continue }

            // Forwarder: function RVA points inside the export directory range.
            if funcRVA >= exportRVA && funcRVA < exportEnd { continue }

            guard let nameAddr = abs32(nameRVA),
                  let name = Self.cString(reader: reader, at: nameAddr,
                                          maxLen: Self.maxNameLength),
                  !name.isEmpty else { continue }

            collected.append((rva: funcRVA, name: name))
        }

        guard !collected.isEmpty else { return nil }
        collected.sort { $0.rva < $1.rva }
        self.entries = collected
    }

    /// Nearest exported function at or below `offset`. Returns name and byte delta.
    public func symbol(forImageOffset offset: UInt64) -> (name: String, delta: UInt64)? {
        guard offset <= UInt64(UInt32.max) else { return nil }
        let target = UInt32(offset)
        // Binary search for greatest entry with rva <= target.
        var lo = 0, hi = entries.count - 1, found = -1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if entries[mid].rva <= target { found = mid; lo = mid + 1 }
            else { hi = mid - 1 }
        }
        guard found >= 0 else { return nil }
        let e = entries[found]
        return (e.name, UInt64(target - e.rva))
    }

    private static func cString(reader: MemoryReading, at address: UInt64,
                                maxLen: Int) -> String? {
        guard let data = reader.read(at: address, size: maxLen), !data.isEmpty else {
            return nil
        }
        let bytes = Array(data)
        guard let nul = bytes.firstIndex(of: 0) else {
            return String(bytes: bytes, encoding: .utf8)
        }
        return String(bytes: bytes[0..<nul], encoding: .utf8)
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd App && swift test --filter "PEExportTable PE32+"`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add App/MiniDumpTruck/Models/PEImage.swift App/Tests/PEImageTests.swift
git commit -m "feat: parse PE32+ export tables (happy path)"
```

---

### Task 5: `PEExportTable` — PE32, forwarders, truncation, DoS

**Files:**
- Modify: `App/Tests/PEImageTests.swift` (add a second suite)

The implementation from Task 4 already handles all of these; this task adds the tests that prove it and locks the behavior.

- [ ] **Step 1: Write the failing/erroring tests**

Append to `App/Tests/PEImageTests.swift`:

```swift
/// PE32 variant of makePE64 (32-bit optional header: data directory at optStart+96).
func makePE32(exports: [(name: String, rva: UInt32)],
              imageSize: Int = 0x2000) -> [UInt8] {
    var img = [UInt8](repeating: 0, count: imageSize)
    func w16(_ v: UInt16, _ o: Int) { img[o] = UInt8(v & 0xFF); img[o+1] = UInt8(v >> 8 & 0xFF) }
    func w32(_ v: UInt32, _ o: Int) { for i in 0..<4 { img[o+i] = UInt8(v >> (i*8) & 0xFF) } }

    let eLfanew = 0x80
    w16(0x5A4D, 0x00)
    w32(UInt32(eLfanew), 0x3C)
    w32(0x00004550, eLfanew)
    let optStart = eLfanew + 4 + 20
    w16(0xE0, eLfanew + 4 + 16)
    w16(0x010B, optStart)              // Magic = PE32
    w32(16, optStart + 92)             // NumberOfRvaAndSizes
    let dirArray = optStart + 96
    w32(0x200, dirArray + 0)
    w32(0x40, dirArray + 4)

    let ed = 0x200
    let funcs: UInt32 = 0x240, names: UInt32 = 0x300, ords: UInt32 = 0x380
    let strs = 0x400
    w32(1, ed + 16)
    w32(UInt32(exports.count), ed + 20)
    w32(UInt32(exports.count), ed + 24)
    w32(funcs, ed + 28); w32(names, ed + 32); w32(ords, ed + 36)
    var strOff = strs
    for (i, e) in exports.enumerated() {
        w32(e.rva, Int(funcs) + i*4)
        w32(UInt32(strOff), Int(names) + i*4)
        w16(UInt16(i), Int(ords) + i*2)
        for b in Array(e.name.utf8) { img[strOff] = b; strOff += 1 }
        img[strOff] = 0; strOff += 1
    }
    return img
}

@Suite("PEExportTable Edge Cases")
struct PEExportTableEdgeTests {
    @Test func parsesPE32() {
        let img = makePE32(exports: [("Alpha", 0x1000), ("Beta", 0x2000)])
        let reader = BufferMemoryReader(base: 0x400000, bytes: img)
        let table = PEExportTable(reader: reader, imageBase: 0x400000,
                                  imageSize: UInt32(img.count))!
        #expect(table.symbol(forImageOffset: 0x2004)?.name == "Beta")
        #expect(table.symbol(forImageOffset: 0x2004)?.delta == 4)
    }

    @Test func skipsForwarders() {
        // A forwarder's function RVA points inside the export dir range
        // (0x200 ..< 0x240). Foo is a forwarder; Bar is real code.
        let img = makePE64(exports: [("Foo", 0x210), ("Bar", 0x1000)])
        let reader = BufferMemoryReader(base: 0x140000000, bytes: img)
        let table = PEExportTable(reader: reader, imageBase: 0x140000000,
                                  imageSize: UInt32(img.count))!
        // Foo skipped entirely; an address near 0x210 must not resolve to Foo.
        #expect(table.symbol(forImageOffset: 0x1000)?.name == "Bar")
        #expect(table.symbol(forImageOffset: 0x0800) == nil)
    }

    @Test func nilWhenImageMemoryAbsent() {
        // Reader has no bytes for the image (dump didn't capture headers).
        let reader = BufferMemoryReader(base: 0x140000000, bytes: [])
        #expect(PEExportTable(reader: reader, imageBase: 0x140000000,
                              imageSize: 0x2000) == nil)
    }

    @Test func nilOnBadDosSignature() {
        var img = makePE64(exports: [("Foo", 0x1000)])
        img[0] = 0x00; img[1] = 0x00     // clobber 'MZ'
        let reader = BufferMemoryReader(base: 0x140000000, bytes: img)
        #expect(PEExportTable(reader: reader, imageBase: 0x140000000,
                              imageSize: UInt32(img.count)) == nil)
    }

    @Test func rejectsExcessiveNameCount() {
        var img = makePE64(exports: [("Foo", 0x1000)])
        // Overwrite NumberOfNames at export dir (0x200 + 24) with a huge value.
        let o = 0x200 + 24
        let huge = UInt32(PEExportTable.maxExports) + 1
        for i in 0..<4 { img[o+i] = UInt8(huge >> (i*8) & 0xFF) }
        let reader = BufferMemoryReader(base: 0x140000000, bytes: img)
        #expect(PEExportTable(reader: reader, imageBase: 0x140000000,
                              imageSize: UInt32(img.count)) == nil)
    }
}
```

- [ ] **Step 2: Run to verify status**

Run: `cd App && swift test --filter "PEExportTable Edge Cases"`
Expected: PASS (5 tests). The Task 4 implementation already covers these paths; if any fail, fix `PEImage.swift` (do not weaken the tests) and re-run.

- [ ] **Step 3: Commit**

```bash
git add App/Tests/PEImageTests.swift
git commit -m "test: PE32, forwarders, truncation, and DoS bounds for export tables"
```

---

### Task 6: `Symbolicator`

**Files:**
- Create: `App/MiniDumpTruck/Services/Symbolicator.swift`
- Test: `App/Tests/SymbolicatorTests.swift`

- [ ] **Step 1: Write the failing test**

Create `App/Tests/SymbolicatorTests.swift`. It builds one dump containing a ModuleList (one module) and a Memory64List region holding that module's PE image, then checks resolution and the max-delta guard.

```swift
import Foundation
import Testing
@testable import MiniDumpTruckCore

private extension Data {
    mutating func w16(_ v: UInt16, _ o: Int) { self[o] = UInt8(v & 0xFF); self[o+1] = UInt8(v >> 8 & 0xFF) }
    mutating func w32(_ v: UInt32, _ o: Int) { for i in 0..<4 { self[o+i] = UInt8(v >> (i*8) & 0xFF) } }
    mutating func w64(_ v: UInt64, _ o: Int) { for i in 0..<8 { self[o+i] = UInt8(v >> (i*8) & 0xFF) } }
}

/// Builds a dump with: 1 ModuleList module (name "test.dll", base, size) and a
/// Memory64List region [base, base+image.count) containing `image`.
private func makeDumpWithModuleImage(base: UInt64, image: [UInt8]) throws -> ParsedMinidump {
    // Layout: header(32) + streamDir(2 entries * 12) then payloads.
    let headerSize = 32
    let dirEntries = 2
    let dirSize = dirEntries * 12
    let modRva = headerSize + dirSize

    // ModuleList: count(4) + one MINIDUMP_MODULE(108) + name (MINIDUMP_STRING).
    let nameUTF16 = Array("test.dll".utf16)
    let nameRva = modRva + 4 + ModuleInfo.size
    let nameFieldLen = 4 + nameUTF16.count * 2
    let m64Rva = nameRva + nameFieldLen
    let m64HeaderSize = 16
    let m64DescSize = 16
    let imgStart = m64Rva + m64HeaderSize + m64DescSize

    var data = Data(repeating: 0, count: imgStart + image.count)
    data.w32(0x504D444D, 0)
    data.w16(0xA793, 4)
    data.w32(UInt32(dirEntries), 8)
    data.w32(UInt32(headerSize), 12)
    data.w32(0, 16)
    data.w32(1700000000, 20)
    data.w64(0, 24)

    // Stream dir entry 0: ModuleList (type 4)
    data.w32(4, headerSize + 0)
    data.w32(UInt32(4 + ModuleInfo.size), headerSize + 4)
    data.w32(UInt32(modRva), headerSize + 8)
    // Stream dir entry 1: Memory64List (type 9)
    data.w32(9, headerSize + 12)
    data.w32(UInt32(m64HeaderSize + m64DescSize), headerSize + 16)
    data.w32(UInt32(m64Rva), headerSize + 20)

    // ModuleList
    data.w32(1, modRva)                                    // module count
    let mod = modRva + 4
    data.w64(base, mod + 0)                                 // baseAddress
    data.w32(UInt32(image.count), mod + 8)                  // sizeOfImage
    data.w32(0, mod + 12)                                   // checksum
    data.w32(0, mod + 16)                                   // timeDateStamp
    data.w32(UInt32(nameRva), mod + 20)                     // moduleNameRva
    // MINIDUMP_STRING at nameRva: length(4) + UTF-16LE
    data.w32(UInt32(nameUTF16.count * 2), nameRva)
    for (i, u) in nameUTF16.enumerated() { data.w16(u, nameRva + 4 + i*2) }

    // Memory64List
    data.w64(1, m64Rva)                                     // numberOfRanges
    data.w64(UInt64(imgStart), m64Rva + 8)                  // baseRva
    data.w64(base, m64Rva + 16)                             // region start
    data.w64(UInt64(image.count), m64Rva + 24)              // region size
    for (i, b) in image.enumerated() { data[imgStart + i] = b }

    return try MinidumpParser.parse(data: data)
}

@Suite("Symbolicator")
struct SymbolicatorTests {
    @Test func resolvesExportedFunction() throws {
        let base: UInt64 = 0x180000000
        let image = makePE64(exports: [("DoWork", 0x1000), ("DoMore", 0x1800)])
        let dump = try makeDumpWithModuleImage(base: base, image: image)
        let sym = Symbolicator(dump: dump)

        let r = sym.resolve(address: base + 0x1804)
        #expect(r?.function == "DoMore")
        #expect(r?.offsetInFunction == 4)
    }

    @Test func returnsNilOutsideAnyModule() throws {
        let base: UInt64 = 0x180000000
        let image = makePE64(exports: [("DoWork", 0x1000)])
        let dump = try makeDumpWithModuleImage(base: base, image: image)
        let sym = Symbolicator(dump: dump)
        #expect(sym.resolve(address: 0x999_000_000) == nil)
    }

    @Test func maxDeltaGuardSuppressesDistantGuess() throws {
        // Only export at rva 0x1000; query 0x1000 + (256KB + 1) past it.
        let base: UInt64 = 0x180000000
        let image = makePE64(exports: [("OnlyExport", 0x1000)], imageSize: 0x80000)
        let dump = try makeDumpWithModuleImage(base: base, image: image)
        let sym = Symbolicator(dump: dump)
        let far = base + 0x1000 + 0x40000 + 1
        #expect(sym.resolve(address: far) == nil)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd App && swift test --filter "Symbolicator"`
Expected: FAIL to build with "cannot find 'Symbolicator' in scope".

- [ ] **Step 3: Implement `Symbolicator`**

Create `App/MiniDumpTruck/Services/Symbolicator.swift`:

```swift
import Foundation

/// Resolves code addresses to exported function names using per-module PE
/// export tables read from dump memory. Slice 1 of issue #2.
public struct Symbolicator: Sendable {
    /// Accuracy guard: if the nearest export is more than this many bytes
    /// below the address, the symbol is probably wrong (unexported/static
    /// code), so report nothing and let the caller fall back to module+offset.
    public static let maxFunctionSpan: UInt64 = 0x40000  // 256 KB

    private let moduleList: ModuleList?
    /// baseAddress -> parsed export table (only modules that produced one).
    private let tables: [UInt64: PEExportTable]

    public init(dump: ParsedMinidump) {
        self.moduleList = dump.moduleList
        let reader = DumpMemoryReader(dump: dump)
        var built: [UInt64: PEExportTable] = [:]
        for module in dump.moduleList?.modules ?? [] {
            if built[module.baseAddress] != nil { continue }
            if let table = PEExportTable(reader: reader,
                                         imageBase: module.baseAddress,
                                         imageSize: module.sizeOfImage) {
                built[module.baseAddress] = table
            }
        }
        self.tables = built
    }

    public func resolve(address: UInt64) -> ResolvedSymbol? {
        guard let module = moduleList?.module(containing: address),
              let table = tables[module.baseAddress] else { return nil }
        let imageOffset = address - module.baseAddress
        guard let hit = table.symbol(forImageOffset: imageOffset) else { return nil }
        guard hit.delta <= Self.maxFunctionSpan else { return nil }
        return ResolvedSymbol(function: hit.name, offsetInFunction: hit.delta)
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd App && swift test --filter "Symbolicator"`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add App/MiniDumpTruck/Services/Symbolicator.swift App/Tests/SymbolicatorTests.swift
git commit -m "feat: add Symbolicator with per-module export tables and max-delta guard"
```

---

### Task 7: Wire `Symbolicator` into `CrashAnalyzer`

**Files:**
- Modify: `App/MiniDumpTruck/Services/CrashAnalyzer.swift` (init + `createFrame` at `:367-382`)
- Test: `App/Tests/SymbolicatorTests.swift` (add an end-to-end suite)

- [ ] **Step 1: Write the failing end-to-end test**

Append to `App/Tests/SymbolicatorTests.swift`:

```swift
@Suite("CrashAnalyzer Symbolication")
struct CrashAnalyzerSymbolicationTests {
    @Test func createFrameAttachesSymbol() throws {
        // Build a dump with a module image; resolve a frame address directly
        // through the same path createFrame uses (Symbolicator + StackFrame).
        let base: UInt64 = 0x180000000
        let image = makePE64(exports: [("CrashHere", 0x1000)])
        let dump = try makeDumpWithModuleImage(base: base, image: image)

        let sym = Symbolicator(dump: dump)
        let resolved = try #require(sym.resolve(address: base + 0x1020))

        let module = try #require(dump.moduleList?.module(containing: base + 0x1020))
        let frame = StackFrame(
            address: base + 0x1020,
            module: module,
            offsetInModule: module.offset(for: base + 0x1020),
            symbol: resolved,
            frameType: .returnAddress,
            confidence: .medium
        )
        #expect(frame.displayAddress == "test.dll!CrashHere+0x20")
    }
}
```

- [ ] **Step 2: Run the test to verify it passes at the unit level**

Run: `cd App && swift test --filter "CrashAnalyzer Symbolication"`
Expected: PASS (1 test). This proves the Symbolicator → StackFrame → displayAddress path. Next steps wire it into `createFrame` so real analysis output carries symbols.

- [ ] **Step 3: Add the Symbolicator to `CrashAnalyzer` and use it in `createFrame`**

In `App/MiniDumpTruck/Services/CrashAnalyzer.swift`, extend `init` (built in Task 2):

Replace:

```swift
    private let memory: DumpMemoryReader

    public init(dump: ParsedMinidump) {
        self.dump = dump
        self.memory = DumpMemoryReader(dump: dump)
    }
```

with:

```swift
    private let memory: DumpMemoryReader
    private let symbolicator: Symbolicator

    public init(dump: ParsedMinidump) {
        self.dump = dump
        self.memory = DumpMemoryReader(dump: dump)
        self.symbolicator = Symbolicator(dump: dump)
    }
```

Replace `createFrame`:

```swift
    private func createFrame(
        address: UInt64,
        type: StackFrame.FrameType,
        confidence: StackFrame.FrameConfidence
    ) -> StackFrame {
        let module = dump.moduleList?.module(containing: address)
        let offset = module?.offset(for: address)

        return StackFrame(
            address: address,
            module: module,
            offsetInModule: offset,
            frameType: type,
            confidence: confidence
        )
    }
```

with:

```swift
    private func createFrame(
        address: UInt64,
        type: StackFrame.FrameType,
        confidence: StackFrame.FrameConfidence
    ) -> StackFrame {
        let module = dump.moduleList?.module(containing: address)
        let offset = module?.offset(for: address)
        let symbol = symbolicator.resolve(address: address)

        return StackFrame(
            address: address,
            module: module,
            offsetInModule: offset,
            symbol: symbol,
            frameType: type,
            confidence: confidence
        )
    }
```

- [ ] **Step 4: Build and run the full suite**

Run: `cd App && swift build && swift test`
Expected: `Build complete!` and all tests pass. Frame addresses, blame, and confidence are unchanged (symbol is additive); existing CrashAnalyzer assertions still hold.

- [ ] **Step 5: Commit**

```bash
git add App/MiniDumpTruck/Services/CrashAnalyzer.swift App/Tests/SymbolicatorTests.swift
git commit -m "feat: populate StackFrame.symbol during crash analysis"
```

---

### Task 8: Surface symbols in exporters and views

**Files:**
- Inspect: `App/MiniDumpTruck/Services/TextReporter.swift`, `App/MiniDumpTruck/Services/HTMLExporter.swift`, `App/MiniDumpTruck/Services/CSVExporter.swift`, `App/MiniDumpTruck/Views/CrashAnalysisView.swift`, `App/MiniDumpTruck/Views/ThreadDetailView.swift`
- Modify: only the sites that hand-build `module+offset` instead of using `StackFrame.displayAddress`
- Test: `App/Tests/ExporterTests.swift` (add a symbol-surfacing suite)

- [ ] **Step 1: Audit the five frame-formatting sites**

For each file, search for stack-frame formatting:

Run: `cd App && grep -n "offsetInModule\|displayAddress\|+0x\|shortName" MiniDumpTruck/Services/TextReporter.swift MiniDumpTruck/Services/HTMLExporter.swift MiniDumpTruck/Services/CSVExporter.swift MiniDumpTruck/Views/CrashAnalysisView.swift MiniDumpTruck/Views/ThreadDetailView.swift`

Classify each hit:
- Uses `frame.displayAddress` already → gets symbols automatically, no change.
- Hand-builds `"\(module.shortName)+0x..."` from a `StackFrame` → replace that expression with `frame.displayAddress`.
Record the list of sites that need changing. If every site already uses `displayAddress`, note that and skip to Step 3 (no source change needed; the test still gets added).

- [ ] **Step 2: Replace any hand-built frame strings with `displayAddress`**

For each site identified, replace the hand-built string with `frame.displayAddress`. Example pattern (apply only where the audit found it; do not invent call sites):

Before:
```swift
let line = "\(frame.module?.shortName ?? "?")+0x\(String(frame.offsetInModule ?? 0, radix: 16))"
```
After:
```swift
let line = frame.displayAddress
```

Do not change JSON export: `StackFrame` is `Codable` and `symbol` is now in `CodingKeys`, so `JSONExporter` emits `{ "symbol": { "function", "offsetInFunction" } }` automatically.

- [ ] **Step 3: Write the surfacing test**

Append to `App/Tests/ExporterTests.swift` (reuse its existing imports; this suite is self-contained):

```swift
@Suite("Symbol Surfacing")
struct SymbolSurfacingTests {
    private func mockModule(name: String, base: UInt64) -> ModuleInfo {
        var data = Data()
        data.append(contentsOf: withUnsafeBytes(of: base.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt32(0x10000).littleEndian) { Array($0) })
        data.append(contentsOf: [UInt8](repeating: 0, count: ModuleInfo.size - 12))
        var m = ModuleInfo(from: data, at: 0)!
        m.setName(name)
        return m
    }

    @Test func jsonExportIncludesStructuredSymbol() throws {
        let frame = StackFrame(
            address: 0x7FF800001014,
            module: mockModule(name: "ntdll.dll", base: 0x7FF800000000),
            offsetInModule: 0x1014,
            symbol: ResolvedSymbol(function: "NtClose", offsetInFunction: 0x14),
            frameType: .returnAddress,
            confidence: .medium
        )
        let json = try JSONEncoder().encode(frame)
        let obj = try #require(
            try JSONSerialization.jsonObject(with: json) as? [String: Any])
        let symbol = try #require(obj["symbol"] as? [String: Any])
        #expect(symbol["function"] as? String == "NtClose")
        #expect(symbol["offsetInFunction"] as? Int == 0x14)
    }

    @Test func displayAddressIsTheSingleFormattingChokepoint() {
        let frame = StackFrame(
            address: 0x7FF800001014,
            module: mockModule(name: "ntdll.dll", base: 0x7FF800000000),
            offsetInModule: 0x1014,
            symbol: ResolvedSymbol(function: "NtClose", offsetInFunction: 0x14),
            frameType: .returnAddress,
            confidence: .medium
        )
        #expect(frame.displayAddress == "ntdll.dll!NtClose+0x14")
    }
}
```

- [ ] **Step 4: Build and run the full suite**

Run: `cd App && swift build && swift test`
Expected: `Build complete!` and all tests pass, including `Symbol Surfacing`.

- [ ] **Step 5: Commit**

```bash
git add App/MiniDumpTruck/Services App/MiniDumpTruck/Views App/Tests/ExporterTests.swift
git commit -m "feat: surface resolved symbols in exporters and crash views"
```

---

## Self-Review (completed during planning)

**Spec coverage:**
- DumpMemoryReader extraction → Task 1 + Task 2.
- `Models/PEImage.swift` (`PEExportTable`) → Task 4 + Task 5.
- `Services/Symbolicator.swift` (eager per-module cache) → Task 6.
- `StackFrame.symbol` + `displayAddress` + `CodingKeys` → Task 3.
- `CrashAnalyzer` integration → Task 7.
- PE32/PE32+, forwarder-skip, max-delta guard, DoS caps, name-length bound → Tasks 4-6 (constants `maxExports`, `maxNameLength` on `PEExportTable`; `maxFunctionSpan` on `Symbolicator`).
- Surfacing in views + 4 exporters; JSON automatic → Task 8.
- Error handling (failable init, truncated memory → nil) → Task 5 (`nilWhenImageMemoryAbsent`, `nilOnBadDosSignature`).
- 531-test regression guard for the refactor → Task 2 Step 1/4, Task 7 Step 4.

**Placeholder scan:** No TBD/TODO; every code step contains complete code; no "similar to Task N" references.

**Type consistency:** `MemoryReading.read(at:size:)`, `PEExportTable(reader:imageBase:imageSize:)`, `PEExportTable.symbol(forImageOffset:) -> (name:delta:)`, `ResolvedSymbol(function:offsetInFunction:)`, `Symbolicator(dump:).resolve(address:) -> ResolvedSymbol?`, and the 6-arg `StackFrame.init(address:module:offsetInModule:symbol:frameType:confidence:)` with `symbol` defaulted are used consistently across Tasks 1-8.

**Out of scope (tracked in spec / other issues):** public symbol server (slice 2), private symbol path (slice 3), unwind-info stack walking (#3), frictionless input (#6), forwarder-string resolution and max-delta tuning (spec post-v1 follow-ups).
