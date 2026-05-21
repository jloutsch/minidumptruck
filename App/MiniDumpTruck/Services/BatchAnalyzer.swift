import Foundation

/// Result of analyzing a single dump file. Failure produces a result with
/// `dump == nil` and `error` populated, so callers see every input file.
public struct BatchResult: Sendable {
    public let fileName: String
    public let dump: ParsedMinidump?
    public let analysis: CrashAnalysis?
    public let error: String?

    public init(fileName: String, dump: ParsedMinidump?, analysis: CrashAnalysis?, error: String? = nil) {
        self.fileName = fileName
        self.dump = dump
        self.analysis = analysis
        self.error = error
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

    /// Analyze multiple dump files
    public static func analyze(
        files: [URL],
        maxConcurrency: Int = 4,
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
                    await analyzeFile(file)
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
                        await analyzeFile(file)
                    }
                }
            }
        }

        let summary = buildSummary(from: results, totalFiles: files.count)
        return (results, summary)
    }

    /// Analyze a single file. Always returns a `BatchResult`; on failure,
    /// `dump` is nil and `error` carries a human-readable reason.
    private static func analyzeFile(_ url: URL) async -> BatchResult {
        let fileName = url.lastPathComponent
        do {
            let data = try Data(contentsOf: url)
            let dump = try MinidumpParser.parse(data: data)
            let analyzer = CrashAnalyzer(dump: dump)
            let analysis = analyzer.analyze()
            return BatchResult(fileName: fileName, dump: dump, analysis: analysis)
        } catch {
            return BatchResult(fileName: fileName, dump: nil, analysis: nil, error: error.localizedDescription)
        }
    }

    /// Build aggregate summary from results
    private static func buildSummary(from results: [BatchResult], totalFiles: Int) -> BatchSummary {
        var successCount = 0
        var crashCount = 0
        var moduleCounts: [String: Int] = [:]
        var exceptionCounts: [UInt32: Int] = [:]

        for result in results {
            guard let dump = result.dump else { continue }
            successCount += 1

            if dump.exception != nil {
                crashCount += 1
            }

            if let blame = result.analysis?.blameModule {
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
