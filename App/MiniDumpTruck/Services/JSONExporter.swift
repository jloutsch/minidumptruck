import Foundation

/// Exportable report structure that excludes raw binary data
public struct ExportableReport: Codable, Sendable {
    public let fileName: String
    public let header: MinidumpHeader
    public let systemInfo: SystemInfo?
    public let exception: ExceptionInfo?
    public let threads: [ThreadInfo]?
    public let modules: [ModuleInfo]?
    public let unloadedModules: [UnloadedModule]?
    public let handleData: [HandleEntry]?
    public let memoryInfo: [MemoryInfo]?
    public let parseWarnings: [ParseWarning]
    public let analysis: CrashAnalysis?

    public init(from dump: ParsedMinidump, analysis: CrashAnalysis?, fileName: String) {
        self.fileName = fileName
        self.header = dump.header
        self.systemInfo = dump.systemInfo
        self.exception = dump.exception
        self.threads = dump.threadList?.threads
        self.modules = dump.moduleList?.modules
        self.unloadedModules = dump.unloadedModuleList?.modules
        self.handleData = dump.handleData?.entries
        self.memoryInfo = dump.memoryInfoList?.entries
        self.parseWarnings = dump.parseWarnings
        self.analysis = analysis
    }
}

/// Generates JSON crash reports from parsed minidumps
public struct JSONExporter: Sendable {

    /// Generate a JSON report string
    public static func generateJSON(
        from dump: ParsedMinidump,
        analysis: CrashAnalysis?,
        fileName: String = "Minidump",
        prettyPrint: Bool = true
    ) -> String {
        let report = ExportableReport(from: dump, analysis: analysis, fileName: fileName)
        let encoder = JSONEncoder()
        if prettyPrint {
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        }
        encoder.dateEncodingStrategy = .iso8601

        do {
            let data = try encoder.encode(report)
            return String(data: data, encoding: .utf8) ?? "{}"
        } catch {
            return encodeErrorFallback(error)
        }
    }

    /// Build the error-fallback JSON. Routes through JSONEncoder so
    /// that error messages containing `"`, `\`, or control characters
    /// still produce valid JSON (the prior string-interpolation
    /// version emitted malformed output that broke downstream
    /// `jq` / `json.loads`).
    static func encodeErrorFallback(_ error: Error) -> String {
        let fallback = ["error": "Failed to encode report: \(ErrorSanitization.reason(for: error))"]
        if let data = try? JSONEncoder().encode(fallback),
           let json = String(data: data, encoding: .utf8) {
            return json
        }
        return "{\"error\":\"Failed to encode report\"}"
    }
}
