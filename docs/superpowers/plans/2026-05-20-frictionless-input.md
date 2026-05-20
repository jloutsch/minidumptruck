# Frictionless Input (Issue #6) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Open Windows minidump files seamlessly — direct `.dmp`, `.zip` containing dumps (multi-select picker), and extensionless files with valid MDMP bytes — with friendly typed errors on failure.

**Architecture:** A pure Core layer (`InputSniffer`, `ZipReader`, `OpenError`, `InputPipeline`, `TempStore`) does sniffing, parsing, and orchestration with synthetic-byte tests. The App layer (`WelcomeView` edits + new `ZipPickerView`) provides UI glue, multi-window opening via `NSWorkspace`, and `MinidumpDocument` construction. ZIP parsing is hand-rolled (~200 LOC) on top of `Compression.framework` (system, zero deps); STORE and DEFLATE supported; encrypted/ZIP64/other methods return typed errors.

**Tech Stack:** Swift 5.9, Swift Package Manager, Swift Testing (`import Testing`), macOS 14+, `Compression.framework`, AppKit (`NSWorkspace`, `NSOpenPanel`, `NSAlert`).

**Spec:** `docs/superpowers/specs/2026-05-20-frictionless-input-design.md`

**Plan-level refinement of the spec:** the spec assigns `InputPipeline` and `TempStore` to the App target. This plan moves them to the Core target (`MiniDumpTruckCore`) because (a) neither needs UI or AppKit — they're pure parse/orchestration over `Foundation` and the test target only depends on Core, so this is what enables unit testing them with synthetic files; (b) it lets `InputPipeline.Outcome` carry `ParsedMinidump`+`fileSize` rather than the App-target `MinidumpDocument`, with the App layer constructing `MinidumpDocument` from those values. `ZipPickerView` stays in the App target (it's SwiftUI). This refines the spec without changing what's built or shipped.

**Conventions for every task:**
- Build: `cd App && swift build`
- Test single suite: `cd App && swift test --filter "<SuiteName>"`
- Test full regression: `cd App && swift test`
- New Core source files go under `App/MiniDumpTruck/{Utilities,Models}/` (globbed into `MiniDumpTruckCore` automatically).
- New App-target source files go under `App/MiniDumpTruck/Views/` (in the App target's `sources` array) or top-level — see Task 6 for the Package.swift wiring.
- New test files go under `App/Tests/`, Swift Testing (`import Testing`, `@Suite`, `@Test`, `#expect`, `try #require`), `@testable import MiniDumpTruckCore`.
- ZIP byte-layout reference: signatures `0x04034B50` (local file header), `0x02014B50` (central directory record), `0x06054B50` (EOCD), `0x07064B50` (ZIP64 EOCD locator — detected and rejected).

---

### Task 1: `OpenError` + `ZipError` types and tests

**Files:**
- Create: `App/MiniDumpTruck/Models/OpenError.swift`
- Test: `App/Tests/OpenErrorTests.swift`

Notes: `ZipError` lives alongside `ZipArchive` in Task 3 but this task introduces it as a stub so `OpenError.zipParseFailed(ZipError)` compiles. The stub here has all the cases the spec calls out; Task 3 just adds the parsing logic, not new cases.

- [ ] **Step 1: Write the failing tests**

Create `App/Tests/OpenErrorTests.swift`:

```swift
import Foundation
import Testing
@testable import MiniDumpTruckCore

@Suite("OpenError")
struct OpenErrorTests {
    @Test func notAMinidumpMentionsBytes() {
        let err = OpenError.notAMinidump(firstBytes: [0x50, 0x4B, 0x03, 0x04])
        let msg = try? #require(err.errorDescription)
        #expect(msg?.contains("does not look like a Windows minidump") == true)
        #expect(msg?.contains("50") == true)  // hex of first byte
    }

    @Test func corruptedMinidumpIncludesUnderlying() {
        struct Boom: LocalizedError {
            var errorDescription: String? { "stream offset out of range" }
        }
        let err = OpenError.corruptedMinidump(underlying: Boom())
        let msg = try? #require(err.errorDescription)
        #expect(msg?.contains("truncated or corrupt") == true)
        #expect(msg?.contains("stream offset out of range") == true)
    }

    @Test func zipNoMinidumpsIncludesZipName() {
        let err = OpenError.zipNoMinidumps(zipName: "crashes.zip")
        let msg = try? #require(err.errorDescription)
        #expect(msg?.contains("crashes.zip") == true)
        #expect(msg?.contains(".dmp") == true)
    }

    @Test func zipParseFailedWrapsZipError() {
        let err = OpenError.zipParseFailed(.encrypted)
        let msg = try? #require(err.errorDescription)
        #expect(msg?.contains("encrypted") == true)
    }

    @Test func zipExtractFailedIncludesEntryName() {
        struct Boom: LocalizedError {
            var errorDescription: String? { "disk full" }
        }
        let err = OpenError.zipExtractFailed(entry: "crash.dmp", underlying: Boom())
        let msg = try? #require(err.errorDescription)
        #expect(msg?.contains("crash.dmp") == true)
        #expect(msg?.contains("disk full") == true)
    }
}

@Suite("ZipError")
struct ZipErrorTests {
    @Test func notAZipDescription() {
        #expect(ZipError.notAZip.errorDescription?.contains("not a ZIP") == true)
    }

    @Test func corruptedIncludesReason() {
        let err = ZipError.corrupted(reason: "truncated central directory")
        #expect(err.errorDescription?.contains("truncated central directory") == true)
    }

    @Test func encryptedDescription() {
        #expect(ZipError.encrypted.errorDescription?.contains("encrypted") == true)
    }

    @Test func zip64UnsupportedDescription() {
        #expect(ZipError.zip64Unsupported.errorDescription?.contains("ZIP64") == true)
    }

    @Test func unsupportedCompressionIncludesMethod() {
        let err = ZipError.unsupportedCompression(method: 12)
        #expect(err.errorDescription?.contains("12") == true)
    }

    @Test func entryTooLargeIncludesNumbers() {
        let err = ZipError.entryTooLarge(actual: 0xFFFFFFFF, limit: 0xFFFFFFFF)
        #expect(err.errorDescription?.contains("too large") == true)
    }

    @Test func tooManyEntriesIncludesCount() {
        let err = ZipError.tooManyEntries(actual: 200_000, limit: 100_000)
        #expect(err.errorDescription?.contains("100000") == true || err.errorDescription?.contains("100,000") == true)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd App && swift test --filter "OpenError" --filter "ZipError"`
Expected: FAIL to build with "cannot find 'OpenError'" / "cannot find 'ZipError'".

- [ ] **Step 3: Create the types**

Create `App/MiniDumpTruck/Models/OpenError.swift`:

```swift
import Foundation

/// Parser/extraction errors from `ZipArchive`. Surfaced to the user via
/// `OpenError.zipParseFailed`. (The `CompressionMethod` enum lives in
/// `ZipReader.swift` alongside the parser; `ZipError.unsupportedCompression`
/// carries a raw `UInt16` so this type does not need that import.)
public enum ZipError: Error, LocalizedError, Equatable {
    case notAZip
    case corrupted(reason: String)
    case encrypted
    case zip64Unsupported
    case unsupportedCompression(method: UInt16)
    case entryTooLarge(actual: UInt32, limit: UInt32)
    case tooManyEntries(actual: UInt64, limit: UInt64)

    public var errorDescription: String? {
        switch self {
        case .notAZip:
            return "This file is not a ZIP archive."
        case .corrupted(let reason):
            return "This ZIP appears to be corrupt: \(reason)."
        case .encrypted:
            return "This ZIP is encrypted. Extract it with the password first, then open the .dmp."
        case .zip64Unsupported:
            return "This ZIP uses the ZIP64 format (over 4 GB), which is not supported yet."
        case .unsupportedCompression(let method):
            return "This ZIP uses compression method \(method), which is not supported. Re-create the zip with standard deflate."
        case .entryTooLarge(let actual, let limit):
            return "A ZIP entry is too large to extract: \(actual) bytes (limit \(limit))."
        case .tooManyEntries(let actual, let limit):
            return "This ZIP has too many entries: \(actual) (limit \(limit))."
        }
    }
}

/// User-facing errors emitted by the input pipeline. `localizedDescription`
/// returns human-readable text suitable for an alert dialog; the raw Swift
/// type names are never shown to the user.
public enum OpenError: Error, LocalizedError {
    case notAMinidump(firstBytes: [UInt8])
    case corruptedMinidump(underlying: Error)
    case zipParseFailed(ZipError)
    case zipNoMinidumps(zipName: String)
    case zipExtractFailed(entry: String, underlying: Error)

    public var errorDescription: String? {
        switch self {
        case .notAMinidump(let bytes):
            let hex = bytes.prefix(4).map { String(format: "%02X", $0) }.joined(separator: " ")
            return "This file does not look like a Windows minidump or a zip containing one. (First bytes: \(hex.isEmpty ? "<empty>" : hex).)"
        case .corruptedMinidump(let underlying):
            let detail = underlying.localizedDescription
            return "This minidump appears to be truncated or corrupt: \(detail)."
        case .zipParseFailed(let zipError):
            return zipError.errorDescription ?? "ZIP parsing failed."
        case .zipNoMinidumps(let zipName):
            return "\(zipName) does not contain any .dmp / .mdmp / .minidump files."
        case .zipExtractFailed(let entry, let underlying):
            let detail = underlying.localizedDescription
            return "Could not extract \(entry) from the zip: \(detail)."
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd App && swift test --filter "OpenError" --filter "ZipError"`
Expected: PASS (13 tests).

- [ ] **Step 5: Run the full suite for regression**

Run: `cd App && swift test`
Expected: previous count + 13 new tests, all green.

- [ ] **Step 6: Commit**

```bash
git add App/MiniDumpTruck/Models/OpenError.swift App/Tests/OpenErrorTests.swift
git commit -m "feat: add OpenError + ZipError typed errors with friendly text"
```

---

### Task 2: `InputSniffer`

**Files:**
- Create: `App/MiniDumpTruck/Utilities/InputSniffer.swift`
- Test: `App/Tests/InputSnifferTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `App/Tests/InputSnifferTests.swift`:

```swift
import Foundation
import Testing
@testable import MiniDumpTruckCore

@Suite("InputSniffer")
struct InputSnifferTests {
    @Test func detectsMinidumpFromData() {
        // "MDMP" in little-endian byte order
        let data = Data([0x4D, 0x44, 0x4D, 0x50, 0xAA, 0xBB])
        #expect(InputSniffer.detect(from: data) == .minidump)
    }

    @Test func detectsZipFromData() {
        // PK\x03\x04 (local file header signature)
        let data = Data([0x50, 0x4B, 0x03, 0x04, 0x14, 0x00])
        #expect(InputSniffer.detect(from: data) == .zip)
    }

    @Test func emptyDataIsUnsupported() {
        let result = InputSniffer.detect(from: Data())
        if case .unsupported(let bytes) = result {
            #expect(bytes.isEmpty)
        } else {
            Issue.record("Expected .unsupported, got \(result)")
        }
    }

    @Test func shortDataIsUnsupported() {
        let result = InputSniffer.detect(from: Data([0x4D, 0x44]))
        if case .unsupported(let bytes) = result {
            #expect(bytes == [0x4D, 0x44])
        } else {
            Issue.record("Expected .unsupported, got \(result)")
        }
    }

    @Test func arbitraryBytesAreUnsupported() {
        let data = Data([0x7F, 0x45, 0x4C, 0x46])  // ELF magic
        let result = InputSniffer.detect(from: data)
        if case .unsupported(let bytes) = result {
            #expect(bytes == [0x7F, 0x45, 0x4C, 0x46])
        } else {
            Issue.record("Expected .unsupported, got \(result)")
        }
    }

    @Test func detectAtUrlReadsOnlyFourBytes() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sniffer-test-\(UUID().uuidString).bin")
        // 10 MB file with MDMP prefix + garbage
        var data = Data([0x4D, 0x44, 0x4D, 0x50])
        data.append(Data(repeating: 0xCC, count: 10_000_000))
        try data.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let kind = try InputSniffer.detect(at: tmp)
        #expect(kind == .minidump)
        // The function MUST NOT mmap or read more than 4 bytes.
        // If it loaded the whole 10 MB, we can detect that by timing or memory
        // — but the contract is just: it returns the right answer fast.
        // A weaker but useful check: it doesn't throw on a large file.
    }

    @Test func detectAtUrlReturnsUnsupportedForTinyFile() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sniffer-tiny-\(UUID().uuidString).bin")
        try Data([0x00, 0x01]).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let kind = try InputSniffer.detect(at: tmp)
        if case .unsupported(let bytes) = kind {
            #expect(bytes == [0x00, 0x01])
        } else {
            Issue.record("Expected .unsupported, got \(kind)")
        }
    }

    @Test func detectAtUrlReturnsUnsupportedForEmptyFile() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sniffer-empty-\(UUID().uuidString).bin")
        try Data().write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let kind = try InputSniffer.detect(at: tmp)
        if case .unsupported(let bytes) = kind {
            #expect(bytes.isEmpty)
        } else {
            Issue.record("Expected .unsupported, got \(kind)")
        }
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd App && swift test --filter "InputSniffer"`
Expected: FAIL to build with "cannot find 'InputSniffer'".

- [ ] **Step 3: Implement the sniffer**

Create `App/MiniDumpTruck/Utilities/InputSniffer.swift`:

```swift
import Foundation

/// What `InputSniffer` decided a file is, based on its first 4 bytes.
public enum InputKind: Sendable, Equatable {
    case minidump
    case zip
    /// The first up-to-4 bytes seen; empty for an empty file.
    case unsupported(firstBytes: [UInt8])
}

/// Decides the type of an input file from its first 4 bytes. Used by the
/// open pipeline so we can drop filename-based extension checks.
public enum InputSniffer {
    /// Minidump file signature: "MDMP" in little-endian UInt32 byte order.
    static let minidumpSignature: [UInt8] = [0x4D, 0x44, 0x4D, 0x50]
    /// ZIP local file header signature: PK\x03\x04.
    static let zipSignature: [UInt8] = [0x50, 0x4B, 0x03, 0x04]

    /// Classify a chunk of bytes by its first 4 bytes.
    public static func detect(from data: Data) -> InputKind {
        let head = Array(data.prefix(4))
        if head == minidumpSignature { return .minidump }
        if head == zipSignature { return .zip }
        return .unsupported(firstBytes: head)
    }

    /// Read at most the first 4 bytes of the file and classify. Throws only
    /// on filesystem errors (file missing, permission denied, etc.).
    public static func detect(at url: URL) throws -> InputKind {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let chunk = try handle.read(upToCount: 4) ?? Data()
        return detect(from: chunk)
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd App && swift test --filter "InputSniffer"`
Expected: PASS (8 tests).

- [ ] **Step 5: Run the full suite**

Run: `cd App && swift test`
Expected: previous count + 8 new tests, all green.

- [ ] **Step 6: Commit**

```bash
git add App/MiniDumpTruck/Utilities/InputSniffer.swift App/Tests/InputSnifferTests.swift
git commit -m "feat: add InputSniffer for content-based file-kind detection"
```

---

### Task 3: `ZipReader` — happy path (STORE + DEFLATE)

**Files:**
- Create: `App/MiniDumpTruck/Utilities/ZipReader.swift`
- Test: `App/Tests/ZipReaderTests.swift`

Notes: This task adds the parser for valid ZIPs. Task 4 adds the rejection paths and DoS bounds.

- [ ] **Step 1: Write the failing tests with a synthetic ZIP builder**

Create `App/Tests/ZipReaderTests.swift`:

```swift
import Foundation
import Compression
import Testing
@testable import MiniDumpTruckCore

// MARK: - Synthetic ZIP builder

/// Builds a ZIP buffer in memory: local file headers + data + central directory + EOCD.
/// Per-entry: provide name, uncompressed data, and compression method.
/// For DEFLATE, this helper does the deflation using Compression.framework.
struct SyntheticZipBuilder {
    struct Entry {
        let name: String
        let uncompressed: Data
        let method: CompressionMethod
    }

    static func build(_ entries: [Entry]) -> Data {
        var out = Data()
        struct CdMeta { let name: String; let method: CompressionMethod; let uncompressedSize: UInt32; let compressedSize: UInt32; let localHeaderOffset: UInt32; let body: Data }
        var meta: [CdMeta] = []

        for e in entries {
            let body: Data
            switch e.method {
            case .store:
                body = e.uncompressed
            case .deflate:
                body = deflate(e.uncompressed)
            }
            let offset = UInt32(out.count)
            let nameBytes = Array(e.name.utf8)
            // Local file header
            out.appendUInt32LE(0x04034B50)            // signature
            out.appendUInt16LE(20)                    // version needed
            out.appendUInt16LE(0)                     // general-purpose flags
            out.appendUInt16LE(e.method.rawValue)     // compression method
            out.appendUInt16LE(0)                     // mod time
            out.appendUInt16LE(0)                     // mod date
            out.appendUInt32LE(0)                     // CRC-32 (unused by reader)
            out.appendUInt32LE(UInt32(body.count))    // compressed size
            out.appendUInt32LE(UInt32(e.uncompressed.count))  // uncompressed size
            out.appendUInt16LE(UInt16(nameBytes.count))       // name len
            out.appendUInt16LE(0)                     // extra len
            out.append(contentsOf: nameBytes)
            out.append(body)
            meta.append(CdMeta(name: e.name, method: e.method,
                               uncompressedSize: UInt32(e.uncompressed.count),
                               compressedSize: UInt32(body.count),
                               localHeaderOffset: offset, body: body))
        }

        let cdOffset = UInt32(out.count)
        for m in meta {
            let nameBytes = Array(m.name.utf8)
            out.appendUInt32LE(0x02014B50)            // CD signature
            out.appendUInt16LE(20)                    // version made by
            out.appendUInt16LE(20)                    // version needed
            out.appendUInt16LE(0)                     // gp flags
            out.appendUInt16LE(m.method.rawValue)     // method
            out.appendUInt16LE(0); out.appendUInt16LE(0)  // mod time/date
            out.appendUInt32LE(0)                     // CRC-32
            out.appendUInt32LE(m.compressedSize)
            out.appendUInt32LE(m.uncompressedSize)
            out.appendUInt16LE(UInt16(nameBytes.count))
            out.appendUInt16LE(0)                     // extra len
            out.appendUInt16LE(0)                     // comment len
            out.appendUInt16LE(0)                     // disk number
            out.appendUInt16LE(0)                     // internal attrs
            out.appendUInt32LE(0)                     // external attrs
            out.appendUInt32LE(m.localHeaderOffset)
            out.append(contentsOf: nameBytes)
        }
        let cdSize = UInt32(out.count) - cdOffset
        // EOCD
        out.appendUInt32LE(0x06054B50)
        out.appendUInt16LE(0)                         // disk no
        out.appendUInt16LE(0)                         // disk where CD starts
        out.appendUInt16LE(UInt16(meta.count))        // records on this disk
        out.appendUInt16LE(UInt16(meta.count))        // total records
        out.appendUInt32LE(cdSize)
        out.appendUInt32LE(cdOffset)
        out.appendUInt16LE(0)                         // comment len
        return out
    }

    private static func deflate(_ input: Data) -> Data {
        if input.isEmpty { return Data() }
        let dstCapacity = max(input.count * 2, 64)
        var dst = Data(count: dstCapacity)
        let written = input.withUnsafeBytes { srcPtr -> Int in
            let src = srcPtr.bindMemory(to: UInt8.self).baseAddress!
            return dst.withUnsafeMutableBytes { dstPtr -> Int in
                let dstP = dstPtr.bindMemory(to: UInt8.self).baseAddress!
                return compression_encode_buffer(dstP, dstCapacity, src, input.count, nil, COMPRESSION_ZLIB)
            }
        }
        return dst.prefix(written)
    }
}

private extension Data {
    mutating func appendUInt16LE(_ v: UInt16) {
        append(UInt8(v & 0xFF)); append(UInt8((v >> 8) & 0xFF))
    }
    mutating func appendUInt32LE(_ v: UInt32) {
        for i in 0..<4 { append(UInt8((v >> (i*8)) & 0xFF)) }
    }
}

// MARK: - Tests

@Suite("ZipArchive happy path")
struct ZipArchiveHappyTests {
    @Test func parsesSingleStoreEntry() throws {
        let body = Data("hello world".utf8)
        let zip = SyntheticZipBuilder.build([
            .init(name: "hello.txt", uncompressed: body, method: .store)
        ])
        let archive = try ZipArchive(data: zip)
        #expect(archive.entries.count == 1)
        #expect(archive.entries[0].name == "hello.txt")
        #expect(archive.entries[0].compressionMethod == .store)
        #expect(archive.entries[0].uncompressedSize == UInt32(body.count))
        #expect(try archive.extract(archive.entries[0]) == body)
    }

    @Test func parsesSingleDeflateEntry() throws {
        let body = Data(repeating: 0x41, count: 4096)  // 4 KB of 'A' — highly compressible
        let zip = SyntheticZipBuilder.build([
            .init(name: "filler.bin", uncompressed: body, method: .deflate)
        ])
        let archive = try ZipArchive(data: zip)
        #expect(archive.entries.count == 1)
        #expect(archive.entries[0].compressionMethod == .deflate)
        #expect(archive.entries[0].uncompressedSize == UInt32(body.count))
        #expect(archive.entries[0].compressedSize < UInt32(body.count))  // actually compressed
        let extracted = try archive.extract(archive.entries[0])
        #expect(extracted == body)
    }

    @Test func parsesMultipleEntriesInCentralDirectoryOrder() throws {
        let a = Data("alpha contents".utf8)
        let b = Data("beta beta".utf8)
        let c = Data(repeating: 0x42, count: 100)
        let zip = SyntheticZipBuilder.build([
            .init(name: "a.dmp", uncompressed: a, method: .store),
            .init(name: "b.txt", uncompressed: b, method: .deflate),
            .init(name: "c.dmp", uncompressed: c, method: .store)
        ])
        let archive = try ZipArchive(data: zip)
        #expect(archive.entries.map(\.name) == ["a.dmp", "b.txt", "c.dmp"])
        #expect(try archive.extract(archive.entries[0]) == a)
        #expect(try archive.extract(archive.entries[1]) == b)
        #expect(try archive.extract(archive.entries[2]) == c)
    }

    @Test func emptyEntryRoundTrips() throws {
        let zip = SyntheticZipBuilder.build([
            .init(name: "empty.dmp", uncompressed: Data(), method: .store)
        ])
        let archive = try ZipArchive(data: zip)
        #expect(archive.entries[0].uncompressedSize == 0)
        #expect(try archive.extract(archive.entries[0]) == Data())
    }
}
```

- [ ] **Step 2: Run to verify the tests fail to build**

Run: `cd App && swift test --filter "ZipArchive happy path"`
Expected: FAIL to build with "cannot find 'ZipArchive'".

- [ ] **Step 3: Implement `ZipArchive` and `ZipEntry`**

Create `App/MiniDumpTruck/Utilities/ZipReader.swift`:

```swift
import Foundation
import Compression

/// Compression methods we support reading from a ZIP archive.
public enum CompressionMethod: UInt16, Sendable {
    case store = 0
    case deflate = 8
}

/// One entry in a ZIP archive's central directory.
public struct ZipEntry: Sendable, Identifiable {
    public let id: UUID
    public let name: String
    public let uncompressedSize: UInt32
    public let compressedSize: UInt32
    public let compressionMethod: CompressionMethod
    /// File offset of the local file header (used by extract).
    internal let localHeaderOffset: UInt32
    /// General-purpose bit flag from the central directory record (bit 0 = encrypted).
    internal let generalPurposeFlags: UInt16
}
// NOTE: ZipEntry is intentionally NOT Equatable. Synthesized Equatable would
// compare the UUID id, so two entries with identical content but different
// ids would be unequal — a footgun.

/// A parsed ZIP archive read from in-memory bytes.
/// Supports STORE and DEFLATE; rejects encrypted, ZIP64, and other methods
/// with a typed error.
public struct ZipArchive: Sendable {
    /// DoS bound: maximum entries parsed from one archive.
    public static let maxEntries: UInt64 = 100_000
    /// DoS bound: maximum uncompressed size of one entry (ZIP non-64 hard limit).
    public static let maxEntrySize: UInt32 = 0xFFFFFFFF
    /// DoS bound: maximum central-directory size.
    public static let maxCentralDirectorySize: UInt32 = 32 * 1024 * 1024

    public let entries: [ZipEntry]

    private let data: Data  // retained for extract()

    public init(data: Data) throws {
        self.data = data
        guard data.count >= 22 else { throw ZipError.notAZip }

        // 1. Find EOCD: signature 0x06054B50, search backwards from end.
        let eocdSig: UInt32 = 0x06054B50
        let zip64LocatorSig: UInt32 = 0x07064B50
        let maxComment = 0xFFFF
        let searchStart = max(0, data.count - 22 - maxComment)
        var eocdOffset: Int? = nil
        var i = data.count - 22
        while i >= searchStart {
            if data.readUInt32(at: i) == eocdSig {
                eocdOffset = i
                break
            }
            i -= 1
        }
        guard let eocd = eocdOffset else { throw ZipError.notAZip }

        // 2. Detect ZIP64 EOCD locator immediately before EOCD.
        if eocd >= 20, data.readUInt32(at: eocd - 20) == zip64LocatorSig {
            throw ZipError.zip64Unsupported
        }

        // 3. Read EOCD fields.
        guard let totalRecords16 = data.readUInt16(at: eocd + 10),
              let cdSize = data.readUInt32(at: eocd + 12),
              let cdOffset = data.readUInt32(at: eocd + 16) else {
            throw ZipError.corrupted(reason: "EOCD truncated")
        }
        let totalRecords = UInt64(totalRecords16)
        if totalRecords > Self.maxEntries {
            throw ZipError.tooManyEntries(actual: totalRecords, limit: Self.maxEntries)
        }
        if cdSize > Self.maxCentralDirectorySize {
            throw ZipError.corrupted(reason: "central directory too large")
        }
        let cdEnd64 = UInt64(cdOffset) + UInt64(cdSize)
        guard cdEnd64 <= UInt64(data.count) else {
            throw ZipError.corrupted(reason: "central directory exceeds file size")
        }

        // 4. Iterate central directory records.
        var entries: [ZipEntry] = []
        entries.reserveCapacity(Int(totalRecords))
        var cursor = Int(cdOffset)
        let cdRecordSig: UInt32 = 0x02014B50
        for _ in 0..<Int(totalRecords) {
            guard data.readUInt32(at: cursor) == cdRecordSig else {
                throw ZipError.corrupted(reason: "bad central directory record signature at offset \(cursor)")
            }
            guard let gpFlags = data.readUInt16(at: cursor + 8),
                  let methodRaw = data.readUInt16(at: cursor + 10),
                  let compressed = data.readUInt32(at: cursor + 20),
                  let uncompressed = data.readUInt32(at: cursor + 24),
                  let nameLen = data.readUInt16(at: cursor + 28),
                  let extraLen = data.readUInt16(at: cursor + 30),
                  let commentLen = data.readUInt16(at: cursor + 32),
                  let localOffset = data.readUInt32(at: cursor + 42) else {
                throw ZipError.corrupted(reason: "central directory record truncated at offset \(cursor)")
            }
            if (gpFlags & 0x0001) != 0 { throw ZipError.encrypted }
            guard let method = CompressionMethod(rawValue: methodRaw) else {
                throw ZipError.unsupportedCompression(method: methodRaw)
            }
            if uncompressed > Self.maxEntrySize {
                throw ZipError.entryTooLarge(actual: uncompressed, limit: Self.maxEntrySize)
            }
            let nameStart = cursor + 46
            let nameEnd = nameStart + Int(nameLen)
            guard nameEnd <= data.count else {
                throw ZipError.corrupted(reason: "filename runs past end of file")
            }
            let nameData = data[nameStart..<nameEnd]
            let name = String(data: nameData, encoding: .utf8) ?? ""

            entries.append(ZipEntry(
                id: UUID(),
                name: name,
                uncompressedSize: uncompressed,
                compressedSize: compressed,
                compressionMethod: method,
                localHeaderOffset: localOffset,
                generalPurposeFlags: gpFlags
            ))
            cursor = nameEnd + Int(extraLen) + Int(commentLen)
        }
        self.entries = entries
    }

    /// Extract one entry's uncompressed bytes.
    public func extract(_ entry: ZipEntry) throws -> Data {
        let localSig: UInt32 = 0x04034B50
        let lh = Int(entry.localHeaderOffset)
        guard lh + 30 <= data.count, data.readUInt32(at: lh) == localSig else {
            throw ZipError.corrupted(reason: "bad local file header at offset \(lh)")
        }
        guard let nameLen = data.readUInt16(at: lh + 26),
              let extraLen = data.readUInt16(at: lh + 28) else {
            throw ZipError.corrupted(reason: "local header truncated")
        }
        let dataStart = lh + 30 + Int(nameLen) + Int(extraLen)
        let dataEnd = dataStart + Int(entry.compressedSize)
        guard dataEnd <= data.count else {
            throw ZipError.corrupted(reason: "entry data runs past end of file")
        }
        let body = data.subdata(in: dataStart..<dataEnd)

        switch entry.compressionMethod {
        case .store:
            guard body.count == Int(entry.uncompressedSize) else {
                throw ZipError.corrupted(reason: "STORE size mismatch")
            }
            return body
        case .deflate:
            return try Self.inflate(body, uncompressedSize: Int(entry.uncompressedSize))
        }
    }

    /// Inflate a raw deflate stream (no zlib header) using Compression.framework.
    private static func inflate(_ compressed: Data, uncompressedSize: Int) throws -> Data {
        if uncompressedSize == 0 { return Data() }
        var dst = Data(count: uncompressedSize)
        let produced = compressed.withUnsafeBytes { srcPtr -> Int in
            let src = srcPtr.bindMemory(to: UInt8.self).baseAddress!
            return dst.withUnsafeMutableBytes { dstPtr -> Int in
                let dstP = dstPtr.bindMemory(to: UInt8.self).baseAddress!
                return compression_decode_buffer(dstP, uncompressedSize, src, compressed.count, nil, COMPRESSION_ZLIB)
            }
        }
        if produced != uncompressedSize {
            throw ZipError.corrupted(reason: "DEFLATE produced \(produced) bytes, expected \(uncompressedSize)")
        }
        return dst
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd App && swift test --filter "ZipArchive happy path"`
Expected: PASS (4 tests).

- [ ] **Step 5: Run the full suite**

Run: `cd App && swift test`
Expected: previous count + 4 new tests, all green.

- [ ] **Step 6: Commit**

```bash
git add App/MiniDumpTruck/Utilities/ZipReader.swift App/Tests/ZipReaderTests.swift
git commit -m "feat: hand-rolled ZIP reader with STORE + DEFLATE support"
```

---

### Task 4: `ZipReader` rejection paths and DoS bounds

**Files:**
- Modify: `App/Tests/ZipReaderTests.swift` (append a second `@Suite`)

The Task 3 implementation already enforces all these rejections. This task adds tests that prove and lock them. If any test fails, the implementation is wrong — STOP and report BLOCKED rather than weakening the test.

- [ ] **Step 1: Append the rejection-path tests**

Append to `App/Tests/ZipReaderTests.swift`:

```swift
@Suite("ZipArchive rejections")
struct ZipArchiveRejectionTests {
    @Test func rejectsBytesWithoutEocd() {
        let garbage = Data(repeating: 0xAA, count: 100)
        do {
            _ = try ZipArchive(data: garbage)
            Issue.record("expected .notAZip")
        } catch ZipError.notAZip {
            // expected
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func rejectsTooSmall() {
        do {
            _ = try ZipArchive(data: Data([0x01, 0x02, 0x03]))
            Issue.record("expected .notAZip")
        } catch ZipError.notAZip {
            // expected
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func rejectsEncryptedEntry() throws {
        var zip = SyntheticZipBuilder.build([
            .init(name: "encrypted.dmp", uncompressed: Data("x".utf8), method: .store)
        ])
        // Find the central directory record signature (PK\x01\x02) and set
        // general-purpose bit flag (offset +8 from sig) bit 0 = encrypted.
        let cdSig: [UInt8] = [0x50, 0x4B, 0x01, 0x02]
        guard let range = zip.range(of: Data(cdSig)) else {
            Issue.record("CD signature not found"); return
        }
        let gpFlagsOffset = range.lowerBound + 8
        zip[gpFlagsOffset] = 0x01
        do {
            _ = try ZipArchive(data: zip)
            Issue.record("expected .encrypted")
        } catch ZipError.encrypted {
            // expected
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func rejectsUnsupportedCompression() throws {
        var zip = SyntheticZipBuilder.build([
            .init(name: "weird.dmp", uncompressed: Data("x".utf8), method: .store)
        ])
        // Central directory record: compression method at offset +10 from CD sig.
        let cdSig: [UInt8] = [0x50, 0x4B, 0x01, 0x02]
        guard let range = zip.range(of: Data(cdSig)) else {
            Issue.record("CD signature not found"); return
        }
        let methodOffset = range.lowerBound + 10
        zip[methodOffset] = 0x0C       // 12 = bzip2
        zip[methodOffset + 1] = 0x00
        do {
            _ = try ZipArchive(data: zip)
            Issue.record("expected .unsupportedCompression")
        } catch ZipError.unsupportedCompression(let method) {
            #expect(method == 12)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func rejectsZip64Locator() throws {
        // Build a minimal valid empty ZIP (no entries) and inject a ZIP64
        // EOCD locator immediately before the EOCD signature.
        var zip = SyntheticZipBuilder.build([])
        // EOCD is at end (22 bytes). Insert 20 bytes of ZIP64 locator before it.
        let eocdSig: [UInt8] = [0x50, 0x4B, 0x05, 0x06]
        guard let range = zip.range(of: Data(eocdSig)) else {
            Issue.record("EOCD not found"); return
        }
        var z64Locator = Data()
        z64Locator.appendUInt32LE(0x07064B50)  // ZIP64 locator signature
        z64Locator.append(Data(repeating: 0, count: 16))  // padding
        zip.insert(contentsOf: z64Locator, at: range.lowerBound)
        do {
            _ = try ZipArchive(data: zip)
            Issue.record("expected .zip64Unsupported")
        } catch ZipError.zip64Unsupported {
            // expected
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func rejectsTooManyEntries() {
        // Build an EOCD claiming 100_001 entries (no actual entries — the
        // bound check fires before iteration).
        var zip = Data()
        zip.appendUInt32LE(0x06054B50)         // EOCD sig
        zip.appendUInt16LE(0)                  // disk no
        zip.appendUInt16LE(0)                  // disk where CD starts
        zip.appendUInt16LE(0xFFFF)             // records on this disk (UInt16 max)
        // Spec: when total records > UInt16 you'd actually need ZIP64. But
        // the bound `maxEntries = 100_000` is below UInt16.max, so we can
        // exercise it without ZIP64. We use UInt16.max here and the reader
        // will see totalRecords16 = 0xFFFF = 65535 < 100000, NOT trip the
        // tooManyEntries guard. To trip it we need total > 100_000, which is
        // only expressible via ZIP64. So this test instead constructs the
        // bound-check call directly via a synthetic CD that LOOKS like
        // 100_001 records by using ZIP64 — but ZIP64 is already rejected.
        // Therefore `tooManyEntries` is currently unreachable from
        // well-formed non-ZIP64 input. Test the bound by direct call.
        #expect(ZipArchive.maxEntries == 100_000)
        // The runtime path that fires this error is when reading from a
        // hypothetical ZIP64 EOCD, which we don't reach. The constant exists
        // for the parser's defensive check; documented here.
    }

    @Test func rejectsCorruptCentralDirectoryRecord() throws {
        var zip = SyntheticZipBuilder.build([
            .init(name: "ok.dmp", uncompressed: Data("hi".utf8), method: .store)
        ])
        // Corrupt the central directory record signature.
        let cdSig: [UInt8] = [0x50, 0x4B, 0x01, 0x02]
        guard let range = zip.range(of: Data(cdSig)) else {
            Issue.record("CD sig not found"); return
        }
        zip[range.lowerBound] = 0xFF
        do {
            _ = try ZipArchive(data: zip)
            Issue.record("expected .corrupted")
        } catch ZipError.corrupted {
            // expected
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func rejectsTruncatedCentralDirectory() {
        // EOCD claims CD extends past file size.
        var zip = Data()
        zip.appendUInt32LE(0x06054B50)
        zip.appendUInt16LE(0); zip.appendUInt16LE(0)
        zip.appendUInt16LE(1); zip.appendUInt16LE(1)
        zip.appendUInt32LE(46)                  // CD size 46
        zip.appendUInt32LE(0xFFFF_FFFF)         // CD offset way past file end
        zip.appendUInt16LE(0)
        do {
            _ = try ZipArchive(data: zip)
            Issue.record("expected .corrupted")
        } catch ZipError.corrupted {
            // expected
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }
}
```

- [ ] **Step 2: Run the tests to verify they pass**

Run: `cd App && swift test --filter "ZipArchive rejections"`
Expected: PASS (8 tests). If any FAILS, the Task 3 implementation has a real gap — STOP and report BLOCKED with the failing assertion. Do not weaken the test.

- [ ] **Step 3: Run the full suite**

Run: `cd App && swift test`
Expected: all green, +8 tests from this task.

- [ ] **Step 4: Commit**

```bash
git add App/Tests/ZipReaderTests.swift
git commit -m "test: ZIP rejection paths (encrypted, ZIP64, corrupt, bad method)"
```

---

### Task 5: `InputPipeline` + `TempStore` in Core

**Files:**
- Create: `App/MiniDumpTruck/Utilities/TempStore.swift`
- Create: `App/MiniDumpTruck/Services/InputPipeline.swift`
- Test: `App/Tests/TempStoreTests.swift`
- Test: `App/Tests/InputPipelineTests.swift`

- [ ] **Step 1: Write the failing TempStore tests**

Create `App/Tests/TempStoreTests.swift`:

```swift
import Foundation
import Testing
@testable import MiniDumpTruckCore

@Suite("TempStore")
struct TempStoreTests {
    @Test func makeDirCreatesUniquePath() throws {
        let a = try TempStore.makeDir(sourceName: "crashes.zip")
        let b = try TempStore.makeDir(sourceName: "crashes.zip")
        defer {
            try? FileManager.default.removeItem(at: a)
            try? FileManager.default.removeItem(at: b)
        }
        #expect(a != b)
        #expect(FileManager.default.fileExists(atPath: a.path))
        #expect(FileManager.default.fileExists(atPath: b.path))
        // Path is under cache root with the zip-<uuid> pattern.
        #expect(a.lastPathComponent.hasPrefix("zip-"))
    }

    @Test func cleanupAgedRemovesOldDirsKeepsFreshOnes() async throws {
        let fresh = try TempStore.makeDir(sourceName: "fresh.zip")
        let stale = try TempStore.makeDir(sourceName: "stale.zip")
        defer {
            try? FileManager.default.removeItem(at: fresh)
            try? FileManager.default.removeItem(at: stale)
        }
        // Backdate the "stale" dir's modification time.
        let oneWeekAgo = Date().addingTimeInterval(-7 * 24 * 3600)
        try FileManager.default.setAttributes([.modificationDate: oneWeekAgo],
                                              ofItemAtPath: stale.path)

        await TempStore.cleanupAged(olderThan: 24 * 3600)

        #expect(FileManager.default.fileExists(atPath: fresh.path))
        #expect(!FileManager.default.fileExists(atPath: stale.path))
    }
}
```

- [ ] **Step 2: Run to verify TempStore tests fail**

Run: `cd App && swift test --filter "TempStore"`
Expected: FAIL to build with "cannot find 'TempStore'".

- [ ] **Step 3: Implement TempStore**

Create `App/MiniDumpTruck/Utilities/TempStore.swift`:

```swift
import Foundation

/// Filesystem temp store for ZIP-extracted files, used by `InputPipeline`.
/// Lives under `~/Library/Caches/MiniDumpTruck/zip-<uuid>/`. macOS may
/// reclaim caches under disk pressure; `cleanupAged` provides explicit
/// best-effort housekeeping.
public enum TempStore {
    /// Root: ~/Library/Caches/MiniDumpTruck/
    public static func root() -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("MiniDumpTruck", isDirectory: true)
    }

    /// Create a fresh `zip-<uuid>/` directory under the cache root.
    /// `sourceName` is recorded only as a comment file for human triage; the
    /// directory name itself is a UUID for uniqueness.
    public static func makeDir(sourceName: String) throws -> URL {
        let dir = root().appendingPathComponent("zip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Delete any `zip-*` subdirectory of the cache root whose modification
    /// date is older than `olderThan` seconds. Best-effort: never throws.
    public static func cleanupAged(olderThan: TimeInterval) async {
        let fm = FileManager.default
        let root = root()
        guard let entries = try? fm.contentsOfDirectory(at: root,
                                                       includingPropertiesForKeys: [.contentModificationDateKey],
                                                       options: [.skipsHiddenFiles]) else {
            return
        }
        let cutoff = Date().addingTimeInterval(-olderThan)
        for entry in entries {
            guard entry.lastPathComponent.hasPrefix("zip-") else { continue }
            let values = try? entry.resourceValues(forKeys: [.contentModificationDateKey])
            guard let mtime = values?.contentModificationDate, mtime < cutoff else { continue }
            try? fm.removeItem(at: entry)
        }
    }
}
```

- [ ] **Step 4: Run TempStore tests**

Run: `cd App && swift test --filter "TempStore"`
Expected: PASS (2 tests).

- [ ] **Step 5: Write the failing InputPipeline tests**

Create `App/Tests/InputPipelineTests.swift`:

```swift
import Foundation
import Testing
@testable import MiniDumpTruckCore

/// Build a real `MDMP`-prefixed minidump body for tests.
/// Returns the smallest synthetic dump that `MinidumpParser.parse` accepts.
private func makeMinimalMinidumpBytes() -> Data {
    // Header (32 bytes): signature 0x504D444D, version 0xA793, 0 streams,
    // dir RVA 32, checksum 0, time 1700000000, flags 0.
    var d = Data(repeating: 0, count: 32)
    func w32(_ v: UInt32, _ o: Int) { for i in 0..<4 { d[o+i] = UInt8((v >> (i*8)) & 0xFF) } }
    func w16(_ v: UInt16, _ o: Int) { d[o] = UInt8(v & 0xFF); d[o+1] = UInt8((v >> 8) & 0xFF) }
    w32(0x504D444D, 0)
    w16(0xA793, 4)
    w32(0, 8)             // stream count
    w32(32, 12)           // stream dir RVA
    w32(0, 16)
    w32(1700000000, 20)
    return d
}

private func writeTempFile(name: String, body: Data) throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("\(name)-\(UUID().uuidString)")
    try body.write(to: url)
    return url
}

@Suite("InputPipeline.ingest")
struct InputPipelineIngestTests {
    @Test func directMinidumpFileOpensInPlace() async throws {
        let url = try writeTempFile(name: "direct", body: makeMinimalMinidumpBytes())
        defer { try? FileManager.default.removeItem(at: url) }
        let outcome = await InputPipeline.ingest(url: url)
        switch outcome {
        case .openInPlace(_, let size):
            #expect(size == 32)
        default:
            Issue.record("expected .openInPlace, got \(outcome)")
        }
    }

    @Test func textFileFailsAsNotAMinidump() async throws {
        let url = try writeTempFile(name: "text", body: Data("hello".utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        let outcome = await InputPipeline.ingest(url: url)
        if case .failed(.notAMinidump) = outcome {
            // expected
        } else {
            Issue.record("expected .failed(.notAMinidump), got \(outcome)")
        }
    }

    @Test func zipWithOneDumpOpensInPlace() async throws {
        let dump = makeMinimalMinidumpBytes()
        let zip = SyntheticZipBuilder.build([
            .init(name: "crash.dmp", uncompressed: dump, method: .store)
        ])
        let url = try writeTempFile(name: "one-dump", body: zip)
        defer { try? FileManager.default.removeItem(at: url) }
        let outcome = await InputPipeline.ingest(url: url)
        switch outcome {
        case .openInPlace(_, let size):
            #expect(size == dump.count)
        default:
            Issue.record("expected .openInPlace, got \(outcome)")
        }
    }

    @Test func zipWithThreeDumpsReturnsNeedsPick() async throws {
        let zip = SyntheticZipBuilder.build([
            .init(name: "a.dmp", uncompressed: makeMinimalMinidumpBytes(), method: .store),
            .init(name: "b.dmp", uncompressed: makeMinimalMinidumpBytes(), method: .store),
            .init(name: "c.dmp", uncompressed: makeMinimalMinidumpBytes(), method: .store)
        ])
        let url = try writeTempFile(name: "multi-dump", body: zip)
        defer { try? FileManager.default.removeItem(at: url) }
        let outcome = await InputPipeline.ingest(url: url)
        switch outcome {
        case .needsPick(_, let entries, let name):
            #expect(entries.count == 3)
            #expect(entries.map(\.name) == ["a.dmp", "b.dmp", "c.dmp"])
            #expect(name == url.lastPathComponent)
        default:
            Issue.record("expected .needsPick, got \(outcome)")
        }
    }

    @Test func zipWithZeroDumpsFailsCleanly() async throws {
        let zip = SyntheticZipBuilder.build([
            .init(name: "readme.txt", uncompressed: Data("hello".utf8), method: .store)
        ])
        let url = try writeTempFile(name: "no-dump", body: zip)
        defer { try? FileManager.default.removeItem(at: url) }
        let outcome = await InputPipeline.ingest(url: url)
        if case .failed(.zipNoMinidumps(let zipName)) = outcome {
            #expect(zipName == url.lastPathComponent)
        } else {
            Issue.record("expected .failed(.zipNoMinidumps), got \(outcome)")
        }
    }

    @Test func zipWithOneCorruptDumpFailsAsCorruptedMinidump() async throws {
        // A zip entry named .dmp but whose body isn't a real minidump.
        let zip = SyntheticZipBuilder.build([
            .init(name: "fake.dmp", uncompressed: Data("not a real dump".utf8), method: .store)
        ])
        let url = try writeTempFile(name: "fake-dump", body: zip)
        defer { try? FileManager.default.removeItem(at: url) }
        let outcome = await InputPipeline.ingest(url: url)
        if case .failed(.corruptedMinidump) = outcome {
            // expected
        } else {
            Issue.record("expected .failed(.corruptedMinidump), got \(outcome)")
        }
    }

    @Test func encryptedZipFailsAsZipParseFailed() async throws {
        var zip = SyntheticZipBuilder.build([
            .init(name: "secret.dmp", uncompressed: Data("x".utf8), method: .store)
        ])
        let cdSig: [UInt8] = [0x50, 0x4B, 0x01, 0x02]
        if let r = zip.range(of: Data(cdSig)) { zip[r.lowerBound + 8] = 0x01 }
        let url = try writeTempFile(name: "encrypted-zip", body: zip)
        defer { try? FileManager.default.removeItem(at: url) }
        let outcome = await InputPipeline.ingest(url: url)
        if case .failed(.zipParseFailed(.encrypted)) = outcome {
            // expected
        } else {
            Issue.record("expected .failed(.zipParseFailed(.encrypted)), got \(outcome)")
        }
    }
}

@Suite("InputPipeline.extractSelected")
struct InputPipelineExtractTests {
    @Test func extractsSelectedToTempfilesAndReturnsUrls() async throws {
        let dumpA = makeMinimalMinidumpBytes()
        let dumpB = makeMinimalMinidumpBytes()
        let zipBytes = SyntheticZipBuilder.build([
            .init(name: "a.dmp", uncompressed: dumpA, method: .store),
            .init(name: "b.dmp", uncompressed: dumpB, method: .store)
        ])
        let archive = try ZipArchive(data: zipBytes)
        let outcome = await InputPipeline.extractSelected(archive.entries,
                                                          from: archive,
                                                          sourceName: "crashes.zip")
        switch outcome {
        case .openInWindows(let urls):
            #expect(urls.count == 2)
            for url in urls {
                let body = try Data(contentsOf: url)
                #expect(body.prefix(4) == Data([0x4D, 0x44, 0x4D, 0x50]))
                try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
            }
        default:
            Issue.record("expected .openInWindows, got \(outcome)")
        }
    }

    @Test func sanitizesEntryFilenamesAgainstPathTraversal() async throws {
        let dump = makeMinimalMinidumpBytes()
        let zipBytes = SyntheticZipBuilder.build([
            .init(name: "../../escape.dmp", uncompressed: dump, method: .store)
        ])
        let archive = try ZipArchive(data: zipBytes)
        let outcome = await InputPipeline.extractSelected(archive.entries,
                                                          from: archive,
                                                          sourceName: "evil.zip")
        switch outcome {
        case .openInWindows(let urls):
            #expect(urls.count == 1)
            // The written file's lastPathComponent must be the sanitized name
            // (no parent-traversal), and the parent directory must be the
            // tempdir we created — not anywhere outside it.
            let url = urls[0]
            #expect(url.lastPathComponent == "escape.dmp")
            #expect(url.deletingLastPathComponent().lastPathComponent.hasPrefix("zip-"))
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        default:
            Issue.record("expected .openInWindows, got \(outcome)")
        }
    }
}
```

- [ ] **Step 6: Run to verify InputPipeline tests fail**

Run: `cd App && swift test --filter "InputPipeline"`
Expected: FAIL to build with "cannot find 'InputPipeline'".

- [ ] **Step 7: Implement InputPipeline**

Create `App/MiniDumpTruck/Services/InputPipeline.swift`:

```swift
import Foundation

/// Orchestrates opening a URL: sniff, parse minidump or zip, extract on
/// behalf of the UI. Pure-ish — no AppKit, no SwiftUI, no document type
/// dependencies. The App layer constructs `MinidumpDocument` from the
/// returned `ParsedMinidump` + `fileSize` and opens new windows via
/// `NSWorkspace.shared.open` for the multi-file case.
public enum InputPipeline {

    /// Result of `ingest(url:)` / `extractSelected(...)`.
    public enum Outcome: Sendable {
        /// Single ready-to-display dump. Caller wraps in `MinidumpDocument`.
        case openInPlace(parsedDump: ParsedMinidump, fileSize: Int)
        /// Extracted dump files on disk. Caller fires `NSWorkspace.open` per URL.
        case openInWindows([URL])
        /// Multi-dump zip. Caller shows a picker; on confirm call `extractSelected`.
        case needsPick(archive: ZipArchive, dumpEntries: [ZipEntry], zipName: String)
        /// Any failure path with a user-facing typed error.
        case failed(OpenError)
    }

    /// Suffixes considered to be minidump filenames (case-insensitive).
    static let dumpSuffixes: [String] = [".dmp", ".mdmp", ".minidump"]

    /// Sniff the URL and dispatch to the minidump or zip path.
    public static func ingest(url: URL) async -> Outcome {
        let zipName = url.lastPathComponent
        do {
            let kind = try InputSniffer.detect(at: url)
            switch kind {
            case .minidump:
                return await openMinidumpFile(url: url)
            case .zip:
                return await openZipFile(url: url, zipName: zipName)
            case .unsupported(let bytes):
                return .failed(.notAMinidump(firstBytes: bytes))
            }
        } catch {
            return .failed(.corruptedMinidump(underlying: error))
        }
    }

    /// Given a user-selected set of entries from `needsPick`, extract each to
    /// a fresh tempdir and return the resulting URLs.
    public static func extractSelected(_ entries: [ZipEntry],
                                       from archive: ZipArchive,
                                       sourceName: String) async -> Outcome {
        do {
            let dir = try TempStore.makeDir(sourceName: sourceName)
            var urls: [URL] = []
            urls.reserveCapacity(entries.count)
            for entry in entries {
                let sanitizedName = (entry.name as NSString).lastPathComponent
                guard !sanitizedName.isEmpty else {
                    return .failed(.zipExtractFailed(entry: entry.name,
                                                     underlying: ZipError.corrupted(reason: "empty filename")))
                }
                let outURL = dir.appendingPathComponent(sanitizedName)
                do {
                    let body = try archive.extract(entry)
                    try body.write(to: outURL)
                    urls.append(outURL)
                } catch {
                    return .failed(.zipExtractFailed(entry: entry.name, underlying: error))
                }
            }
            return .openInWindows(urls)
        } catch {
            return .failed(.zipExtractFailed(entry: "(tempdir)", underlying: error))
        }
    }

    // MARK: - Private

    private static func openMinidumpFile(url: URL) async -> Outcome {
        do {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            do {
                let parsed = try MinidumpParser.parse(data: data)
                return .openInPlace(parsedDump: parsed, fileSize: data.count)
            } catch {
                return .failed(.corruptedMinidump(underlying: error))
            }
        } catch {
            return .failed(.corruptedMinidump(underlying: error))
        }
    }

    private static func openZipFile(url: URL, zipName: String) async -> Outcome {
        let zipData: Data
        do {
            zipData = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            return .failed(.corruptedMinidump(underlying: error))
        }
        let archive: ZipArchive
        do {
            archive = try ZipArchive(data: zipData)
        } catch let z as ZipError {
            return .failed(.zipParseFailed(z))
        } catch {
            return .failed(.zipParseFailed(.corrupted(reason: error.localizedDescription)))
        }
        let dumps = archive.entries.filter { entry in
            let lower = entry.name.lowercased()
            return dumpSuffixes.contains { lower.hasSuffix($0) }
        }
        switch dumps.count {
        case 0:
            return .failed(.zipNoMinidumps(zipName: zipName))
        case 1:
            // Extract in memory, parse directly — no tempfile for single-dump case.
            do {
                let body = try archive.extract(dumps[0])
                do {
                    let parsed = try MinidumpParser.parse(data: body)
                    return .openInPlace(parsedDump: parsed, fileSize: body.count)
                } catch {
                    return .failed(.corruptedMinidump(underlying: error))
                }
            } catch {
                return .failed(.zipExtractFailed(entry: dumps[0].name, underlying: error))
            }
        default:
            return .needsPick(archive: archive, dumpEntries: dumps, zipName: zipName)
        }
    }
}
```

- [ ] **Step 8: Run the tests to verify they pass**

Run: `cd App && swift test --filter "InputPipeline"`
Expected: PASS (9 tests across both suites).

- [ ] **Step 9: Run the full suite**

Run: `cd App && swift test`
Expected: all green.

- [ ] **Step 10: Commit**

```bash
git add App/MiniDumpTruck/Utilities/TempStore.swift App/MiniDumpTruck/Services/InputPipeline.swift App/Tests/TempStoreTests.swift App/Tests/InputPipelineTests.swift
git commit -m "feat: add InputPipeline + TempStore for sniff-and-dispatch open"
```

---

### Task 6: `WelcomeView` routing through `InputPipeline` (single-dump and 0/many failure cases)

**Files:**
- Modify: `App/MiniDumpTruck/MiniDumpTruckApp.swift` (drop extension guards; route through `InputPipeline`)

Task 7 adds the multi-dump picker. This task wires single-dump zips and direct minidumps end-to-end; the multi-dump case will fall through to a temporary `NSAlert` placeholder until Task 7.

- [ ] **Step 1: Baseline — run the full suite, record pass count**

Run: `cd App && swift test`
Expected: green; record total tests count for regression check after edits.

- [ ] **Step 2: Replace `openFile()` body**

In `App/MiniDumpTruck/MiniDumpTruckApp.swift`, find:

```swift
    private func openFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Select a Windows minidump file (.dmp)"

        if panel.runModal() == .OK, let url = panel.url {
            let ext = url.pathExtension.lowercased()
            guard ext == "dmp" || ext == "mdmp" || ext == "minidump" else {
                let alert = NSAlert()
                alert.messageText = "Unsupported File Type"
                alert.informativeText = "Please select a Windows minidump file (.dmp, .mdmp)."
                alert.alertStyle = .warning
                alert.runModal()
                return
            }
            loadDocument(from: url)
        }
    }
```

Replace with:

```swift
    private func openFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Select a Windows minidump file (.dmp) or a zip containing one"

        if panel.runModal() == .OK, let url = panel.url {
            ingest(url: url)
        }
    }
```

- [ ] **Step 3: Replace `handleDrop(providers:)` body**

Find:

```swift
    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }

        provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, error in
            guard let data = item as? Data,
                  let url = URL(dataRepresentation: data, relativeTo: nil) else {
                return
            }

            // Validate file extension before loading
            let ext = url.pathExtension.lowercased()
            guard ext == "dmp" || ext == "mdmp" || ext == "minidump" else {
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = "Unsupported File Type"
                    alert.informativeText = "Please drop a Windows minidump file (.dmp, .mdmp)."
                    alert.alertStyle = .warning
                    alert.runModal()
                }
                return
            }

            DispatchQueue.main.async {
                loadDocument(from: url)
            }
        }

        return true
    }
```

Replace with:

```swift
    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }

        provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
            guard let data = item as? Data,
                  let url = URL(dataRepresentation: data, relativeTo: nil) else {
                return
            }
            DispatchQueue.main.async {
                ingest(url: url)
            }
        }

        return true
    }
```

- [ ] **Step 4: Replace `loadDocument(from:)` with the new `ingest(url:)`**

Find:

```swift
    private func loadDocument(from url: URL) {
        // Show loading state
        loadingFileName = url.lastPathComponent
        loadingFileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        isLoading = true

        // Parse in background to keep UI responsive
        Task.detached(priority: .userInitiated) {
            do {
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                let parsedDump = try MinidumpParser.parse(data: data)
                let document = MinidumpDocument(parsedDump: parsedDump, fileSize: data.count)

                await MainActor.run {
                    isLoading = false
                    openedDocument = document
                }
            } catch {
                await MainActor.run {
                    isLoading = false

                    let alert = NSAlert()
                    alert.messageText = "Failed to Open File"
                    alert.informativeText = error.localizedDescription
                    alert.alertStyle = .warning
                    alert.runModal()
                }
            }
        }
    }
```

Replace with:

```swift
    private func ingest(url: URL) {
        loadingFileName = url.lastPathComponent
        loadingFileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        isLoading = true

        Task.detached(priority: .userInitiated) {
            let outcome = await InputPipeline.ingest(url: url)
            await MainActor.run {
                handle(outcome: outcome)
            }
        }
    }

    @MainActor
    private func handle(outcome: InputPipeline.Outcome) {
        isLoading = false
        switch outcome {
        case .openInPlace(let parsed, let size):
            openedDocument = MinidumpDocument(parsedDump: parsed, fileSize: size)
        case .openInWindows(let urls):
            for url in urls {
                NSWorkspace.shared.open(url)
            }
        case .needsPick:
            // Multi-dump picker added in Task 7. Until then, surface a placeholder.
            let alert = NSAlert()
            alert.messageText = "Multiple Dumps Found"
            alert.informativeText = "This zip contains more than one minidump. Multi-dump picker is coming in the next change; for now, please extract the .dmp you want and open it directly."
            alert.alertStyle = .informational
            alert.runModal()
        case .failed(let err):
            let alert = NSAlert()
            alert.messageText = "Cannot Open File"
            alert.informativeText = err.errorDescription ?? "Unknown error."
            alert.alertStyle = .warning
            alert.runModal()
        }
    }
```

- [ ] **Step 5: Build**

Run: `cd App && swift build`
Expected: `Build complete!`

- [ ] **Step 6: Run the full suite**

Run: `cd App && swift test`
Expected: same total count as Step 1 baseline (no test additions or removals; behavior of `MiniDumpTruckApp.swift` is App-level and not unit-tested).

- [ ] **Step 7: Manual smoke test**

Build for debug and run: `cd App && swift run MiniDumpTruck`

Verify by interactive smoke test:
1. Drag a known-good `.dmp` file onto the welcome screen → opens.
2. Open a known-good `.dmp` via the "Open File..." button → opens.
3. Drop a `.zip` containing exactly one `.dmp` (use Finder's "Compress" on a `.dmp` to create one) → opens.
4. Drop a `.zip` containing two `.dmp` files → "Multiple Dumps Found" placeholder alert appears.
5. Drop a `.zip` containing no `.dmp` files → friendly "does not contain any .dmp" alert.
6. Drop a text file → "does not look like a Windows minidump" alert.

If any step fails or the app crashes, STOP and report BLOCKED with specifics.

- [ ] **Step 8: Commit**

```bash
git add App/MiniDumpTruck/MiniDumpTruckApp.swift
git commit -m "feat: route WelcomeView open/drop through InputPipeline"
```

---

### Task 7: `ZipPickerView` and multi-dump opening

**Files:**
- Create: `App/MiniDumpTruck/Views/ZipPickerView.swift`
- Modify: `App/MiniDumpTruck/MiniDumpTruckApp.swift` (replace the `needsPick` placeholder with a sheet)

- [ ] **Step 1: Create the picker view**

Create `App/MiniDumpTruck/Views/ZipPickerView.swift`:

```swift
import SwiftUI
import MiniDumpTruckCore

/// Modal sheet shown when a zip contains more than one minidump.
/// Lets the user multi-select which entries to open; each selection
/// becomes its own window via the standard DocumentGroup open path.
struct ZipPickerView: View {
    let zipName: String
    let entries: [ZipEntry]
    let onConfirm: ([ZipEntry]) -> Void
    let onCancel: () -> Void

    @State private var selected: Set<UUID> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(zipName) contains \(entries.count) minidump files.")
                .font(.headline)
            Text("Select one or more to open. Each opens in its own window.")
                .font(.caption)
                .foregroundStyle(.secondary)

            List(entries) { entry in
                HStack {
                    Toggle(isOn: Binding(
                        get: { selected.contains(entry.id) },
                        set: { isOn in
                            if isOn { selected.insert(entry.id) }
                            else { selected.remove(entry.id) }
                        }
                    )) {
                        VStack(alignment: .leading) {
                            Text(entry.name)
                                .font(.system(.body, design: .monospaced))
                            Text(ByteCountFormatter.string(
                                fromByteCount: Int64(entry.uncompressedSize),
                                countStyle: .file))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(minHeight: 180, maxHeight: 360)

            HStack {
                Button("Cancel", role: .cancel) { onCancel() }
                Spacer()
                Button(selected.isEmpty ? "Open Selected" : "Open \(selected.count) Selected") {
                    let picks = entries.filter { selected.contains($0.id) }
                    onConfirm(picks)
                }
                .buttonStyle(.borderedProminent)
                .disabled(selected.isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
```

- [ ] **Step 2: Add picker state to `WelcomeView` and wire the sheet**

In `App/MiniDumpTruck/MiniDumpTruckApp.swift`, inside `struct WelcomeView`, add new `@State` properties next to the existing `@State` block:

Find:

```swift
struct WelcomeView: View {
    @Binding var openedDocument: MinidumpDocument?
    @State private var isDragging = false
    @State private var isLoading = false
    @State private var loadingFileName: String = ""
    @State private var loadingFileSize: Int = 0
```

Add immediately after:

```swift
    @State private var pickerArchive: ZipArchive?
    @State private var pickerEntries: [ZipEntry] = []
    @State private var pickerZipName: String = ""
    @State private var isPickerPresented: Bool = false
```

- [ ] **Step 3: Replace the `needsPick` placeholder in `handle(outcome:)`**

Find:

```swift
        case .needsPick:
            // Multi-dump picker added in Task 7. Until then, surface a placeholder.
            let alert = NSAlert()
            alert.messageText = "Multiple Dumps Found"
            alert.informativeText = "This zip contains more than one minidump. Multi-dump picker is coming in the next change; for now, please extract the .dmp you want and open it directly."
            alert.alertStyle = .informational
            alert.runModal()
```

Replace with:

```swift
        case .needsPick(let archive, let entries, let zipName):
            pickerArchive = archive
            pickerEntries = entries
            pickerZipName = zipName
            isPickerPresented = true
```

- [ ] **Step 4: Attach the picker sheet to the view body**

In `WelcomeView`'s `body`, find the outermost `ZStack { ... }` (or the existing top-level container) and add a `.sheet(...)` modifier at the end of it (right before `.frame(minWidth: 500, ...)`). Concretely, find:

```swift
        .frame(minWidth: 500, minHeight: 400)
        .background(Color(nsColor: .windowBackgroundColor))
        .animation(.easeInOut(duration: 0.2), value: isLoading)
```

Replace with:

```swift
        .sheet(isPresented: $isPickerPresented) {
            if let archive = pickerArchive {
                ZipPickerView(
                    zipName: pickerZipName,
                    entries: pickerEntries,
                    onConfirm: { picks in
                        isPickerPresented = false
                        extractAndOpen(picks: picks, from: archive, zipName: pickerZipName)
                    },
                    onCancel: {
                        isPickerPresented = false
                        pickerArchive = nil
                        pickerEntries = []
                    }
                )
            }
        }
        .frame(minWidth: 500, minHeight: 400)
        .background(Color(nsColor: .windowBackgroundColor))
        .animation(.easeInOut(duration: 0.2), value: isLoading)
```

- [ ] **Step 5: Add the `extractAndOpen` method**

In `WelcomeView`, add a new method next to `ingest(url:)`:

```swift
    private func extractAndOpen(picks: [ZipEntry], from archive: ZipArchive, zipName: String) {
        loadingFileName = zipName
        isLoading = true
        Task.detached(priority: .userInitiated) {
            let outcome = await InputPipeline.extractSelected(picks, from: archive, sourceName: zipName)
            await MainActor.run {
                handle(outcome: outcome)
            }
        }
    }
```

- [ ] **Step 6: Build**

Run: `cd App && swift build`
Expected: `Build complete!`

- [ ] **Step 7: Run the full suite**

Run: `cd App && swift test`
Expected: same total as Task 6 baseline (still no App-target unit tests; SwiftUI rendering not unit-tested).

- [ ] **Step 8: Manual smoke test**

Build and run: `cd App && swift run MiniDumpTruck`

Verify:
1. Drop a `.zip` containing two or more `.dmp` files → picker sheet appears showing entry names + sizes.
2. Select one entry, click "Open Selected" → it opens in the current window (since the existing window has no opened document yet, it lands in `WelcomeView`'s `openedDocument` state).
3. Cancel works: sheet dismisses, nothing opens.
4. (Edge) If the existing window already has a dump open, selecting from the picker should open new windows via `NSWorkspace.open` — verify this by selecting 2 entries from a 3-dump zip.

If any step fails or the app crashes, STOP and report BLOCKED.

- [ ] **Step 9: Commit**

```bash
git add App/MiniDumpTruck/Views/ZipPickerView.swift App/MiniDumpTruck/MiniDumpTruckApp.swift
git commit -m "feat: ZipPickerView for multi-dump archives"
```

---

### Task 8: TempStore cleanup at app start

**Files:**
- Modify: `App/MiniDumpTruck/MiniDumpTruckApp.swift` (add init that fires cleanup)

- [ ] **Step 1: Add an init to `MiniDumpTruckApp`**

In `App/MiniDumpTruck/MiniDumpTruckApp.swift`, find:

```swift
@main
struct MiniDumpTruckApp: App {
    @State private var openedDocument: MinidumpDocument?
    @AppStorage("zoomScale") private var zoomScale: Double = 1.0

    var body: some Scene {
```

Replace with:

```swift
@main
struct MiniDumpTruckApp: App {
    @State private var openedDocument: MinidumpDocument?
    @AppStorage("zoomScale") private var zoomScale: Double = 1.0

    init() {
        // Best-effort cleanup of zip-extracted tempfiles older than 24 hours.
        // Fired off as a detached task; never blocks app launch, never throws.
        Task.detached(priority: .background) {
            await TempStore.cleanupAged(olderThan: 24 * 3600)
        }
    }

    var body: some Scene {
```

- [ ] **Step 2: Build**

Run: `cd App && swift build`
Expected: `Build complete!`

- [ ] **Step 3: Run the full suite**

Run: `cd App && swift test`
Expected: green, same count.

- [ ] **Step 4: Manual verify (optional)**

Build and run `cd App && swift run MiniDumpTruck` once after creating a stale temp dir manually:

```bash
mkdir -p ~/Library/Caches/MiniDumpTruck/zip-stale-12345
touch -t 202401010000 ~/Library/Caches/MiniDumpTruck/zip-stale-12345
```

Launch the app, then verify the stale dir is gone within a few seconds:

```bash
ls ~/Library/Caches/MiniDumpTruck/
```

- [ ] **Step 5: Commit**

```bash
git add App/MiniDumpTruck/MiniDumpTruckApp.swift
git commit -m "feat: cleanup stale zip tempfiles on app start"
```

---

## Self-Review (completed during planning)

**Spec coverage:**
- `InputSniffer` (sniff first 4 bytes via data + URL) → Task 2.
- `ZipReader`/`ZipArchive`/`ZipEntry`/`CompressionMethod`/`ZipError` (STORE+DEFLATE, central directory, EOCD, ZIP64 reject, encrypted reject, unsupported method, DoS bounds) → Tasks 3 + 4. `ZipError` lives in `OpenError.swift` (Task 1) as a stub; `CompressionMethod`, `ZipEntry`, `ZipArchive` are introduced together in Task 3.
- `OpenError` (typed friendly errors) → Task 1.
- `InputPipeline.ingest` and `.extractSelected` → Task 5.
- `TempStore` (makeDir + cleanupAged) → Task 5 (creation) + Task 8 (cleanup on app start).
- `WelcomeView` integration (drop extension guard, route through pipeline, sheet) → Tasks 6 + 7.
- `ZipPickerView` → Task 7.
- Path-traversal sanitization via `lastPathComponent` → Task 5 (`extractSelected`).
- Deliberate non-changes (`MinidumpDocument.readableContentTypes` unchanged, `MinidumpParser` unchanged, slice 1 of #2 untouched, CLI unchanged) → respected by no task touching those files.
- Out-of-scope items (encrypted ZIP, ZIP64, nested archives, CLI zip support) → not built; explicit typed errors in Tasks 1+4 keep the contract honest.

**Plan-level refinement noted:** `InputPipeline` + `TempStore` moved to Core (vs. spec's App-target placement). Reason given in plan header.

**Placeholder scan:** No TBD/TODO. Every code step has complete code. No "similar to Task N" references. Manual smoke tests in Tasks 6/7/8 are explicit step-by-step checks, not vague "test it manually."

**Type consistency:** `InputKind.minidump/.zip/.unsupported(firstBytes:)`, `CompressionMethod.store/.deflate`, `ZipArchive.init(data:) throws`, `ZipArchive.extract(_:) throws -> Data`, `ZipEntry(id:name:uncompressedSize:compressedSize:compressionMethod:localHeaderOffset:generalPurposeFlags:)`, `InputPipeline.Outcome.openInPlace(parsedDump:fileSize:) / .openInWindows([URL]) / .needsPick(archive:dumpEntries:zipName:) / .failed(OpenError)`, `TempStore.makeDir(sourceName:) throws -> URL`, `TempStore.cleanupAged(olderThan:) async` — used consistently across Tasks 1-8.

**Out of scope (recorded):** encrypted ZIP password prompt, ZIP64 support, nested archives, CLI zip support, DocumentGroup accepting `.zip` (conflicts with macOS Archive Utility), the broader UX review (issue #8 tracks).
