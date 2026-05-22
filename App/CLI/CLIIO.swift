import Foundation

/// Shared read helper for CLI commands. Enforces a configurable
/// file-size ceiling so a 4 GB full-memory dump (or a typo'd path
/// pointing at a sparse file) cannot OOM the process before the
/// parser even runs.
enum CLIIO {
    /// Default cap: 2 GB. Microsoft minidumps with full memory can
    /// legitimately exceed this; override via `--max-file-size` flag
    /// when triaging large dumps with sufficient RAM.
    static let defaultMaxFileSize: Int64 = 2 * 1024 * 1024 * 1024

    /// Read a dump file, enforcing a size ceiling and rejecting non-
    /// regular files. Wraps I/O failures as typed CLIError cases so
    /// each command exits with code 3 on I/O / size-guard failure
    /// rather than the generic exit 1.
    ///
    /// NOTE: TOCTOU window exists between stat and read (path could be
    /// swapped to a larger file). Acceptable for triage workflows
    /// where dump files are static on disk; documented as a residual
    /// risk in #30.
    static func readDump(at url: URL, maxSize: Int64 = defaultMaxFileSize) throws -> Data {
        // Reject non-positive caps explicitly — a negative cap would
        // silently pass `size > maxSize` for every real file and
        // disable the guard. Zero rejects all non-empty files with a
        // confusing message; reject explicitly so the user fixes the
        // flag rather than wondering.
        guard maxSize > 0 else {
            throw CLIError.ioError("--max-file-size must be positive (got \(maxSize))")
        }

        let attrs: [FileAttributeKey: Any]
        do {
            attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch {
            throw CLIError.ioError(error.localizedDescription)
        }

        // Reject anything that isn't a regular file. attributesOfItem
        // follows symlinks, so a symlink to /dev/zero / /dev/urandom /
        // a FIFO / a block device would report a small size and
        // bypass the guard — then Data(contentsOf:) would OOM/hang.
        if let type = attrs[.type] as? FileAttributeType, type != .typeRegular {
            throw CLIError.ioError("\(url.path) is not a regular file (type: \(type.rawValue))")
        }

        if let size = attrs[.size] as? Int64, size > maxSize {
            throw CLIError.fileTooLarge(path: url.path, size: size, limit: maxSize)
        }

        do {
            return try Data(contentsOf: url)
        } catch {
            throw CLIError.ioError(error.localizedDescription)
        }
    }
}
