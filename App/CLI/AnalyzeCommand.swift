import ArgumentParser
import Foundation
import MiniDumpTruckCore

struct AnalyzeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "analyze",
        abstract: "Analyze crash dump file(s) and print a report."
    )

    @Argument(help: "Path to a .dmp file or directory containing .dmp files.")
    var path: String

    @Flag(name: .shortAndLong, help: "Include registers and memory regions.")
    var verbose = false

    @Flag(name: .shortAndLong, help: "Show batch summary only (for directories).")
    var summary = false

    @Option(name: .shortAndLong, help: "Maximum concurrent analyses for batch mode.")
    var jobs: Int = 4

    mutating func run() async throws {
        let url = URL(fileURLWithPath: path)
        var isDir: ObjCBool = false

        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            throw CLIError.fileNotFound(path)
        }

        if isDir.boolValue {
            try await analyzeBatch(directory: url)
        } else {
            let exitCode = try analyzeSingle(file: url)
            if exitCode == 2 {
                throw ExitCode(2)
            }
        }
    }

    private func analyzeSingle(file: URL) throws -> Int32 {
        let data = try Data(contentsOf: file)
        let dump = try MinidumpParser.parse(data: data)
        let analyzer = CrashAnalyzer(dump: dump)
        let analysis = analyzer.analyze()

        let report = TextReporter.generateReport(
            from: dump,
            analysis: analysis,
            fileName: file.lastPathComponent,
            verbose: verbose
        )

        print(report)

        // Exit code 2 if crash detected
        return dump.exception != nil ? 2 : 0
    }

    private func analyzeBatch(directory: URL) async throws {
        let files = try findDumpFiles(in: directory)

        guard !files.isEmpty else {
            print("No .dmp files found in \(directory.path)")
            return
        }

        print("Found \(files.count) dump file(s)...")

        let (results, batchSummary) = await BatchAnalyzer.analyze(
            files: files,
            maxConcurrency: jobs
        ) { completed, total in
            if !summary {
                print("  [\(completed)/\(total)] analyzed", terminator: "\r")
                fflush(stdout)
            }
        }

        if !summary {
            print("")  // Clear progress line
        }
        for result in results {
            switch result.outcome {
            case .success(let dump, let analysis):
                if !summary {
                    print("")
                    let report = TextReporter.generateReport(
                        from: dump,
                        analysis: analysis,
                        fileName: result.fileName,
                        verbose: verbose
                    )
                    print(report)
                }
            case .failure(let reason):
                let line = "\(result.fileName): \(reason)\n"
                FileHandle.standardError.write(Data(line.utf8))
            }
        }

        print("")
        print(batchSummary.description)

        if batchSummary.crashesDetected > 0 {
            throw ExitCode(2)
        }
        if batchSummary.failedParses > 0 {
            throw ExitCode(1)
        }
    }

    private func findDumpFiles(in directory: URL) throws -> [URL] {
        let contents = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        return contents
            .filter { $0.pathExtension.lowercased() == "dmp" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
