import Foundation

/// Generates a self-contained HTML crash report from a parsed minidump
public struct HTMLExporter: Sendable {

    /// Generate a complete HTML report
    public static func generateReport(
        from dump: ParsedMinidump,
        analysis: CrashAnalysis?,
        fileName: String = "Minidump Report"
    ) -> String {
        var sections: [String] = []

        sections.append(summarySection(dump: dump, fileName: fileName))

        if !dump.parseWarnings.isEmpty {
            sections.append(warningsSection(dump.parseWarnings))
        }

        if let systemInfo = dump.systemInfo {
            sections.append(systemInfoSection(systemInfo))
        }

        if let miscInfo = dump.miscInfo {
            sections.append(miscInfoSection(miscInfo))
        }

        if let exception = dump.exception {
            sections.append(exceptionSection(exception, modules: dump.moduleList))
        }

        if let analysis = analysis {
            sections.append(analysisSection(analysis))
        }

        if let threadList = dump.threadList, !threadList.threads.isEmpty {
            sections.append(threadListSection(
                threads: threadList.threads,
                threadNames: dump.threadNames,
                exceptionThreadId: dump.exception?.threadId
            ))
        }

        if let moduleList = dump.moduleList, !moduleList.modules.isEmpty {
            sections.append(moduleListSection(moduleList.modules))
        }

        if let handleData = dump.handleData, !handleData.entries.isEmpty {
            sections.append(handleSection(handleData.entries))
        }

        if let memoryInfoList = dump.memoryInfoList, !memoryInfoList.entries.isEmpty {
            sections.append(memoryInfoSection(memoryInfoList.entries))
        }

        if let unloadedModuleList = dump.unloadedModuleList, !unloadedModuleList.modules.isEmpty {
            sections.append(unloadedModulesSection(unloadedModuleList.modules))
        }

        return wrapHTML(title: "Crash Report - \(escapeHTML(fileName))", body: sections.joined(separator: "\n\n"))
    }

    // MARK: - Section Builders

    private static func summarySection(dump: ParsedMinidump, fileName: String) -> String {
        let header = dump.header
        let threadCount = dump.threadList?.threads.count ?? 0
        let moduleCount = dump.moduleList?.modules.count ?? 0
        let streamCount = dump.streamDirectory.entries.count

        var rows = ""
        rows += tableRow("Dump File", escapeHTML(fileName))
        rows += tableRow("Timestamp", header.timestamp.formatted())
        rows += tableRow("File Size", ByteCountFormatter.string(fromByteCount: Int64(dump.data.count), countStyle: .file))
        rows += tableRow("Streams", "\(streamCount)")
        rows += tableRow("Threads", "\(threadCount)")
        rows += tableRow("Modules", "\(moduleCount)")
        rows += tableRow("Flags", escapeHTML(header.flagsDescription.joined(separator: ", ")))

        return """
        <section id="summary">
        <h2>Summary</h2>
        <table class="info-table">\(rows)</table>
        </section>
        """
    }

    private static func warningsSection(_ warnings: [ParseWarning]) -> String {
        var html = """
        <section id="warnings" style="border-color: var(--orange);">
        <h2 style="color: var(--orange);">Parse Warnings (\(warnings.count))</h2>
        <table class="data-table"><thead><tr>
        <th>Stream</th><th>Offset</th><th>Message</th>
        </tr></thead><tbody>
        """

        for warning in warnings {
            let streamName = warning.streamType?.displayName ?? "Unknown"
            let offset = warning.offset.map { $0.hex32 } ?? "-"
            html += "<tr>"
            html += "<td>\(escapeHTML(streamName))</td>"
            html += "<td class=\"mono\">\(offset)</td>"
            html += "<td>\(escapeHTML(warning.message))</td>"
            html += "</tr>"
        }

        html += "</tbody></table></section>"
        return html
    }

    private static func systemInfoSection(_ info: SystemInfo) -> String {
        var rows = ""
        rows += tableRow("Operating System", "\(escapeHTML(info.windowsVersionName)) (\(escapeHTML(info.osVersionString)))")
        rows += tableRow("Architecture", escapeHTML(info.processorArchitecture.displayName))
        rows += tableRow("Processors", "\(info.numberOfProcessors)")
        rows += tableRow("Product Type", escapeHTML(info.productType.displayName))
        if let csd = info.csdVersion, !csd.isEmpty {
            rows += tableRow("Service Pack", escapeHTML(csd))
        }
        if info.cpuInfo.isX86 {
            rows += tableRow("CPU Vendor", escapeHTML(info.cpuInfo.vendorString))
            rows += tableRow("CPU Family/Model", "Family \(info.cpuInfo.displayFamily), Model \(info.cpuInfo.displayModel), Stepping \(info.cpuInfo.stepping)")
        }

        return """
        <section id="system-info">
        <h2>System Information</h2>
        <table class="info-table">\(rows)</table>
        </section>
        """
    }

    private static func miscInfoSection(_ info: MiscInfo) -> String {
        var rows = ""
        if let pid = info.processId {
            rows += tableRow("Process ID", "\(pid)")
        }
        if let createTime = info.formattedCreateTime {
            rows += tableRow("Process Created", escapeHTML(createTime))
        }
        if let uptime = info.processUptime {
            rows += tableRow("CPU Time", escapeHTML(uptime))
        }
        if let freq = info.processorFrequency {
            rows += tableRow("Processor Frequency", escapeHTML(freq))
        }
        if let integrity = info.integrityLevelDescription {
            rows += tableRow("Integrity Level", escapeHTML(integrity))
        }
        if let tz = info.timeZoneName {
            rows += tableRow("Timezone", escapeHTML(tz))
        }
        if let build = info.buildString {
            rows += tableRow("Build String", escapeHTML(build))
        }

        guard !rows.isEmpty else { return "" }

        return """
        <section id="misc-info">
        <h2>Process Information</h2>
        <table class="info-table">\(rows)</table>
        </section>
        """
    }

    private static func exceptionSection(_ exception: ExceptionInfo, modules: ModuleList?) -> String {
        let moduleName = modules?.module(containing: exception.exceptionAddress)?.shortName

        var rows = ""
        rows += tableRow("Exception Code", "<code>\(exception.exceptionCode.hex32)</code> (\(escapeHTML(exception.exceptionName)))")
        rows += tableRow("Description", escapeHTML(exception.exceptionDescription))
        rows += tableRow("Address", "<code>\(exception.exceptionAddress.hexAddress)</code>")
        if let moduleName = moduleName {
            rows += tableRow("Module", escapeHTML(moduleName))
        }
        rows += tableRow("Thread ID", "\(exception.threadId)")
        if let details = exception.accessViolationDetails {
            rows += tableRow("Details", escapeHTML(details))
        }
        if !exception.exceptionParameters.isEmpty {
            let params = exception.exceptionParameters.map { $0.hexAddress }.joined(separator: ", ")
            rows += tableRow("Parameters", "<code>\(params)</code>")
        }

        return """
        <section id="exception">
        <h2>Exception</h2>
        <table class="info-table">\(rows)</table>
        </section>
        """
    }

    private static func analysisSection(_ analysis: CrashAnalysis) -> String {
        let summary = analysis.crashSummary
        let confidenceClass: String
        switch analysis.confidence {
        case .high: confidenceClass = "badge-green"
        case .medium: confidenceClass = "badge-orange"
        case .low: confidenceClass = "badge-red"
        }

        var html = """
        <section id="analysis">
        <h2>Crash Analysis <span class="badge \(confidenceClass)">\(analysis.confidence.displayName) Confidence</span></h2>
        """

        // Blame module
        if let blame = analysis.blameModule {
            var blameRows = ""
            blameRows += tableRow("Blamed Module", "<strong>\(escapeHTML(blame.module.shortName))</strong>")
            if let version = blame.module.version {
                blameRows += tableRow("Version", escapeHTML(version.fileVersion))
            }
            blameRows += tableRow("Reason", escapeHTML(blame.reasonDescription))
            html += "<table class=\"info-table\">\(blameRows)</table>"
        }

        // Summary
        var summaryRows = ""
        summaryRows += tableRow("Exception", escapeHTML(summary.exceptionType))
        summaryRows += tableRow("Faulting Address", "<code>\(summary.faultingAddress.hexAddress)</code>")
        if let module = summary.faultingModule {
            summaryRows += tableRow("Faulting Module", escapeHTML(module.shortName))
        }
        summaryRows += tableRow("Probable Cause", escapeHTML(summary.probableCause))
        summaryRows += tableRow("Recommendation", escapeHTML(summary.recommendation))
        html += "<h3>Summary</h3><table class=\"info-table\">\(summaryRows)</table>"

        // Stack trace
        if !analysis.stackFrames.isEmpty {
            html += "<h3>Call Stack</h3>"
            html += "<table class=\"data-table\"><thead><tr>"
            html += "<th>#</th><th>Type</th><th>Address</th><th>Module</th><th>Confidence</th>"
            html += "</tr></thead><tbody>"

            for (i, frame) in analysis.stackFrames.enumerated() {
                let typeStr: String
                switch frame.frameType {
                case .instructionPointer: typeStr = "IP"
                case .returnAddress: typeStr = "Ret"
                case .framePointer: typeStr = "FP"
                }

                let confClass: String
                switch frame.confidence {
                case .high: confClass = "badge-green"
                case .medium: confClass = "badge-orange"
                case .low: confClass = "badge-red"
                }

                html += "<tr>"
                html += "<td>\(i)</td>"
                html += "<td><span class=\"badge badge-sm\">\(typeStr)</span></td>"
                html += "<td class=\"mono\">\(frame.address.hexAddress)</td>"
                html += "<td>\(escapeHTML(frame.displayAddress))</td>"
                html += "<td><span class=\"badge badge-sm \(confClass)\">\(frame.confidence == .high ? "High" : frame.confidence == .medium ? "Medium" : "Low")</span></td>"
                html += "</tr>"
            }
            html += "</tbody></table>"
        }

        html += "</section>"
        return html
    }

    private static func threadListSection(
        threads: [ThreadInfo],
        threadNames: ThreadNameList?,
        exceptionThreadId: UInt32?
    ) -> String {
        var html = """
        <details id="threads">
        <summary><h2>Threads (\(threads.count))</h2></summary>
        """

        for thread in threads {
            let name = threadNames?.name(for: thread.id)
            let isFaulting = thread.id == exceptionThreadId
            let faultBadge = isFaulting ? " <span class=\"badge badge-red\">Faulting</span>" : ""
            let nameStr = name.map { " - \(escapeHTML($0))" } ?? ""

            html += "<details\(isFaulting ? " open" : "")>"
            html += "<summary><strong>Thread \(thread.id)\(nameStr)</strong>\(faultBadge)</summary>"

            var rows = ""
            rows += tableRow("Thread ID", "\(thread.id)")
            if let name = name { rows += tableRow("Name", escapeHTML(name)) }
            rows += tableRow("Priority", "\(escapeHTML(thread.priorityDescription)) (class \(thread.priorityClass))")
            rows += tableRow("Suspend Count", "\(thread.suspendCount)")
            rows += tableRow("TEB", "<code>\(thread.teb.hexAddress)</code>")
            rows += tableRow("Stack", "<code>\(thread.stack.startOfMemoryRange.hexAddress)</code> (\(thread.stack.dataSize) bytes)")

            html += "<table class=\"info-table\">\(rows)</table>"

            // Registers
            if let ctx = thread.context {
                html += "<details><summary>Registers</summary>"
                html += "<table class=\"data-table\"><thead><tr><th>Register</th><th>Value</th></tr></thead><tbody>"

                // Architecture-neutral via the enum's generalRegisters
                // accessor — yields RAX-R15 on x64 and X0-PC on ARM64.
                // Append the architecture's flags register at the end so
                // the report carries condition-code state too.
                var regs: [(String, UInt64)] = ctx.generalRegisters
                switch ctx {
                case .amd64(let amd):
                    regs.append(("RFLAGS", UInt64(amd.eflags)))
                case .arm64(let arm):
                    regs.append(("CPSR", UInt64(arm.cpsr)))
                }

                for (name, value) in regs {
                    html += "<tr><td class=\"mono\">\(name)</td><td class=\"mono\">\(value.hexAddress)</td></tr>"
                }

                html += "</tbody></table></details>"
            }

            html += "</details>"
        }

        html += "</details>"
        return html
    }

    private static func moduleListSection(_ modules: [ModuleInfo]) -> String {
        var html = """
        <details id="modules">
        <summary><h2>Modules (\(modules.count))</h2></summary>
        <table class="data-table"><thead><tr>
        <th>Name</th><th>Base Address</th><th>Size</th>
        <th>Version</th><th>PDB</th><th>Timestamp</th>
        </tr></thead><tbody>
        """

        for module in modules {
            html += "<tr>"
            html += "<td title=\"\(escapeHTML(module.name))\">\(escapeHTML(module.shortName))</td>"
            html += "<td class=\"mono\">\(module.baseAddress.hexAddress)</td>"
            html += "<td>\(formatSize(UInt64(module.sizeOfImage)))</td>"
            html += "<td>\(escapeHTML(module.version?.fileVersion ?? ""))</td>"
            html += "<td>\(escapeHTML(module.codeViewRecord?.pdbShortName ?? ""))</td>"
            html += "<td>\(escapeHTML(module.timestamp.formatted()))</td>"
            html += "</tr>"
        }

        html += "</tbody></table></details>"
        return html
    }

    private static func handleSection(_ handles: [HandleEntry]) -> String {
        var html = """
        <details id="handles">
        <summary><h2>Handles (\(handles.count))</h2></summary>
        <table class="data-table"><thead><tr>
        <th>Handle</th><th>Type</th><th>Object Name</th>
        <th>Access</th><th>Handle Count</th><th>Pointer Count</th>
        </tr></thead><tbody>
        """

        for handle in handles {
            html += "<tr>"
            html += "<td class=\"mono\">\(escapeHTML(handle.handleHex))</td>"
            html += "<td>\(escapeHTML(handle.typeName))</td>"
            html += "<td>\(escapeHTML(handle.objectName))</td>"
            html += "<td class=\"mono\">\(escapeHTML(handle.accessHex))</td>"
            html += "<td>\(handle.handleCount)</td>"
            html += "<td>\(handle.pointerCount)</td>"
            html += "</tr>"
        }

        html += "</tbody></table></details>"
        return html
    }

    private static func memoryInfoSection(_ entries: [MemoryInfo]) -> String {
        var html = """
        <details id="memory-info">
        <summary><h2>Memory Info (\(entries.count))</h2></summary>
        <table class="data-table"><thead><tr>
        <th>Base Address</th><th>Region Size</th><th>State</th>
        <th>Protection</th><th>Type</th>
        </tr></thead><tbody>
        """

        for entry in entries {
            html += "<tr>"
            html += "<td class=\"mono\">\(entry.baseAddress.hexAddress)</td>"
            html += "<td>\(formatSize(entry.regionSize))</td>"
            html += "<td>\(escapeHTML(entry.state.displayName))</td>"
            html += "<td>\(escapeHTML(entry.protect.shortDescription))</td>"
            html += "<td>\(escapeHTML(entry.type.displayName))</td>"
            html += "</tr>"
        }

        html += "</tbody></table></details>"
        return html
    }

    private static func unloadedModulesSection(_ modules: [UnloadedModule]) -> String {
        var html = """
        <details id="unloaded-modules">
        <summary><h2>Unloaded Modules (\(modules.count))</h2></summary>
        <table class="data-table"><thead><tr>
        <th>Name</th><th>Base Address</th><th>Size</th><th>Timestamp</th>
        </tr></thead><tbody>
        """

        for module in modules {
            html += "<tr>"
            html += "<td>\(escapeHTML(module.shortName))</td>"
            html += "<td class=\"mono\">\(module.baseAddress.hexAddress)</td>"
            html += "<td>\(formatSize(UInt64(module.sizeOfImage)))</td>"
            html += "<td>\(escapeHTML(module.timestamp.formatted()))</td>"
            html += "</tr>"
        }

        html += "</tbody></table></details>"
        return html
    }

    // MARK: - Utilities

    // Internal (not private) so tests can verify the chokepoint
    // directly with crafted input. Production code reaches this via
    // every field interpolation in the report builders above.
    static func escapeHTML(_ string: String) -> String {
        // Strip ANSI escapes, null bytes, bidi formatting marks, zero-
        // width chars BEFORE HTML entity encoding. Without this,
        // dump-sourced module/version/thread name fields would ship
        // raw \x1b / \u{202E} into the HTML output — terminal-aware
        // viewers (less, cat <file.html>) would interpret escapes,
        // and rendered HTML can be visually misleading via RTL
        // overrides. Entity-encoding does not touch these chars.
        string
            .sanitizedForOutput()
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private static func formatSize(_ size: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: size), countStyle: .file)
    }

    /// Render a key/value row in a `<table>`. **Asymmetric contract**:
    /// `label` is HTML-escaped automatically; `value` is inserted RAW so
    /// callers can pass intentional inline markup (`<code>`, `<strong>`,
    /// `<a href>`, etc.). Any dump-sourced string passed as `value` MUST
    /// be wrapped in `escapeHTML(...)` at the call site — every existing
    /// caller does so. Adding a new call site? Read this comment.
    private static func tableRow(_ label: String, _ value: String) -> String {
        "<tr><th>\(escapeHTML(label))</th><td>\(value)</td></tr>"
    }

    // MARK: - HTML Wrapper

    private static func wrapHTML(title: String, body: String) -> String {
        let now = Date().formatted()

        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <title>\(title)</title>
        <style>
        \(HTMLExporterCSS.stylesheet)
        </style>
        </head>
        <body>
        <header>
        <h1>Crash Dump Analysis Report</h1>
        <p class="subtitle">Generated by MiniDumpTruck</p>
        <p class="timestamp">Generated: \(escapeHTML(now))</p>
        </header>

        <nav id="toc">
        <strong>Contents:</strong>
        <a href="#summary">Summary</a>
        <a href="#warnings">Warnings</a>
        <a href="#system-info">System</a>
        <a href="#exception">Exception</a>
        <a href="#analysis">Analysis</a>
        <a href="#threads">Threads</a>
        <a href="#modules">Modules</a>
        <a href="#handles">Handles</a>
        <a href="#memory-info">Memory</a>
        </nav>

        \(body)

        <footer>
        <p>Generated by <strong>MiniDumpTruck</strong> &mdash; Windows Crash Dump Analyzer for macOS</p>
        </footer>
        </body>
        </html>
        """
    }

}
