# Symbolication, Slice 1: Offline PE Export-Table Resolution

Date: 2026-05-19
Issue: #2 (Symbolication: resolve function names via PDB / symbol server)
Scope: Slice 1 of 3 only. Slices 2 (public Microsoft symbol server) and 3
(user-configured private symbol path) are out of scope for this work.

## Problem and persona

Today the analyzer outputs addresses plus module names. Call stacks for
stripped/optimized release dumps show `module+0x9a3c4` instead of function
names. The wedge user is a support / IT / escalation engineer on a Mac who is
handed a `.dmp` and needs a routing verdict in minutes, with no Windows, no
symbol setup, and no network.

Slice 1 delivers function names for **exported** functions using only the
dump's own captured memory. No network, no configuration, no security surface.
It turns `ntdll+0x9a3c4` into `ntdll!NtWaitForSingleObject+0x14`, which is
exactly the OS/driver routing signal that persona needs.

## Guiding principle

A wrong function name is worse than an honest `module+0xNN`. A wrong name
routes a support ticket to the wrong team. Every judgment call in this design
biases toward "no name" over "possibly wrong name."

## Scope boundary

In scope:

- Parse the loaded PE image's export table from dump memory.
- Resolve a code address to the nearest exported function entry plus a byte
  delta.
- Surface resolved names in the crash analysis views and all four exporters.
- Extract the duplicated dump-memory read logic into one reusable unit.

Out of scope (tracked elsewhere):

- Public Microsoft symbol server fetch and cache (issue #2, slice 2).
- User-configured / corporate symbol store for private app PDBs (issue #2,
  slice 3).
- Improved stack walking via unwind info (issue #3).
- Frictionless input handling (issue #6).
- Forwarder-string resolution (see Post-v1 follow-ups).
- Max-delta tuning against real dumps (see Post-v1 follow-ups).

## Architecture (Approach A)

Three new units plus two small modifications. Each unit has one purpose, a
defined interface, and is independently testable.

### `Utilities/DumpMemoryReader.swift` (new)

Wraps a dump's memory streams. Lifts the `Memory64List -> MemoryList`
fallback currently private in `CrashAnalyzer.swift:385-390` into one reusable
unit so the logic is not duplicated.

```
struct DumpMemoryReader: Sendable {
    init(dump: ParsedMinidump)
    func read(at: UInt64, size: Int) -> Data?      // memory64List first, then memoryList
    func readUInt64(at: UInt64) -> UInt64?
    func readUInt32(at: UInt64) -> UInt32?
    func readUInt16(at: UInt64) -> UInt16?         // needed for export ordinals and the optional-header magic
}
```

`CrashAnalyzer` is refactored to use this instead of its private copy. The
extraction is behavior-preserving; the existing 531-test suite is the
regression guard.

### `Models/PEImage.swift` (new)

Parses a loaded PE image's export table from a `DumpMemoryReader`, given a
module's `baseAddress` and `sizeOfImage`. House style: failable init,
overflow-safe arithmetic, DoS caps.

```
struct PEExportTable: Sendable {
    init?(reader: DumpMemoryReader, imageBase: UInt64, imageSize: UInt32)
    // sorted [(functionRVA, name)] for named exports; forwarders skipped in v1
    func symbol(forImageOffset: UInt64) -> (name: String, delta: UInt64)?
}
```

### `Services/Symbolicator.swift` (new)

Built once from a `ParsedMinidump`. Eagerly parses every module's export
table into an immutable `[baseAddress: PEExportTable]` at init, so it stays a
`Sendable` value with no locking. Eager over lazy is a deliberate YAGNI
decision: module counts are bounded and parsing is cheap header reads.
Laziness is a later optimization only if a profile shows it matters.

```
struct Symbolicator: Sendable {
    init(dump: ParsedMinidump)
    func resolve(address: UInt64) -> ResolvedSymbol?
}
struct ResolvedSymbol: Sendable, Codable {
    let function: String
    let offsetInFunction: UInt64
}
```

### `StackFrame` (modified, `CrashAnalysis.swift:19`)

Add `let symbol: ResolvedSymbol?`, defaulting to `nil` in the initializer so
existing direct constructors in tests keep compiling. `displayAddress`
becomes:

- `module!function+0xNN` when a symbol exists,
- else the current `module+0xNN`,
- else `0x%016llX`.

Add `symbol` to `CodingKeys` so JSON export carries structured symbol fields
automatically.

### `CrashAnalyzer` (modified)

Holds a `Symbolicator` built in init. `createFrame`
(`CrashAnalyzer.swift:367`) calls `resolve` and passes the symbol into
`StackFrame`. No change to stack-walking logic (that is issue #3).

## Data flow

```
CrashAnalyzer.init(dump)
  └─ Symbolicator(dump)
       └─ for each module in dump.moduleList:
            PEExportTable(reader: DumpMemoryReader(dump),
                          imageBase: module.baseAddress,
                          imageSize: module.sizeOfImage)
            → store in [baseAddress: PEExportTable]   (skip modules with no/unreadable exports)

CrashAnalyzer.walkStack → createFrame(address)
  ├─ module = dump.moduleList.module(containing: address)      (unchanged)
  ├─ symbol = symbolicator.resolve(address)
  └─ StackFrame(address, module, offsetInModule, symbol, type, confidence)
```

## Resolution algorithm

`PEExportTable.init?` parse steps. All reads go through `DumpMemoryReader` at
`imageBase + rva`. Every read is bounds-checked against `imageSize` and reader
availability, with overflow-safe arithmetic.

1. DOS header: `e_magic == 0x5A4D` ("MZ"); read `e_lfanew` at
   `imageBase + 0x3C`.
2. NT headers at `imageBase + e_lfanew`: signature `== 0x00004550` ("PE\0\0").
3. File header: read `SizeOfOptionalHeader`.
4. Optional header magic: `0x10B` = PE32, `0x20B` = PE32+. This only shifts
   where the data directory array starts (the PE32+ optional header is 16
   bytes larger before the directories). Export directory is
   `DataDirectory[0]` -> `(exportRVA, exportSize)`. Both 32-bit and 64-bit
   modules resolve; this is pure PE and architecture-agnostic.
5. `IMAGE_EXPORT_DIRECTORY` at `imageBase + exportRVA`: read
   `NumberOfNames`, `AddressOfFunctions`, `AddressOfNames`,
   `AddressOfNameOrdinals`, `Base`.
6. For `i in 0..<NumberOfNames`, capped at `maxExports = 200_000`
   (mirrors `ModuleList.maxModules`):
   - `nameRVA = u32(AddressOfNames + i*4)`
   - `ordinal = u16(AddressOfNameOrdinals + i*2)`
   - `funcRVA = u32(AddressOfFunctions + ordinal*4)`
   - Forwarder check: if `funcRVA` is inside
     `[exportRVA, exportRVA + exportSize)`, it is a forwarder string. Skip in
     v1.
   - `name` = C-string scan at `imageBase + nameRVA`, bounded by both
     `imageSize` and a max symbol-name length (`maxNameLength = 4096`) so a
     malformed table cannot drive an unbounded scan.
   - collect `(funcRVA, name)`.
7. Sort by `funcRVA` ascending. Empty result -> `init?` returns nil; the
   module contributes no symbols.

`symbol(forImageOffset:)`: binary search for the greatest `funcRVA <= offset`;
return `(name, offset - funcRVA)`.

`Symbolicator.resolve(address:)`:

- module = `module(containing: address)`; else nil.
- `imageOffset = address - module.baseAddress`.
- table lookup -> `(name, delta)`.
- Max-delta guard: if `delta > maxFunctionSpan` (`0x40000`, 256 KB) return
  nil. Export tables list only entry points; an address far past the nearest
  export is almost certainly unexported/static code, and a wrong name is worse
  than `module+0xNN`.
- else `ResolvedSymbol(function: name, offsetInFunction: delta)`.

The tunable constants are `maxExports`, `maxFunctionSpan`, and
`maxNameLength`. Each is documented inline with rationale. Only
`maxFunctionSpan` is a correctness/accuracy dial; the other two are DoS
bounds.

## Accepted judgment calls (v1)

### Forwarder-skip

Forwarded exports contain no code; their function RVA points at an ASCII
string (for example `"NTDLL.RtlAllocateHeap"`) inside the export directory's
own byte range. `kernel32.dll` and `kernelbase.dll` are saturated with
forwarders. Treating a forwarder RVA as code would produce a confidently wrong
symbol. We skip forwarders in v1. Real-world cost is near zero: a stack return
address almost never lands in a forwarder stub, and the real target resolves
via the destination module's own export table, which we parse. This banks a
correctness guarantee for a tiny coverage gap.

### Max-delta fallback

Export tables list exported entry points only, with no function sizes and no
internal/static functions. The nearest export below an address can be an
unrelated earlier function. The `maxFunctionSpan` guard suppresses a symbol
when the delta is implausibly large, falling back to `module+0xNN`, which is
never wrong. This biases to false negatives (a correct symbol occasionally
suppressed) over false positives (a wrong name), consistent with the guiding
principle. Export-only symbolication is partial by nature: many release
frames, especially in the user's own code, will correctly show `module+0xNN`
with no name. That is expected for slice 1, not a defect; those frames get
names from slices 2 and 3.

## Error handling

Matches the codebase: failable `init?`, no throwing.

- Bad signature, out-of-bounds read, or truncated/absent module memory ->
  `PEExportTable.init?` returns nil. The module contributes no symbols. This
  is the expected path for small dumps that did not capture module header
  pages, not an error state. No logging noise.
- Overflow-safe arithmetic (`addingReportingOverflow`) on every offset, same
  as `ModuleList` / `Memory64List`.
- DoS: `maxExports` cap; every read bounded by `imageSize` and reader
  availability. Mirrors existing `maxModules` / `maxRegions` caps.
- `Symbolicator.resolve` returning nil -> `StackFrame` falls back to
  `module+0xNN`. Never crashes, never guesses past the max-delta guard.

## Surfacing

The issue's acceptance requires names in views and all exporters.

- Single chokepoint: `StackFrame.displayAddress`. Most formatting already
  routes through it and gets symbols for free.
- Audit and align the five frame-formatting sites: `CrashAnalysisView`,
  `ThreadDetailView`, `TextReporter`, `HTMLExporter`, `CSVExporter`. Any that
  hand-build `module+offset` switch to `displayAddress`.
- `JSONExporter`: `StackFrame` is `Codable` and `symbol` joins `CodingKeys`,
  so structured `{function, offsetInFunction}` is emitted automatically.
  Verify, do not hand-roll.

## Testing (TDD)

All synthetic bytes, no test-data files. Follows the existing
`ModelUnitTests` / `ParserEdgeCaseTests` patterns.

`PEExportTable`: build a minimal valid PE (DOS + NT + optional header + one
`IMAGE_EXPORT_DIRECTORY` with 2-3 named exports) in memory, wrapped in a
synthetic `Memory64List` region at a base address. Assert:

- exact entry -> `mod!Foo+0x0`; mid-function -> `mod!Foo+0x10`
- address below first export -> nil (fallback)
- delta beyond `maxFunctionSpan` -> nil (fallback)
- forwarder entry skipped
- PE32 and PE32+ both parse
- truncated/absent module memory -> nil, no crash
- DoS: huge `NumberOfNames` -> rejected by cap, no hang

`Symbolicator`: end-to-end on a synthetic `ParsedMinidump` ->
`StackFrame.displayAddress` shows `mod!func+0xNN`.

`DumpMemoryReader`: parity test proving identical bytes to the old
`CrashAnalyzer` path.

Regression: the full existing suite (531 tests) stays green after the
`readMemory` refactor; that is the safety net for the behavior-preserving
extraction.

## Post-v1 follow-ups (recorded decisions, not forgotten shortcuts)

1. Forwarder-string resolution: parse the forwarder target string (for
   example `"NTDLL.RtlAllocateHeap"`) and display the resolved name. Polish,
   not required for a routing verdict.
2. Max-delta tuning: validate `maxFunctionSpan` against a corpus of
   real-world dumps and adjust. The default of 256 KB is a conservative guess
   until the feature exists to measure against.
3. Slice 2 (public Microsoft symbol server) and slice 3 (private symbol
   path), per issue #2.
