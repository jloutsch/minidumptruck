# Frictionless Input: Zip Pass-Through + Content Sniffing + Friendly Failure

Date: 2026-05-20
Issue: #6 (Frictionless input: open dumps from attachments, zips, and tickets with zero setup)
Branch: feat/6-frictionless-input
Scope: zip pass-through, content-based detection (drop the extension guard),
typed friendly error UX. Companion issue #8 tracks the broader UX review.

## Problem and persona

Today MiniDumpTruck only opens files whose name ends in `.dmp`, `.mdmp`, or
`.minidump`. Both the welcome-screen `NSOpenPanel` and the drag-drop handler
in `MiniDumpTruckApp.swift` enforce that extension before reading a byte.
Real-world attachments fail this check in two common ways:

- A DFIR / incident-response engineer receives a `crashes.zip` in a ticket
  containing one or more `.dmp` files. macOS extension check rejects the
  zip; the user has to manually unzip first.
- A Mail attachment arrives named `attachment` or `crash` with no
  extension (or `.bin`) and is rejected even when the bytes are a valid
  minidump.

The target persona is the support / IR / DFIR engineer on a Mac handed a
crash dump in a ticket. They want to drop a file in and get a routing
verdict in minutes with no setup. The current extension guard, combined
with no zip support, is the user-facing friction this issue removes.

## Guiding principle

Bytes decide, not filenames. The current extension guard is filename-
trust; we replace it with content-trust (sniff the first 4 bytes) plus
explicit support for the one common wrapper (ZIP). Failures stay fast and
human-readable. The principle inherited from slice 1 of #2 also holds:
honest "I cannot do that" beats silent "I will guess wrong."

## Scope boundary

In scope:

- ZIP pass-through. Accept a `.zip` whose entries include one or more
  `.dmp` / `.mdmp` / `.minidump` files. Single entry opens directly.
  Multiple entries trigger a picker; selected entries open in their own
  windows via the existing `DocumentGroup` multi-window mechanism.
- Content-based detection. Drop the extension guard. Sniff the first 4
  bytes of the input. `MDMP` -> parse as minidump. `PK\x03\x04` -> parse
  as zip. Anything else -> friendly error.
- Friendly typed errors. A new `OpenError` enum with `LocalizedError`
  conformance replaces technical parser strings at the UI boundary. Each
  case carries enough context to be actionable.
- Hand-rolled minimal ZIP reader. Parse the ZIP central directory
  ourselves. Decompress with `Compression.framework` (system, no
  dependency). Supported compression: STORE (no compression) and
  DEFLATE. Unsupported variants (encrypted, ZIP64, other methods) return
  explicit typed errors.

Out of scope, recorded so they are not forgotten:

- Encrypted ZIP support. Tell the user to decrypt first.
- ZIP64 / entries over 4 GB. Tell the user the limit, point at follow-up.
- Nested archives (zip-of-zip-of-dump).
- CLI zip handling (`minidumptruck-cli analyze crashes.zip`). Own issue.
- `DocumentGroup` accepting `.zip` as a readable type. macOS Archive
  Utility owns `.zip` by default; routing zips through Welcome avoids
  conflicting with platform behavior.
- The broader UX review (issue #8 tracks).

## Architecture (Approach A)

Five new units plus targeted edits to `WelcomeView`. The parser lives in
`MiniDumpTruckCore`; the UI pipeline lives in the App target.

### `Utilities/InputSniffer.swift` (Core, new)

```
public enum InputKind: Sendable, Equatable {
    case minidump
    case zip
    case unsupported(firstBytes: [UInt8])
}
public enum InputSniffer {
    public static func detect(from data: Data) -> InputKind
    public static func detect(at url: URL) throws -> InputKind
}
```

`detect(from:)` reads the first 4 bytes of `data`. `detect(at:)` opens the
file via `FileHandle(forReadingFrom:)`, reads at most 4 bytes, closes.
This avoids mmap'ing a 500 MB zip just to learn whether it is a minidump.

Signatures (all little-endian):
- `0x504D444D` -> `.minidump` (MDMP)
- `0x04034B50` -> `.zip` (PK\x03\x04)
- anything else -> `.unsupported(firstBytes: [...])`

### `Utilities/ZipReader.swift` (Core, new)

```
public struct ZipArchive: Sendable {
    public let entries: [ZipEntry]
    public init(data: Data) throws
    public func extract(_ entry: ZipEntry) throws -> Data
}
public struct ZipEntry: Sendable, Identifiable {
    public let id: UUID
    public let name: String
    public let uncompressedSize: UInt32
    public let compressedSize: UInt32
    public let compressionMethod: CompressionMethod
    /// File offset of the local file header (used by extract).
    internal let localHeaderOffset: UInt32
    internal let generalPurposeFlags: UInt16
}
// NOTE: ZipEntry is intentionally NOT Equatable. Synthesized Equatable
// would compare the UUID id, so two entries with identical content but
// different ids would be unequal — a footgun. No pipeline code path
// requires Equatable on ZipEntry.
public enum CompressionMethod: UInt16, Sendable {
    case store = 0
    case deflate = 8
}
public enum ZipError: Error, LocalizedError {
    case notAZip
    case corrupted(reason: String)
    case encrypted
    case zip64Unsupported
    case unsupportedCompression(method: UInt16)
    case entryTooLarge(actual: UInt32, limit: UInt32)
    case tooManyEntries(actual: UInt64, limit: UInt64)
    /// Returns user-facing text per the "Friendly text contract" in OpenError
    /// (ZipError messages are surfaced via OpenError.zipParseFailed).
    public var errorDescription: String? { ... }
}
```

Algorithm (`ZipArchive.init`):
1. Find the End of Central Directory (EOCD) record. Search backwards
   from end of file for signature `0x06054B50`, scanning at most the
   last 64 KB (per ZIP spec for non-ZIP64).
2. If a ZIP64 EOCD locator (`0x07064B50`) is found, throw
   `.zip64Unsupported`.
3. From EOCD, read: number of central directory records, central
   directory size, central directory offset. Bounds-check all three.
4. Iterate central directory records. For each: validate signature
   (`0x02014B50`), parse fields, check general-purpose bit 0 (encryption)
   -> throw `.encrypted`. Check compression method -> if not 0 or 8,
   throw `.unsupportedCompression`. Capture `localHeaderOffset`.

Algorithm (`ZipArchive.extract`):
1. Seek to `localHeaderOffset`, validate local header signature
   (`0x04034B50`), parse local-header fields, skip filename and extra
   field to reach compressed data.
2. STORE: return the slice directly (after bounds checks).
3. DEFLATE: feed compressed bytes to `Compression.framework`'s raw
   `COMPRESSION_ZLIB` decoder (raw deflate stream, no zlib header), read
   until `uncompressedSize` bytes are produced.
4. Verify produced byte count matches `uncompressedSize` exactly. Mismatch -> `.corrupted`.

DoS bounds (mirror slice 1's pattern):
- `maxEntries = 100_000`
- `maxUncompressedSize = 0xFFFFFFFF` (4 GB - 1; ZIP non-64 hard limit)
- `maxCentralDirectorySize = 32 * 1024 * 1024` (32 MB)
- All offset arithmetic via `addingReportingOverflow` / `&+`. Every read
  bounds-checked against `data.count`.

### `Models/OpenError.swift` (Core, new)

```
public enum OpenError: Error, LocalizedError {
    case notAMinidump(firstBytes: [UInt8])
    case corruptedMinidump(underlying: Error)
    case zipParseFailed(ZipError)
    case zipNoMinidumps(zipName: String)
    case zipExtractFailed(entry: String, underlying: Error)
    /// Returns user-facing text per the "Friendly text contract" below.
    public var errorDescription: String? { ... }
}
```

Friendly text contract per case:
- `notAMinidump(bytes)` -> "This file does not look like a Windows
  minidump. (First bytes: <hex>.)"
- `corruptedMinidump(err)` -> "This minidump appears to be truncated or
  corrupt: <underlying.localizedDescription>."
- `zipParseFailed(.encrypted)` -> "This zip is encrypted. Extract it
  with the password first, then open the .dmp."
- `zipParseFailed(.zip64Unsupported)` -> "This zip uses the ZIP64 format
  (over 4 GB), which is not supported yet."
- `zipParseFailed(.unsupportedCompression(m))` -> "This zip uses
  compression method <m>, which is not supported. Re-create the zip with
  standard deflate."
- `zipNoMinidumps(name)` -> "<name> does not contain any .dmp / .mdmp /
  .minidump files."
- `zipExtractFailed(entry, err)` -> "Could not extract <entry> from the
  zip: <underlying>."

### `InputPipeline.swift` (App target, new)

```
@MainActor enum InputPipeline {
    enum Outcome {
        case openInPlace(MinidumpDocument)
        case openInWindows([URL])
        case needsPick(archive: ZipArchive, dumpEntries: [ZipEntry], zipName: String)
        case failed(OpenError)
    }
    static func ingest(url: URL) async -> Outcome
    static func extractSelected(_ entries: [ZipEntry],
                                from archive: ZipArchive,
                                sourceName: String) async -> Outcome
}
```

`ingest(url:)`:
1. `InputSniffer.detect(at: url)`.
2. `.minidump`: `Data(contentsOf: url, options: .mappedIfSafe)` ->
   `MinidumpParser.parse(data:)`. Success -> `.openInPlace`. Throws ->
   `.failed(.corruptedMinidump)`.
3. `.zip`: load full bytes -> `ZipArchive(data:)`. Filter entries by
   case-insensitive suffix in `.dmp`, `.mdmp`, `.minidump`.
   - 0 entries -> `.failed(.zipNoMinidumps)`.
   - 1 entry -> extract -> parse -> `.openInPlace`.
   - N entries -> `.needsPick`.
4. `.unsupported(bytes)` -> `.failed(.notAMinidump(firstBytes: bytes))`.
5. Any `ZipError` -> `.failed(.zipParseFailed)`.

`extractSelected(entries:from:sourceName:)`:
1. `TempStore.makeDir(sourceName:)` -> `~/Library/Caches/MiniDumpTruck/
   zip-<uuid>/`.
2. For each entry, sequentially: `archive.extract(entry)` -> write to
   `<dir>/<sanitized-name>`. Any failure -> abort, return
   `.failed(.zipExtractFailed)`. Do not leave the user with half their
   windows opened.
3. On all-successful: `.openInWindows([URL])`.

### `ZipPickerView.swift` (App target, new)

A minimal SwiftUI sheet:

- Title: "<zipName> contains <N> minidump files."
- `List` of entries, each row: `Toggle` + filename + size formatted via
  `ByteCountFormatter`.
- "Open N Selected" primary button (disabled when 0 selected). Live count
  in the label.
- "Cancel" secondary button.
- Forwards selection to an `onConfirm: ([ZipEntry]) -> Void` closure;
  parent (Welcome) calls `extractSelected` -> `NSWorkspace.open` per URL.

### `TempStore.swift` (App target, new)

```
enum TempStore {
    static func makeDir(sourceName: String) throws -> URL
    static func cleanupAged(olderThan: TimeInterval) async
    /// Test-injectable clock for cleanupAged tests.
    static var now: () -> Date = Date.init
}
```

- Base path: `~/Library/Caches/MiniDumpTruck/zip-<uuid>/`.
- `cleanupAged` runs on app start (best-effort, never throws to the user),
  deletes any `zip-*` directory whose modification date is older than
  `olderThan` (24 hours).
- macOS will also reclaim caches under disk pressure; this is belt and
  suspenders.

### `WelcomeView` changes (App target, modify)

In `MiniDumpTruckApp.swift`:

- `openFile()`: remove the extension check (`ext == "dmp" || ...`). Keep
  `NSOpenPanel.allowedContentTypes = [.data]`. Route the chosen URL into
  `InputPipeline.ingest(url:)`.
- `handleDrop(providers:)`: remove the extension check inside the closure.
  Route the dropped URL into `InputPipeline.ingest(url:)`.
- New state: `@State private var pickerArchive: ZipArchive?`,
  `@State private var pickerEntries: [ZipEntry] = []`,
  `@State private var pickerZipName: String = ""`. When set,
  `.sheet(isPresented:)` shows `ZipPickerView`.
- New routing on `InputPipeline.Outcome`:
  - `.openInPlace(doc)` -> `openedDocument = doc`.
  - `.openInWindows(urls)` -> for each, `NSWorkspace.shared.open(url)`.
  - `.needsPick(archive, entries, name)` -> populate picker state, show
    sheet. On confirm: call `extractSelected`, switch on result.
  - `.failed(err)` -> `NSAlert` with `err.errorDescription`.

### Deliberate non-changes

- `MinidumpDocument.readableContentTypes` stays `[.minidump, .data]`. Not
  adding `.zip`. Reason: macOS Finder hands `.zip` to Archive Utility for
  unarchiving by default; adding `.zip` to `MinidumpDocument` would create
  a confusing "which app opens this" dialog. Zips go through Welcome only.
- `MinidumpParser` unchanged.
- `CrashAnalyzer` and slice 1 of #2 untouched.
- CLI unchanged.

## Data flow

```
WelcomeView.openFile / .handleDrop
    -> InputPipeline.ingest(url)
       -> InputSniffer.detect(at: url)
          -> .minidump: Data(contentsOf:url:.mappedIfSafe)
                         -> MinidumpParser.parse(data:)
                            -> .openInPlace(MinidumpDocument)
                            or .failed(.corruptedMinidump)
          -> .zip:      Data(contentsOf:url) -> ZipArchive(data:)
                         -> filter dump entries
                            -> 0: .failed(.zipNoMinidumps)
                            -> 1: extract -> parse -> .openInPlace
                            -> N: .needsPick(archive, entries, name)
          -> .unsupported(b): .failed(.notAMinidump(firstBytes: b))
ZipPickerView (on confirm)
    -> InputPipeline.extractSelected(entries, archive, sourceName)
       -> TempStore.makeDir(sourceName)
       -> for each: archive.extract -> write to tempdir
          -> on any failure: .failed(.zipExtractFailed)
       -> .openInWindows([URL])
          -> for each URL: NSWorkspace.shared.open(url)
             -> macOS DocumentGroup opens each in its own window
```

## Error handling

Mirrors slice 1's pattern: failable / throwing `init`, no force-unwraps,
no `fatalError` in production. Every typed error case has a friendly
`localizedDescription`. The UI never shows a Swift error
type-name to the user.

- ZIP reader: failable `init` becomes throwing for ZIP because the error
  variants matter for the UI message. `extract` throws too.
- Overflow-safe arithmetic on every offset (`addingReportingOverflow`,
  `&+`, `&*`).
- Bounds-check every read against `data.count`. Reject negative or
  oversized fields immediately.
- `InputPipeline` never crashes on bad input. The worst case is a
  `.failed(...)` outcome with a clear message.
- `NSWorkspace.open` failures: macOS may reject a file; we surface the
  per-file failure as a one-line message but continue with the rest. (Edge
  case worth handling; a malformed `NSWorkspace` reject should not abort
  other selected dumps.)
- Tempfile path sanitization: ZIP entry names containing `..` or
  starting with `/` are normalized to their last path component
  (`Foundation.URL.lastPathComponent`) before writing, so a crafted zip
  cannot write outside the tempdir.

## Testing strategy (TDD)

All synthetic bytes; no test data files. Matches slice 1 conventions:
Swift Testing (`import Testing`, `@Suite`, `@Test`, `#expect`,
`try #require`); `@testable import MiniDumpTruckCore`.

### `InputSnifferTests` (Core)
- Minidump signature -> `.minidump`.
- ZIP signature -> `.zip`.
- Empty data -> `.unsupported([])`.
- 1-3 byte data (under 4 bytes) -> `.unsupported(...)`.
- Arbitrary bytes -> `.unsupported(firstBytes: ...)`.
- File-based variant: write a 1 MB temp file with MDMP prefix; assert
  `detect(at: url)` returns `.minidump` AND reads at most 4 bytes
  (verifiable via `FileHandle.offsetInFile` after the call).

### `ZipReaderTests` (Core)

Helper `makeZip(entries:[(name:String, data:Data, method:CompressionMethod)])`
builds a synthetic ZIP buffer: local file headers + compressed data +
central directory + EOCD. Tests:
- Single STORE entry round-trip (extract == original).
- Single DEFLATE entry round-trip (compress via `Compression.framework`
  in the test helper, then verify extract matches).
- Multiple entries: iteration order matches central directory.
- `.notAZip`: garbage bytes / no EOCD signature.
- `.encrypted`: general-purpose bit 0 set on a central directory record.
- `.zip64Unsupported`: synthetic ZIP64 EOCD locator present.
- `.unsupportedCompression(12)`: method = 12 (bzip2) in central directory.
- `.corrupted("truncated")`: declared size larger than file.
- `.entryTooLarge`: uncompressedSize at the 4 GB limit + 1.
- `.tooManyEntries`: EOCD claims 100_001 records.

### `OpenErrorTests` (Core)
- Each case's `errorDescription` is non-empty and contains the expected
  context (zip name, byte values, underlying message).

### `InputPipelineTests` (App; or move to Core if possible by parameterizing)

Build synthetic files in `NSTemporaryDirectory()`:
- URL with MDMP-prefixed bytes -> `.openInPlace`.
- URL with synthetic zip containing one valid MDMP entry -> `.openInPlace`.
- URL with synthetic zip containing three dump entries -> `.needsPick`
  with 3 entries.
- URL with synthetic zip containing zero dump entries -> `.failed(.zipNoMinidumps)`.
- URL with text file -> `.failed(.notAMinidump)`.
- URL with synthetic zip containing one entry whose body is NOT MDMP ->
  `.failed(.corruptedMinidump)`.

### `TempStoreTests` (App)
- `makeDir(sourceName:)` creates a unique path under the cache dir.
- `cleanupAged(olderThan:)` deletes dirs older than TTL, preserves fresh
  ones. Uses `TempStore.now` injection for a deterministic clock.

### `ZipPickerView`
No unit test (SwiftUI rendering). Behavior is dumb: forwards selected
entries to closure. Manual smoke test in App.

### Regression
Full existing test suite (553 on `main` plus or minus the merge state)
remains green. None of this touches `MinidumpParser`, `CrashAnalyzer`,
slice 1 of #2, or any existing exporter / view.

## Post-v1 follow-ups (recorded, not lost)

1. Encrypted ZIP support. Today's error suggests decrypting first; v2
   could prompt for password and stream-decrypt.
2. ZIP64 / entries over 4 GB. The friendly error names the limit; v2 can
   lift it by parsing the ZIP64 EOCD locator and central directory
   extra fields.
3. Nested archives (.zip in .zip in .dmp). Not seen in DFIR practice;
   skip unless real users ask.
4. CLI zip handling (`minidumptruck-cli analyze crashes.zip`). Own
   issue. Reuses Core `ZipArchive` and `InputSniffer`.
5. Drag-and-drop multi-zip (drop two zips at once into Welcome). Today
   we handle the first provider; iterating providers is a small follow-up.
