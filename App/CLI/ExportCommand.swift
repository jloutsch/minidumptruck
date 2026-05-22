import ArgumentParser
import Foundation
import MiniDumpTruckCore

struct ExportCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export",
        abstract: "Export crash dump data in various formats."
    )

    @Argument(help: "Path to a .dmp file or directory containing .dmp files.")
    var path: String

    @Option(name: .shortAndLong, help: "Output format: text, html, csv, json.")
    var format: ExportFormat = .text

    @Option(name: .shortAndLong, help: "Output directory (defaults to current directory).")
    var output: String = "."

    @Flag(name: .shortAndLong, help: "Include registers and memory regions (text format).")
    var verbose = false

    @Option(name: .long, help: "Maximum dump file size in bytes (default 2 GB).")
    var maxFileSize: Int64 = CLIIO.defaultMaxFileSize

    mutating func run() async throws {
        let url = URL(fileURLWithPath: path)
        var isDir: ObjCBool = false

        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            throw CLIError.fileNotFound(path)
        }

        do {
            let outputDir = URL(fileURLWithPath: output)
            do {
                try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
            } catch {
                throw CLIError.ioError(error.localizedDescription)
            }

            let files: [URL]
            if isDir.boolValue {
                do {
                    let contents = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
                    files = contents.filter { $0.pathExtension.lowercased() == "dmp" }
                        .sorted { $0.lastPathComponent < $1.lastPathComponent }
                } catch {
                    throw CLIError.ioError(error.localizedDescription)
                }
            } else {
                files = [url]
            }

            guard !files.isEmpty else {
                print("No .dmp files found.")
                return
            }

            for file in files {
                try exportFile(file, to: outputDir)
            }

            print("Exported \(files.count) file(s) to \(outputDir.path)")
        } catch let cliError as CLIError {
            FileHandle.standardError.write(Data("\(cliError.description)\n".utf8))
            throw cliError.exitCode
        }
    }

    private func exportFile(_ file: URL, to outputDir: URL) throws {
        let data = try CLIIO.readDump(at: file, maxSize: maxFileSize)
        let dump: ParsedMinidump
        do {
            dump = try MinidumpParser.parse(data: data)
        } catch {
            throw CLIError.parseError(error.localizedDescription)
        }
        let analyzer = CrashAnalyzer(dump: dump)
        let analysis = analyzer.analyze()
        let baseName = file.deletingPathExtension().lastPathComponent

        let content: String
        let ext: String

        switch format {
        case .text:
            content = TextReporter.generateReport(
                from: dump, analysis: analysis,
                fileName: file.lastPathComponent, verbose: verbose
            )
            ext = "txt"

        case .html:
            content = HTMLExporter.generateReport(
                from: dump, analysis: analysis,
                fileName: file.lastPathComponent
            )
            ext = "html"

        case .csv:
            content = CSVExporter.generateCSV(from: dump)
            ext = "csv"

        case .json:
            content = JSONExporter.generateJSON(
                from: dump, analysis: analysis,
                fileName: file.lastPathComponent
            )
            ext = "json"
        }

        let outputFile = outputDir.appendingPathComponent("\(baseName).\(ext)")
        try content.write(to: outputFile, atomically: true, encoding: .utf8)
        print("  \(file.lastPathComponent) -> \(outputFile.lastPathComponent)")
    }
}

enum ExportFormat: String, ExpressibleByArgument, CaseIterable {
    case text, html, csv, json
}
