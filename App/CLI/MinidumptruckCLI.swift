import ArgumentParser

@main
struct MinidumptruckCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "minidumptruck-cli",
        abstract: "Analyze Windows crash dump (.dmp) files from the command line.",
        version: "1.0.0",
        subcommands: [
            AnalyzeCommand.self,
            ExportCommand.self,
            InfoCommand.self,
        ],
        defaultSubcommand: AnalyzeCommand.self
    )

    static func main() async {
        if CommandLine.arguments.contains("--manual") {
            print(CLIManual.content)
            return
        }
        do {
            var command = try parseAsRoot()
            if var asyncCommand = command as? AsyncParsableCommand {
                try await asyncCommand.run()
            } else {
                try command.run()
            }
        } catch {
            exit(withError: error)
        }
    }
}
