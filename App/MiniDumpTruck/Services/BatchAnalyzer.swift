import Foundation

/// Outcome of analyzing a single dump file. Success carries the parsed
/// dump and the analysis; failure carries a human-readable reason.
public enum BatchOutcome: Sendable {
    case success(ParsedMinidump, analysis: CrashAnalysis?)
    case failure(reason: String)
}

/// Result of analyzing a single dump file. Every input file produces a
/// result.
public struct BatchResult: Sendable {
    public let fileName: String
    public let outcome: BatchOutcome

    public init(fileName: String, outcome: BatchOutcome) {
        self.fileName = fileName
        self.outcome = outcome
    }
}

/// Aggregated summary across multiple crash dumps
public struct BatchSummary: Sendable {
    public let totalFiles: Int
    public let successfulParses: Int
    public let failedParses: Int
    public let crashesDetected: Int
    public let topBlamedModules: [(module: String, count: Int)]
    public let topExceptionCodes: [(code: String, name: String, count: Int)]

    public var description: String {
        var lines: [String] = []
        lines.append("Batch Analysis Summary")
        lines.append("  Total files: \(totalFiles)")
        lines.append("  Successfully parsed: \(successfulParses)")
        lines.append("  Failed to parse: \(failedParses)")
        lines.append("  Crashes detected: \(crashesDetected)")

        if !topBlamedModules.isEmpty {
            lines.append("")
            lines.append("  Most blamed modules:")
            for (module, count) in topBlamedModules.prefix(10) {
                lines.append("    \(module): \(count)")
            }
        }

        if !topExceptionCodes.isEmpty {
            lines.append("")
            lines.append("  Most common exceptions:")
            for (code, name, count) in topExceptionCodes.prefix(10) {
                lines.append("    \(code) (\(name)): \(count)")
            }
        }

        return lines.joined(separator: "\n")
    }
}

/// Analyzes multiple crash dump files in parallel
public struct BatchAnalyzer: Sendable {

    /// Analyze multiple dump files.
    ///
    /// `maxFileSize` is an optional cap (in bytes) applied per-file
    /// before the read. Files above the cap produce a failure outcome
    /// rather than OOM the process — important in batch mode where
    /// `maxConcurrency` large dumps could otherwise be in flight at
    /// once. nil disables the guard.
    public static func analyze(
        files: [URL],
        maxConcurrency: Int = 4,
        maxFileSize: Int64? = nil,
        progress: @Sendable @escaping (Int, Int) -> Void = { _, _ in }
    ) async -> (results: [BatchResult], summary: BatchSummary) {
        var results: [BatchResult] = []
        var completed = 0

        await withTaskGroup(of: BatchResult.self) { group in
            // Limit concurrency by adding tasks in batches
            var index = 0

            // Seed initial batch
            for _ in 0..<min(maxConcurrency, files.count) {
                let file = files[index]
                index += 1
                group.addTask {
                    await analyzeFile(file, maxFileSize: maxFileSize)
                }
            }

            for await result in group {
                results.append(result)
                completed += 1
                progress(completed, files.count)

                // Add next task if available
                if index < files.count {
                    let file = files[index]
                    index += 1
                    group.addTask {
                        await analyzeFile(file, maxFileSize: maxFileSize)
                    }
                }
            }
        }

        let summary = buildSummary(from: results, totalFiles: files.count)
        return (results, summary)
    }

    /// Analyze a single file. Always returns a `BatchResult` — success or
    /// `.failure` with a human-readable reason.
    private static func analyzeFile(_ url: URL, maxFileSize: Int64?) async -> BatchResult {
        let fileName = url.lastPathComponent

        // Pre-flight size check: skip files that exceed the cap rather
        // than reading them into a Data buffer first.
        if let cap = maxFileSize,
           let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? Int64,
           size > cap {
            let sizeStr = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
            let capStr = ByteCountFormatter.string(fromByteCount: cap, countStyle: .file)
            return BatchResult(
                fileName: fileName,
                outcome: .failure(reason: "file too large (\(sizeStr); limit \(capStr))")
            )
        }

        do {
            let data = try Data(contentsOf: url)
            let dump = try MinidumpParser.parse(data: data)
            let analyzer = CrashAnalyzer(dump: dump)
            let analysis = analyzer.analyze()
            return BatchResult(fileName: fileName, outcome: .success(dump, analysis: analysis))
        } catch {
            return BatchResult(fileName: fileName, outcome: .failure(reason: ErrorSanitization.reason(for: error)))
        }
    }

    /// Build aggregate summary from results
    private static func buildSummary(from results: [BatchResult], totalFiles: Int) -> BatchSummary {
        var successCount = 0
        var crashCount = 0
        var moduleCounts: [String: Int] = [:]
        var exceptionCounts: [UInt32: Int] = [:]

        for result in results {
            guard case .success(let dump, let analysis) = result.outcome else { continue }
            successCount += 1

            if dump.exception != nil {
                crashCount += 1
            }

            if let blame = analysis?.blameModule {
                moduleCounts[blame.module.shortName, default: 0] += 1
            }

            if let exception = dump.exception {
                exceptionCounts[exception.exceptionCode, default: 0] += 1
            }
        }

        let failedCount = totalFiles - successCount

        let topModules = moduleCounts
            .sorted { $0.value > $1.value }
            .map { (module: $0.key, count: $0.value) }

        let topExceptions = exceptionCounts
            .sorted { $0.value > $1.value }
            .map { (
                code: String(format: "0x%08X", $0.key),
                name: NTStatusCodes.name(for: $0.key),
                count: $0.value
            ) }

        return BatchSummary(
            totalFiles: totalFiles,
            successfulParses: successCount,
            failedParses: failedCount,
            crashesDetected: crashCount,
            topBlamedModules: topModules,
            topExceptionCodes: topExceptions
        )
    }
}
