import SwiftUI
import MiniDumpTruckCore
import UniformTypeIdentifiers

/// UTType for Windows minidump files
extension UTType {
    static var minidump: UTType {
        UTType(importedAs: "com.microsoft.windows-minidump", conformingTo: .data)
    }
}

/// Document wrapper for minidump files
struct MinidumpDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.minidump, .data] }

    let parsedDump: ParsedMinidump?
    let parseError: Error?
    let fileSize: Int

    init() {
        self.parsedDump = nil
        self.parseError = nil
        self.fileSize = 0
    }

    /// Initialize with an already-parsed dump (for programmatic loading)
    init(parsedDump: ParsedMinidump, fileSize: Int) {
        self.parsedDump = parsedDump
        self.parseError = nil
        self.fileSize = fileSize
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }

        self.fileSize = data.count

        do {
            self.parsedDump = try MinidumpParser.parse(data: data)
            self.parseError = nil
        } catch {
            self.parsedDump = nil
            self.parseError = error
        }
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        // Read-only document
        throw CocoaError(.fileWriteNoPermission)
    }

    // MARK: - Convenience accessors

    var header: MinidumpHeader? { parsedDump?.header }
    var streamDirectory: StreamDirectory? { parsedDump?.streamDirectory }
    var systemInfo: SystemInfo? { parsedDump?.systemInfo }
    var miscInfo: MiscInfo? { parsedDump?.miscInfo }
    var exception: ExceptionInfo? { parsedDump?.exception }
    var threads: [ThreadInfo] { parsedDump?.threadList?.threads ?? [] }
    var modules: [ModuleInfo] { parsedDump?.moduleList?.modules ?? [] }
    var memoryRegions: [MemoryRegion] { parsedDump?.memory64List?.regions ?? [] }
    var memoryInfoEntries: [MemoryInfo] { parsedDump?.memoryInfoList?.entries ?? [] }
    var unloadedModules: [UnloadedModule] { parsedDump?.unloadedModuleList?.modules ?? [] }
    var threadNames: ThreadNameList? { parsedDump?.threadNames }
    var handleData: HandleDataList? { parsedDump?.handleData }
    var handles: [HandleEntry] { parsedDump?.handleData?.entries ?? [] }

    var faultingThread: ThreadInfo? {
        guard let dump = parsedDump else { return nil }
        return MinidumpParser.faultingThread(in: dump)
    }

    func resolveAddress(_ address: UInt64) -> String {
        guard let dump = parsedDump else {
            return String(format: "0x%016llX", address)
        }
        return MinidumpParser.resolveAddress(address, in: dump)
    }

    func readMemory(at address: UInt64, size: Int) -> Data? {
        guard let dump = parsedDump else { return nil }
        return MinidumpParser.readMemory(from: dump, at: address, size: size)
    }

    func module(containing address: UInt64) -> ModuleInfo? {
        parsedDump?.moduleList?.module(containing: address)
    }

    func threadName(for threadId: UInt32) -> String? {
        threadNames?.name(for: threadId)
    }

    func unloadedModule(containing address: UInt64) -> UnloadedModule? {
        parsedDump?.unloadedModuleList?.module(containing: address)
    }
}
