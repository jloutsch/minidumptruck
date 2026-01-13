# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

MiniDumpTruck is a native macOS application for analyzing Windows crash dump files (.dmp). It provides WinDbg-like functionality without requiring Windows, allowing developers to inspect minidump files on macOS.

## Build Commands

```bash
# Build the project
cd App && swift build

# Build for release
cd App && swift build -c release

# Run the application
cd App && ./.build/debug/MiniDumpTruck

# Run tests
cd App && swift test
```

To open in Xcode: `open App/Package.swift`

## Architecture

The application follows MVVM architecture with SwiftUI:

- **Models/** - Data structures for minidump format (MinidumpHeader, ThreadInfo, ModuleInfo, ExceptionInfo, MemoryRegion, etc.)
- **Parsers/** - Binary parsing logic (MinidumpParser.swift is the main entry point)
- **ViewModels/** - Observable state management (DumpViewModel)
- **Views/** - SwiftUI views with NavigationSplitView 3-column layout
- **Utilities/** - Helper extensions (BinaryReader for little-endian parsing, NTStatusCodes for exception lookup)
- **Services/** - Analysis services (CrashAnalyzer for stack walking and blame analysis)

## Key Files

- `App/MiniDumpTruck/Parsers/MinidumpParser.swift` - Main parser that coordinates stream parsing
- `App/MiniDumpTruck/Utilities/BinaryReader.swift` - Data extension for reading little-endian binary values
- `App/MiniDumpTruck/Models/ThreadContext.swift` - x64 CONTEXT_AMD64 structure for register state
- `App/MiniDumpTruck/Views/ContentView.swift` - Main UI with NavigationSplitView
- `App/MiniDumpTruck/Services/CrashAnalyzer.swift` - Stack walking and blame analysis (WinDbg-like !analyze)

## Windows Minidump Format

- Header starts with "MDMP" signature (0x504D444D)
- Stream directory at offset specified in header
- Key stream types: ThreadList (3), ModuleList (4), Exception (6), SystemInfo (7), Memory64List (9)
- All values are little-endian

## Target Platform

- macOS 14+ (Sonoma) - uses @Observable macro and latest SwiftUI features
- Swift 5.9+
