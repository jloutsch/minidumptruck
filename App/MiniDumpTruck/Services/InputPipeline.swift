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
        let dir: URL
        do {
            dir = try TempStore.makeDir(sourceName: sourceName)
        } catch {
            return .failed(.zipExtractFailed(entry: "(tempdir)", underlying: error))
        }
        var urls: [URL] = []
        urls.reserveCapacity(entries.count)
        for entry in entries {
            let sanitizedName = (entry.name as NSString).lastPathComponent
            guard !sanitizedName.isEmpty else {
                try? FileManager.default.removeItem(at: dir)
                return .failed(.zipExtractFailed(entry: entry.name,
                                                 underlying: ZipError.corrupted(reason: "empty filename")))
            }
            // Reject literal ".." and "." after sanitization — these resolve
            // to the tempdir parent or self and would write outside the
            // intended directory (or fail in a confusing way).
            guard sanitizedName != "..", sanitizedName != "." else {
                try? FileManager.default.removeItem(at: dir)
                return .failed(.zipExtractFailed(entry: entry.name,
                                                 underlying: ZipError.corrupted(reason: "invalid filename")))
            }
            let outURL = dir.appendingPathComponent(sanitizedName)
            do {
                let body = try archive.extract(entry)
                try body.write(to: outURL, options: .atomic)
                urls.append(outURL)
            } catch {
                try? FileManager.default.removeItem(at: dir)
                return .failed(.zipExtractFailed(entry: entry.name, underlying: error))
            }
        }
        return .openInWindows(urls)
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
            return .failed(.zipParseFailed(.corrupted(reason: error.localizedDescription)))
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
