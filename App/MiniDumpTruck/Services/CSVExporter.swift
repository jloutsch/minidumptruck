import Foundation

/// Generates CSV spreadsheet data from a parsed minidump
public struct CSVExporter: Sendable {

    /// Generate a multi-section CSV from a parsed minidump
    public static func generateCSV(from dump: ParsedMinidump) -> String {
        // UTF-8 BOM for Excel compatibility
        var csv = "\u{FEFF}"

        var sections: [String] = []

        if let moduleList = dump.moduleList {
            sections.append(modulesSection(moduleList.modules))
        }

        if let threadList = dump.threadList {
            sections.append(threadsSection(threadList.threads, threadNames: dump.threadNames))
        }

        if let handleData = dump.handleData, !handleData.entries.isEmpty {
            sections.append(handlesSection(handleData.entries))
        }

        if let memoryInfoList = dump.memoryInfoList, !memoryInfoList.entries.isEmpty {
            sections.append(memoryInfoSection(memoryInfoList.entries))
        }

        if let unloadedModuleList = dump.unloadedModuleList, !unloadedModuleList.modules.isEmpty {
            sections.append(unloadedModulesSection(unloadedModuleList.modules))
        }

        csv += sections.joined(separator: "\n\n")
        return csv
    }

    // MARK: - Section Generators

    private static func modulesSection(_ modules: [ModuleInfo]) -> String {
        var lines: [String] = []
        lines.append("# Modules")
        lines.append(csvRow([
            "Name", "Full Path", "Base Address", "End Address", "Size",
            "File Version", "Product Version", "File Type",
            "PDB Name", "PDB GUID", "Checksum", "Timestamp"
        ]))

        for module in modules {
            lines.append(csvRow([
                module.shortName,
                module.name,
                formatAddress(module.baseAddress),
                formatAddress(module.endAddress),
                String(module.sizeOfImage),
                module.version?.fileVersion ?? "",
                module.version?.productVersion ?? "",
                module.version?.fileTypeDescription ?? "",
                module.codeViewRecord?.pdbShortName ?? "",
                module.codeViewRecord?.guidString ?? "",
                formatHex32(module.checksum),
                formatTimestamp(module.timestamp)
            ]))
        }

        return lines.joined(separator: "\n")
    }

    private static func threadsSection(_ threads: [ThreadInfo], threadNames: ThreadNameList?) -> String {
        var lines: [String] = []
        lines.append("# Threads")
        // Architecture-neutral column names. A dump is either all x64 or
        // all ARM64 so we can pick the header once based on the first
        // available context. IP/SP/FP map to RIP/RSP/RBP on x64 and to
        // PC/SP/FP on ARM64; R0-R3 map to RAX/RCX/RDX/RBX vs X0-X3.
        let firstCtx = threads.lazy.compactMap { $0.context }.first
        let arch = firstCtx?.architectureName ?? "x64"
        let ipName = firstCtx?.ipRegisterName ?? "RIP"
        let spName = firstCtx?.spRegisterName ?? "RSP"
        let fpName = firstCtx?.fpRegisterName ?? "RBP"
        let r0Name = arch == "ARM64" ? "X0" : "RAX"
        let r1Name = arch == "ARM64" ? "X1" : "RCX"
        let r2Name = arch == "ARM64" ? "X2" : "RDX"
        let r3Name = arch == "ARM64" ? "X3" : "RBX"
        lines.append(csvRow([
            "Thread ID", "Name", "Priority", "Priority Class", "Suspend Count",
            "Stack Base", "Stack Size", "TEB",
            ipName, spName, fpName, r0Name, r1Name, r2Name, r3Name
        ]))

        for thread in threads {
            let name = threadNames?.name(for: thread.id) ?? ""
            let ctx = thread.context
            let arch0 = arch0Through3(ctx)
            lines.append(csvRow([
                String(thread.id),
                name,
                thread.priorityDescription,
                String(thread.priorityClass),
                String(thread.suspendCount),
                formatAddress(thread.stack.startOfMemoryRange),
                String(thread.stack.dataSize),
                formatAddress(thread.teb),
                ctx.map { formatAddress($0.instructionPointer) } ?? "",
                ctx.map { formatAddress($0.stackPointer) } ?? "",
                ctx.map { formatAddress($0.framePointer) } ?? "",
                arch0.0,
                arch0.1,
                arch0.2,
                arch0.3
            ]))
        }

        return lines.joined(separator: "\n")
    }

    /// First four architecture-specific GP registers (RAX/RCX/RDX/RBX on
    /// x64, X0–X3 on ARM64) as pre-formatted hex strings. Empty strings
    /// when no context is available.
    private static func arch0Through3(_ ctx: ThreadContext?) -> (String, String, String, String) {
        switch ctx {
        case .amd64(let amd):
            return (formatAddress(amd.rax), formatAddress(amd.rcx),
                    formatAddress(amd.rdx), formatAddress(amd.rbx))
        case .arm64(let arm):
            return (formatAddress(arm.xRegs[0]), formatAddress(arm.xRegs[1]),
                    formatAddress(arm.xRegs[2]), formatAddress(arm.xRegs[3]))
        case .none:
            return ("", "", "", "")
        }
    }

    private static func handlesSection(_ handles: [HandleEntry]) -> String {
        var lines: [String] = []
        lines.append("# Handles")
        lines.append(csvRow([
            "Handle", "Type", "Object Name", "Granted Access",
            "Handle Count", "Pointer Count", "Attributes"
        ]))

        for handle in handles {
            lines.append(csvRow([
                handle.handleHex,
                handle.typeName,
                handle.objectName,
                handle.accessHex,
                String(handle.handleCount),
                String(handle.pointerCount),
                formatHex32(handle.attributes)
            ]))
        }

        return lines.joined(separator: "\n")
    }

    private static func memoryInfoSection(_ entries: [MemoryInfo]) -> String {
        var lines: [String] = []
        lines.append("# Memory Info")
        lines.append(csvRow([
            "Base Address", "Allocation Base", "Region Size",
            "State", "Protection", "Allocation Protection", "Type"
        ]))

        for entry in entries {
            lines.append(csvRow([
                formatAddress(entry.baseAddress),
                formatAddress(entry.allocationBase),
                String(entry.regionSize),
                entry.state.displayName,
                entry.protect.shortDescription,
                entry.allocationProtect.shortDescription,
                entry.type.displayName
            ]))
        }

        return lines.joined(separator: "\n")
    }

    private static func unloadedModulesSection(_ modules: [UnloadedModule]) -> String {
        var lines: [String] = []
        lines.append("# Unloaded Modules")
        lines.append(csvRow([
            "Name", "Base Address", "Size", "Checksum", "Timestamp"
        ]))

        for module in modules {
            lines.append(csvRow([
                module.shortName,
                formatAddress(module.baseAddress),
                String(module.sizeOfImage),
                formatHex32(module.checksum),
                formatTimestamp(module.timestamp)
            ]))
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Utilities

    // Internal (not private) so tests can verify the chokepoint
    // directly with crafted input.
    static func escapeCSV(_ field: String) -> String {
        // Strip control chars, bidi marks, zero-width chars BEFORE
        // CSV-specific handling. Without this, a dump-sourced module
        // name containing \x1b[2J or U+202E ships into the CSV file
        // and triggers the embedded sequence when the file is cat'd
        // or opened in a terminal-aware viewer. The sanitizer also
        // strips \n and \r, so a crafted field can no longer break
        // out of its row by embedding line breaks — the existing
        // RFC-4180 quoting below becomes a defense-in-depth layer.
        var result = field.sanitizedForOutput()

        // CSV injection protection: prefix formula-triggering characters with a single quote
        // to prevent Excel/Sheets from interpreting fields as formulas
        if let first = result.first, "=+-@|%".contains(first) {
            result = "'" + result
        }

        // TAB is preserved by sanitizedForOutput (legitimate in TextReporter)
        // but a field containing TAB will split across columns in TSV-aware
        // readers (Excel Text-to-Columns, awk's default FS, etc.). Quote
        // such fields so they stay as a single column in any consumer.
        if result.contains(",") || result.contains("\"") || result.contains("\n") || result.contains("\r") || result.contains("\t") {
            return "\"" + result.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return result
    }

    private static func csvRow(_ fields: [String]) -> String {
        fields.map { escapeCSV($0) }.joined(separator: ",")
    }

    private static func formatAddress(_ address: UInt64) -> String {
        String(format: "0x%016llX", address)
    }

    private static func formatHex32(_ value: UInt32) -> String {
        String(format: "0x%08X", value)
    }

    private static func formatTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}
