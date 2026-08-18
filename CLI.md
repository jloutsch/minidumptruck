# MiniDumpTruck CLI Manual

`minidumptruck-cli` is a command-line tool for analyzing Windows crash dump (.dmp) files on macOS. It provides the same parsing and analysis engine as the MiniDumpTruck GUI application, accessible from the terminal for scripting, automation, and CI/CD integration.

## Installation

Build from source:

```bash
cd App && swift build
```

The binary is located at `App/.build/debug/minidumptruck-cli`. For an optimized build:

```bash
cd App && swift build -c release
# Binary at App/.build/release/minidumptruck-cli
```

### macOS

Each release publishes a prebuilt Apple Silicon binary as
`minidumptruck-cli-<version>-macos-arm64.tar.gz`, with a matching
`.sha256` file. Verify and extract it with:

```bash
shasum -a 256 -c minidumptruck-cli-<version>-macos-arm64.tar.gz.sha256
tar -xzf minidumptruck-cli-<version>-macos-arm64.tar.gz
```

Apple Silicon only — there is no Intel or universal build. On an Intel
Mac, build from source as above.

The binary carries only the ad-hoc signature the Swift toolchain
applies automatically, which is what lets it run on Apple Silicon at
all. It is **not** Developer ID signed or notarized. What that means in
practice depends on how you unpack it:

- Extracting with `tar` in the terminal, as above, does not propagate
  the quarantine flag, and the binary runs.
- Downloading through a browser and unpacking with Finder's Archive
  Utility does propagate it, and macOS refuses to run the result. Clear
  it with:

  ```bash
  xattr -d com.apple.quarantine minidumptruck-cli
  ```

### Linux

Each release publishes a prebuilt x86_64 Linux binary as
`minidumptruck-cli-<version>-linux-x86_64.tar.gz`, with a matching
`.sha256` file. Verify and extract it with:

```bash
sha256sum -c minidumptruck-cli-<version>-linux-x86_64.tar.gz.sha256
tar -xzf minidumptruck-cli-<version>-linux-x86_64.tar.gz
```

The Swift runtime is linked into the binary, so no Swift toolchain is
needed to run it. It is not fully static, though, and it requires one
shared library that is **not** part of a minimal Ubuntu install:

```bash
sudo apt-get install -y libcurl4
```

Ubuntu Desktop already has `libcurl4`; minimal server installs and
container base images generally do not. Without it the binary does not
start at all, failing before it prints anything:

```
error while loading shared libraries: libcurl.so.4
```

Everything else it links against (`libz`, `libstdc++`, `libgcc_s`,
`libm`, `libc`) is present in a stock Ubuntu 24.04 image.

## Quick Start

```bash
# Analyze a single crash dump
minidumptruck-cli analyze crash.dmp

# Get a quick summary of a dump file
minidumptruck-cli info crash.dmp

# Export a report as HTML
minidumptruck-cli export -f html -o ./reports crash.dmp

# Batch-analyze a directory of dumps
minidumptruck-cli analyze ./dumps/
```

## Global Options

| Option | Description |
|---|---|
| `--help`, `-h` | Print usage information and exit. |
| `--version` | Print the version number (1.0.0) and exit. |

## Commands

`minidumptruck-cli` has three subcommands. If no subcommand is specified, `analyze` is used by default.

---

### `analyze`

Analyze crash dump file(s) and print a detailed text report.

```
minidumptruck-cli analyze [OPTIONS] <path>
```

**Arguments:**

| Argument | Description |
|---|---|
| `<path>` | Path to a `.dmp` file or a directory containing `.dmp` files. |

**Options:**

| Option | Short | Default | Description |
|---|---|---|---|
| `--verbose` | `-v` | off | Include CPU register dumps for each thread and memory region details. |
| `--summary` | `-s` | off | Show only the batch summary (directory mode). Suppresses individual reports. |
| `--jobs` | `-j` | 4 | Maximum number of concurrent analyses in batch mode. |

**Single File Mode**

When `<path>` is a `.dmp` file, the tool parses the dump, runs crash analysis, and prints a full text report to stdout containing:

- File metadata (name, timestamp, size, flags)
- Parse warnings (if any)
- System information (OS version, architecture, processors, service pack)
- Process information (PID, creation time, CPU time)
- Exception details (code, description, faulting address, faulting module)
- Crash analysis (confidence level, probable cause, recommendation, blamed module, call stack)
- Thread list (IDs, names, faulting thread marker)
- Module list (addresses, names, sizes, versions)

With `--verbose`, the report additionally includes:

- Full register state for each thread (RIP, RSP, RBP, RAX-RDX, R8-R15, segment registers, XMM registers)
- Memory region details (address, size, state, protection, type)

**Directory (Batch) Mode**

When `<path>` is a directory, the tool discovers all `.dmp` files (sorted alphabetically), analyzes them concurrently, and prints:

1. Individual reports for each file (unless `--summary` is set)
2. A batch summary with aggregate statistics:
   - Total files processed
   - Successful/failed parse counts
   - Number of crashes detected
   - Most blamed modules (ranked by frequency)
   - Most common exception codes (ranked by frequency)

Progress is displayed on stderr during batch processing as `[completed/total] analyzed`.

**Exit Codes:**

| Code | Meaning |
|---|---|
| 0 | Success. No exception/crash detected in the dump(s). |
| 1 | Error (file not found, parse failure, invalid arguments). |
| 2 | Success, but one or more crash dumps contained an exception. |

The exit code distinction between 0 and 2 enables scripting workflows that differentiate between clean dumps and crash dumps.

**Examples:**

```bash
# Basic analysis
minidumptruck-cli analyze crash.dmp

# Verbose analysis with register dumps
minidumptruck-cli analyze -v crash.dmp

# Batch analyze with 8 concurrent jobs, summary only
minidumptruck-cli analyze -s -j 8 ./crash-dumps/

# Check exit code in a script
minidumptruck-cli analyze crash.dmp
if [ $? -eq 2 ]; then
    echo "Crash detected!"
fi
```

---

### `export`

Export crash dump data to a file in the specified format.

```
minidumptruck-cli export [OPTIONS] <path>
```

**Arguments:**

| Argument | Description |
|---|---|
| `<path>` | Path to a `.dmp` file or a directory containing `.dmp` files. |

**Options:**

| Option | Short | Default | Description |
|---|---|---|---|
| `--format` | `-f` | `text` | Output format. One of: `text`, `html`, `csv`, `json`. |
| `--output` | `-o` | `.` (current directory) | Output directory. Created automatically if it doesn't exist. |
| `--verbose` | `-v` | off | Include registers and memory regions (text format only). |

**Output Formats:**

| Format | Extension | Description |
|---|---|---|
| `text` | `.txt` | Plain-text report (same as `analyze` output). Supports `--verbose`. |
| `html` | `.html` | Standalone HTML page with styled tables and sections. |
| `csv` | `.csv` | Comma-separated values with UTF-8 BOM for Excel compatibility. Contains module and thread data in tabular form. |
| `json` | `.json` | Structured JSON with all parsed data: header, system info, exception, modules, threads, analysis results, and parse warnings. |

**File Naming:**

Output files are named after the input file with the format-appropriate extension. For example, `crash.dmp` exported as JSON produces `crash.json`.

**Batch Mode:**

When `<path>` is a directory, one output file is created per `.dmp` file found. After processing, the tool prints:

```
Exported <count> file(s) to <output-directory>
```

**Exit Codes:**

| Code | Meaning |
|---|---|
| 0 | Success. |
| 1 | Error (file not found, parse failure, invalid arguments). |

**Examples:**

```bash
# Export as HTML to a reports directory
minidumptruck-cli export -f html -o ./reports crash.dmp

# Export all dumps in a directory as JSON
minidumptruck-cli export -f json -o ./json-reports ./crash-dumps/

# Export verbose text report
minidumptruck-cli export -f text -v -o ./reports crash.dmp

# Export as CSV for spreadsheet analysis
minidumptruck-cli export -f csv -o ./data crash.dmp
```

---

### `info`

Show a quick summary of a crash dump: header metadata, system info, and exception details.

```
minidumptruck-cli info <path>
```

**Arguments:**

| Argument | Description |
|---|---|
| `<path>` | Path to a single `.dmp` file. |

This command has no additional options. It is designed for fast triage — quickly checking what a dump file contains without running full analysis.

**Output Sections:**

1. **File metadata**: file name, stream count, timestamp
2. **System info**: OS version, architecture, processor count, build number (or "not available")
3. **Exception**: code (with symbolic name), thread ID, faulting address, flags (or "none" if no exception)
4. **Parse warnings**: any issues encountered during parsing (only shown if present)

**Exit Codes:**

| Code | Meaning |
|---|---|
| 0 | Success. |
| 1 | Error (file not found, parse failure). |

**Example:**

```bash
$ minidumptruck-cli info crash.dmp
File: crash.dmp
Streams: 13
Timestamp: Feb 14, 2007 at 2:13:00 PM

System Info:
  OS: Windows XP (5.1 Build 2600)
  Architecture: x86 (Intel)
  Processors: 1
  Build: 2600

Exception:
  Code: 0xC0000005 (STATUS_ACCESS_VIOLATION)
  Thread ID: 3060
  Address: 0x000000000040429E
```

---

## Error Handling

All commands print error messages to stderr. Common errors:

| Error | Cause |
|---|---|
| `File or directory not found: <path>` | The specified path does not exist. |
| `No .dmp files found` | The directory contains no files with a `.dmp` extension. |
| ArgumentParser validation errors | Invalid flags, missing required arguments, or unknown options. |

## Scripting Patterns

**Triage a directory of dumps:**

```bash
# Quick overview of each dump
for f in ./dumps/*.dmp; do
    echo "=== $f ==="
    minidumptruck-cli info "$f"
    echo
done
```

**CI crash detection:**

```bash
minidumptruck-cli analyze ./test-crashes/
exit_code=$?
if [ $exit_code -eq 2 ]; then
    echo "::warning::Crash dumps contain exceptions"
fi
```

**Generate reports in multiple formats:**

```bash
for fmt in text html json csv; do
    minidumptruck-cli export -f $fmt -o "./reports/$fmt" ./dumps/
done
```

**Process JSON output programmatically:**

```bash
minidumptruck-cli export -f json -o /tmp crash.dmp
cat /tmp/crash.json | jq '.analysis.blamedModule'
```
