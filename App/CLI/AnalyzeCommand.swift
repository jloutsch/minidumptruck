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

    @Option(name: .long, help: "Maximum dump file size in bytes (default 2 GB). Files larger than this are skipped.")
    var maxFileSize: Int64 = CLIIO.defaultMaxFileSize

    mutating func run() async throws {
        let url = URL(fileURLWithPath: path)
        var isDir: ObjCBool = false

        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            throw CLIError.fileNotFound(path)
        }

        do {
            if isDir.boolValue {
                try await analyzeBatch(directory: url)
            } else {
                let exitCode = try analyzeSingle(file: url)
                if exitCode == 2 {
                    throw ExitCode(2)
                }
            }
        } catch let cliError as CLIError {
            FileHandle.standardError.write(Data("\(cliError.description)\n".utf8))
            throw cliError.exitCode
        }
    }

    private func analyzeSingle(file: URL) throws -> Int32 {
        let data = try CLIIO.readDump(at: file, maxSize: maxFileSize)
        let dump: ParsedMinidump
        do {
            dump = try MinidumpParser.parse(data: data)
        } catch {
            throw CLIError.parseError(error.localizedDescription)
        }
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
            maxConcurrency: jobs,
            maxFileSize: maxFileSize
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
                // BatchAnalyzer owns error-text sanitization (Cocoa/POSIX
                // messages with paths). This site owns filename sanitization
                // and re-sanitizes the reason as cheap insurance against
                // future BatchAnalyzer regressions. Do not remove either
                // layer.
                let sanitized = result.fileName.sanitizedForOutput(maxLength: ErrorSanitization.filenameMaxLength)
                let safeName = sanitized.isEmpty ? "<unnamed>" : sanitized
                let safeReason = reason.sanitizedForOutput()
                let line = "\(safeName): \(safeReason)\n"
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
        // Wrap raw NSError as CLIError.ioError so a permission-denied
        // directory exits with the documented code 3, not the generic
        // code 1 ArgumentParser would produce otherwise.
        let contents: [URL]
        do {
            // Request `isRegularFile` so we can filter out symlinks
            // that resolve to directories. A file named `crash.dmp`
            // that's actually a symlink-to-directory would otherwise
            // pass the .dmp extension filter and crash the single-
            // file path when Data(contentsOf:) follows the symlink and
            // hits a directory.
            contents = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey]
            )
        } catch {
            throw CLIError.ioError(error.localizedDescription)
        }
        return contents
            .filter { $0.pathExtension.lowercased() == "dmp" }
            .filter { url in
                // resourceValues follows symlinks, so a symlink to a
                // regular file still counts as `isRegularFile == true`
                // (legitimate). Only symlink-to-directory and weirder
                // file types (FIFOs, sockets) get filtered.
                (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
