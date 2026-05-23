# Contributing to MiniDumpTruck

Thanks for your interest in contributing! This guide will help you get started.

## Getting Started

1. Fork the repository
2. Clone your fork
3. Create a feature branch from `main`

## Building

```bash
cd App && swift build
```

To open in Xcode:

```bash
open App/Package.swift
```

## Running Tests

```bash
cd App && swift test
```

All tests must pass before submitting a pull request.

## Project Structure

- `App/MiniDumpTruck/Models/` - Data structures for the minidump format
- `App/MiniDumpTruck/Parsers/` - Binary parsing logic
- `App/MiniDumpTruck/Views/` - SwiftUI views
- `App/MiniDumpTruck/ViewModels/` - Observable state management
- `App/MiniDumpTruck/Services/` - Analysis and export services
- `App/MiniDumpTruck/Utilities/` - Helper extensions
- `App/CLI/` - Command-line interface
- `App/Tests/` - Test suite

## Pull Requests

1. Create a feature branch (`git checkout -b feature/my-change`)
2. Make your changes
3. Run `cd App && swift test` and ensure all tests pass
4. Commit with a clear message explaining the "why"
5. Push to your fork and open a pull request

Keep PRs focused on a single change. If you have multiple unrelated fixes, submit them as separate PRs.

## Reporting Issues

Use [GitHub Issues](https://github.com/jloutsch/minidumptruck/issues) to report bugs or request features. Include:

- macOS version
- Steps to reproduce (for bugs)
- Expected vs actual behavior
- Sample dump file if applicable (ensure it contains no sensitive data)

## Code Style

- Swift with SwiftUI for the GUI
- Swift Package Manager for builds (not Xcode projects)
- macOS 14+ minimum deployment target
- Keep changes minimal and focused

## License

By contributing, you agree that your contributions will be licensed under the [GNU GPLv3](LICENSE) — the same license that covers the rest of the project.
