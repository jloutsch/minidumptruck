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

    /// Read a dump file, enforcing a size ceiling. Wraps I/O failures
    /// as typed CLIError cases so each command exits with code 3 on
    /// I/O or size-guard failure rather than the generic exit 1.
    static func readDump(at url: URL, maxSize: Int64 = defaultMaxFileSize) throws -> Data {
        // Pre-flight size check before allocating the read buffer.
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? Int64,
           size > maxSize {
            throw CLIError.fileTooLarge(path: url.path, size: size, limit: maxSize)
        }
        do {
            return try Data(contentsOf: url)
        } catch {
            throw CLIError.ioError(error.localizedDescription)
        }
    }
}
