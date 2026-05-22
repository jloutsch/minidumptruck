import ArgumentParser
import Foundation
import MiniDumpTruckCore

struct InfoCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "info",
        abstract: "Show quick summary of a crash dump (header, system info, exception)."
    )

    @Argument(help: "Path to a .dmp file.")
    var path: String

    @Option(name: .long, help: "Maximum dump file size in bytes (default 2 GB).")
    var maxFileSize: Int64 = CLIIO.defaultMaxFileSize

    mutating func run() throws {
        let url = URL(fileURLWithPath: path)

        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CLIError.fileNotFound(path)
        }

        do {
            let data = try CLIIO.readDump(at: url, maxSize: maxFileSize)
            let dump: ParsedMinidump
            do {
                dump = try MinidumpParser.parse(data: data)
            } catch {
                throw CLIError.parseError(error.localizedDescription)
            }

            printHeader(dump)
            printSystemInfo(dump)
            printException(dump)
            printWarnings(dump)
        } catch let cliError as CLIError {
            FileHandle.standardError.write(Data("\(cliError.description)\n".utf8))
            throw cliError.exitCode
        }
    }

    private func printHeader(_ dump: ParsedMinidump) {
        print("File: \(URL(fileURLWithPath: path).lastPathComponent)")
        print("Streams: \(dump.streamDirectory.entries.count)")
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        print("Timestamp: \(formatter.string(from: dump.header.timestamp))")
        print("")
    }

    private func printSystemInfo(_ dump: ParsedMinidump) {
        guard let sys = dump.systemInfo else {
            print("System Info: not available")
            return
        }

        // Sanitize attacker-influenced strings (osVersionString may
        // include service-pack text from the dump) before writing to
        // a terminal — strips ANSI escapes and bidi overrides.
        print("System Info:")
        print("  OS: \(sys.osVersionString.sanitizedForOutput())")
        print("  Architecture: \(sys.processorArchitecture.displayName)")
        print("  Processors: \(sys.numberOfProcessors)")
        print("  Build: \(sys.buildNumber)")
        print("")
    }

    private func printException(_ dump: ParsedMinidump) {
        guard let exc = dump.exception else {
            print("Exception: none")
            return
        }

        let codeName = NTStatusCodes.name(for: exc.exceptionCode)
        print("Exception:")
        print("  Code: \(String(format: "0x%08X", exc.exceptionCode)) (\(codeName))")
        print("  Thread ID: \(exc.threadId)")
        print("  Address: \(String(format: "0x%016llX", exc.exceptionAddress))")
        if exc.exceptionFlags != 0 {
            print("  Flags: \(String(format: "0x%08X", exc.exceptionFlags))")
        }
        print("")
    }

    private func printWarnings(_ dump: ParsedMinidump) {
        guard !dump.parseWarnings.isEmpty else { return }

        print("Parse Warnings (\(dump.parseWarnings.count)):")
        for warning in dump.parseWarnings {
            let streamName = warning.streamType.map { "\($0)" } ?? "unknown"
            print("  [\(streamName)] \(warning.message.sanitizedForOutput())")
        }
    }
}
