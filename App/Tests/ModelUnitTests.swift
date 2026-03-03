import Foundation
import Testing
@testable import MiniDumpTruckCore

// MARK: - Binary Data Helpers

/// Helpers for building synthetic binary data in little-endian format
private extension Data {
    static func withCapacity(_ capacity: Int) -> Data {
        Data(repeating: 0, count: capacity)
    }

    mutating func writeUInt8(_ value: UInt8, at offset: Int) {
        self[offset] = value
    }

    mutating func writeUInt16(_ value: UInt16, at offset: Int) {
        self[offset] = UInt8(value & 0xFF)
        self[offset + 1] = UInt8((value >> 8) & 0xFF)
    }

    mutating func writeUInt32(_ value: UInt32, at offset: Int) {
        for i in 0..<4 {
            self[offset + i] = UInt8((value >> (i * 8)) & 0xFF)
        }
    }

    mutating func writeUInt64(_ value: UInt64, at offset: Int) {
        for i in 0..<8 {
            self[offset + i] = UInt8((value >> (i * 8)) & 0xFF)
        }
    }

    /// Write a MINIDUMP_STRING (length + UTF-16LE data) at offset
    mutating func writeMinidumpString(_ string: String, at offset: Int) {
        let utf16 = Array(string.utf16)
        let byteLen = UInt32(utf16.count * 2)
        writeUInt32(byteLen, at: offset)
        for (i, unit) in utf16.enumerated() {
            writeUInt16(unit, at: offset + 4 + i * 2)
        }
    }
}

/// Build a minimal valid minidump header
private func makeMinidumpHeader(
    numberOfStreams: UInt32 = 0,
    streamDirectoryRva: UInt32 = 32,
    flags: UInt64 = 0
) -> Data {
    var data = Data(repeating: 0, count: 32)
    data.writeUInt32(0x504D444D, at: 0)  // MDMP signature
    data.writeUInt16(0xA793, at: 4)       // version
    data.writeUInt16(0, at: 6)            // implementation version
    data.writeUInt32(numberOfStreams, at: 8)
    data.writeUInt32(streamDirectoryRva, at: 12)
    data.writeUInt32(0, at: 16)           // checksum
    data.writeUInt32(1700000000, at: 20)  // timestamp
    data.writeUInt64(flags, at: 24)
    return data
}

// MARK: - StreamType Tests

@Suite("StreamType")
struct StreamTypeTests {
    @Test func allCasesCount() {
        #expect(StreamType.allCases.count == 25)
    }

    @Test func displayNames() {
        #expect(StreamType.threadList.displayName == "Thread List")
        #expect(StreamType.moduleList.displayName == "Module List")
        #expect(StreamType.exception.displayName == "Exception")
        #expect(StreamType.systemInfo.displayName == "System Info")
        #expect(StreamType.memory64List.displayName == "Memory64 List")
        #expect(StreamType.memoryList.displayName == "Memory List")
        #expect(StreamType.handleData.displayName == "Handle Data")
        #expect(StreamType.miscInfo.displayName == "Misc Info")
        #expect(StreamType.threadNames.displayName == "Thread Names")
        #expect(StreamType.unloadedModuleList.displayName == "Unloaded Module List")
    }

    @Test func systemImages() {
        #expect(StreamType.threadList.systemImage == "text.line.first.and.arrowtriangle.forward")
        #expect(StreamType.moduleList.systemImage == "shippingbox")
        #expect(StreamType.memoryList.systemImage == "memorychip")
        #expect(StreamType.exception.systemImage == "exclamationmark.triangle")
        #expect(StreamType.systemInfo.systemImage == "info.circle")
        #expect(StreamType.handleData.systemImage == "link")
        #expect(StreamType.miscInfo.systemImage == "ellipsis.circle")
    }

    @Test func rawValues() {
        #expect(StreamType.threadList.rawValue == 3)
        #expect(StreamType.moduleList.rawValue == 4)
        #expect(StreamType.memoryList.rawValue == 5)
        #expect(StreamType.exception.rawValue == 6)
        #expect(StreamType.systemInfo.rawValue == 7)
        #expect(StreamType.memory64List.rawValue == 9)
        #expect(StreamType.threadNames.rawValue == 24)
    }
}

// MARK: - StreamDirectoryEntry Tests

@Suite("StreamDirectoryEntry")
struct StreamDirectoryEntryTests {
    @Test func parsesValidEntry() {
        var data = Data(repeating: 0, count: 12)
        data.writeUInt32(3, at: 0)    // streamType = threadList
        data.writeUInt32(100, at: 4)  // dataSize
        data.writeUInt32(200, at: 8)  // rva
        let entry = StreamDirectoryEntry(from: data, at: 0)
        #expect(entry != nil)
        #expect(entry?.streamType == 3)
        #expect(entry?.dataSize == 100)
        #expect(entry?.rva == 200)
        #expect(entry?.type == .threadList)
        #expect(entry?.displayName == "Thread List")
    }

    @Test func unknownStreamType() {
        var data = Data(repeating: 0, count: 12)
        data.writeUInt32(9999, at: 0)
        data.writeUInt32(50, at: 4)
        data.writeUInt32(100, at: 8)
        let entry = StreamDirectoryEntry(from: data, at: 0)
        #expect(entry != nil)
        #expect(entry?.type == nil)
        #expect(entry?.displayName == "Unknown (9999)")
        #expect(entry?.systemImage == "questionmark.circle")
    }

    @Test func failsOnTruncatedData() {
        let data = Data(repeating: 0, count: 8)  // Need 12
        let entry = StreamDirectoryEntry(from: data, at: 0)
        #expect(entry == nil)
    }

    @Test func structSize() {
        #expect(StreamDirectoryEntry.size == 12)
    }
}

// MARK: - MinidumpHeader Tests (Synthetic)

@Suite("MinidumpHeader Synthetic")
struct MinidumpHeaderSyntheticTests {
    @Test func parsesValidHeader() {
        let data = makeMinidumpHeader(numberOfStreams: 5, streamDirectoryRva: 32, flags: 0x03)
        let header = MinidumpHeader(from: data)
        #expect(header != nil)
        #expect(header?.numberOfStreams == 5)
        #expect(header?.streamDirectoryRva == 32)
        #expect(header?.flags == 0x03)
    }

    @Test func rejectsWrongSignature() {
        var data = makeMinidumpHeader()
        data.writeUInt32(0xDEADBEEF, at: 0)
        #expect(MinidumpHeader(from: data) == nil)
    }

    @Test func rejectsWrongVersion() {
        var data = makeMinidumpHeader()
        data.writeUInt16(0x1234, at: 4)
        #expect(MinidumpHeader(from: data) == nil)
    }

    @Test func rejectsTruncatedData() {
        let data = Data(repeating: 0, count: 16)  // Need 32
        #expect(MinidumpHeader(from: data) == nil)
    }

    @Test func timestampConversion() {
        let data = makeMinidumpHeader()
        let header = MinidumpHeader(from: data)!
        #expect(header.timestamp.timeIntervalSince1970 == 1700000000)
    }

    @Test func flagsDescriptions() {
        let data = makeMinidumpHeader(flags: 0x07)  // DataSegs + FullMemory + HandleData
        let header = MinidumpHeader(from: data)!
        let flags = header.flagsDescription
        #expect(flags.contains("WithDataSegs"))
        #expect(flags.contains("WithFullMemory"))
        #expect(flags.contains("WithHandleData"))
    }

    @Test func normalFlagsDescription() {
        let descriptions = MinidumpType.descriptions(for: 0)
        #expect(descriptions == ["Normal"])
    }
}

// MARK: - ExceptionInfo Tests

@Suite("ExceptionInfo")
struct ExceptionInfoTests {
    private func makeExceptionData(
        threadId: UInt32 = 1,
        exceptionCode: UInt32 = 0xC0000005,
        exceptionAddress: UInt64 = 0x7FF812345678,
        numberOfParameters: UInt32 = 2,
        parameters: [UInt64] = [0, 0x0000DEAD]
    ) -> Data {
        var data = Data(repeating: 0, count: 168)
        data.writeUInt32(threadId, at: 0)
        // Alignment at 4
        data.writeUInt32(exceptionCode, at: 8)
        data.writeUInt32(0, at: 12)  // flags
        data.writeUInt64(0, at: 16)  // exceptionRecord
        data.writeUInt64(exceptionAddress, at: 24)
        data.writeUInt32(numberOfParameters, at: 32)
        // Alignment at 36
        for (i, param) in parameters.prefix(15).enumerated() {
            data.writeUInt64(param, at: 40 + i * 8)
        }
        // Context location at offset 160
        data.writeUInt32(1232, at: 160) // contextDataSize
        data.writeUInt32(500, at: 164)  // contextRva
        return data
    }

    @Test func parsesAccessViolation() {
        let data = makeExceptionData()
        let info = ExceptionInfo(from: data, at: 0)
        #expect(info != nil)
        #expect(info?.threadId == 1)
        #expect(info?.exceptionCode == 0xC0000005)
        #expect(info?.exceptionAddress == 0x7FF812345678)
    }

    @Test func accessViolationDetailsRead() {
        let data = makeExceptionData(parameters: [0, 0x0000DEAD])
        let info = ExceptionInfo(from: data, at: 0)!
        let details = info.accessViolationDetails
        #expect(details != nil)
        #expect(details!.contains("reading from"))
    }

    @Test func accessViolationDetailsWrite() {
        let data = makeExceptionData(parameters: [1, 0x0000DEAD])
        let info = ExceptionInfo(from: data, at: 0)!
        let details = info.accessViolationDetails
        #expect(details!.contains("writing to"))
    }

    @Test func accessViolationDetailsExecute() {
        let data = makeExceptionData(parameters: [8, 0x0000DEAD])
        let info = ExceptionInfo(from: data, at: 0)!
        let details = info.accessViolationDetails
        #expect(details!.contains("executing"))
    }

    @Test func accessViolationDetailsUnknownOp() {
        let data = makeExceptionData(parameters: [99, 0x0000DEAD])
        let info = ExceptionInfo(from: data, at: 0)!
        let details = info.accessViolationDetails
        #expect(details!.contains("accessing"))
    }

    @Test func noAccessViolationDetailsForOtherExceptions() {
        let data = makeExceptionData(exceptionCode: 0xC00000FD)  // STACK_OVERFLOW
        let info = ExceptionInfo(from: data, at: 0)!
        #expect(info.accessViolationDetails == nil)
    }

    @Test func noAccessViolationDetailsWithoutParams() {
        let data = makeExceptionData(exceptionCode: 0xC0000005, numberOfParameters: 0, parameters: [])
        let info = ExceptionInfo(from: data, at: 0)!
        #expect(info.accessViolationDetails == nil)
    }

    @Test func contextLocation() {
        let data = makeExceptionData()
        let info = ExceptionInfo(from: data, at: 0)!
        #expect(info.contextDataSize == 1232)
        #expect(info.contextRva == 500)
    }

    @Test func parametersAreCapped() {
        // numberOfParameters is capped at 15
        let data = makeExceptionData(numberOfParameters: 100)
        let info = ExceptionInfo(from: data, at: 0)!
        #expect(info.numberOfParameters == 15)
    }

    @Test func failsOnTruncatedData() {
        let data = Data(repeating: 0, count: 100)  // Need 168
        #expect(ExceptionInfo(from: data, at: 0) == nil)
    }
}

// MARK: - SystemInfo Tests

@Suite("SystemInfo")
struct SystemInfoTests {
    private func makeSystemInfoData(
        arch: UInt16 = 9,  // amd64
        processorLevel: UInt16 = 6,
        processorRevision: UInt16 = 0x0A07,
        numberOfProcessors: UInt8 = 8,
        productType: UInt8 = 1,  // workstation
        majorVersion: UInt32 = 10,
        minorVersion: UInt32 = 0,
        buildNumber: UInt32 = 22621,
        platformId: UInt32 = 2,  // NT
        csdVersionRva: UInt32 = 0,
        vendorId: [UInt32] = [0x756E6547, 0x49656E69, 0x6C65746E]  // "GenuineIntel"
    ) -> Data {
        var data = Data(repeating: 0, count: 56)
        data.writeUInt16(arch, at: 0)
        data.writeUInt16(processorLevel, at: 2)
        data.writeUInt16(processorRevision, at: 4)
        data.writeUInt8(numberOfProcessors, at: 6)
        data.writeUInt8(productType, at: 7)
        data.writeUInt32(majorVersion, at: 8)
        data.writeUInt32(minorVersion, at: 12)
        data.writeUInt32(buildNumber, at: 16)
        data.writeUInt32(platformId, at: 20)
        data.writeUInt32(csdVersionRva, at: 24)
        data.writeUInt16(0, at: 28) // suiteFlags
        // CPU info at offset 32 (x86/x64)
        data.writeUInt32(vendorId[0], at: 32)
        data.writeUInt32(vendorId[1], at: 36)
        data.writeUInt32(vendorId[2], at: 40)
        data.writeUInt32(0x000806EC, at: 44) // versionInfo
        data.writeUInt32(0xBFEBFBFF, at: 48) // featureInfo
        data.writeUInt32(0, at: 52)           // extendedFeatures
        return data
    }

    @Test func parsesX64SystemInfo() {
        let data = makeSystemInfoData()
        let info = SystemInfo(from: data, at: 0)
        #expect(info != nil)
        #expect(info?.processorArchitecture == .amd64)
        #expect(info?.numberOfProcessors == 8)
        #expect(info?.majorVersion == 10)
        #expect(info?.buildNumber == 22621)
    }

    @Test func windowsVersionNames() {
        let win11 = makeSystemInfoData(majorVersion: 10, minorVersion: 0, buildNumber: 22621)
        #expect(SystemInfo(from: win11, at: 0)?.windowsVersionName == "Windows 11")

        let win10 = makeSystemInfoData(majorVersion: 10, minorVersion: 0, buildNumber: 19045)
        #expect(SystemInfo(from: win10, at: 0)?.windowsVersionName == "Windows 10")

        let win81 = makeSystemInfoData(majorVersion: 6, minorVersion: 3, buildNumber: 9600)
        #expect(SystemInfo(from: win81, at: 0)?.windowsVersionName == "Windows 8.1")

        let win8 = makeSystemInfoData(majorVersion: 6, minorVersion: 2, buildNumber: 9200)
        #expect(SystemInfo(from: win8, at: 0)?.windowsVersionName == "Windows 8")

        let win7 = makeSystemInfoData(majorVersion: 6, minorVersion: 1, buildNumber: 7601)
        #expect(SystemInfo(from: win7, at: 0)?.windowsVersionName == "Windows 7")

        let vista = makeSystemInfoData(majorVersion: 6, minorVersion: 0, buildNumber: 6002)
        #expect(SystemInfo(from: vista, at: 0)?.windowsVersionName == "Windows Vista")

        let xp = makeSystemInfoData(majorVersion: 5, minorVersion: 1, buildNumber: 2600)
        #expect(SystemInfo(from: xp, at: 0)?.windowsVersionName == "Windows XP")

        let win2k = makeSystemInfoData(majorVersion: 5, minorVersion: 0, buildNumber: 2195)
        #expect(SystemInfo(from: win2k, at: 0)?.windowsVersionName == "Windows 2000")
    }

    @Test func unknownWindowsVersion() {
        let data = makeSystemInfoData(majorVersion: 99, minorVersion: 1, buildNumber: 1)
        let info = SystemInfo(from: data, at: 0)!
        #expect(info.windowsVersionName == "Windows 99.1")
    }

    @Test func osVersionString() {
        let data = makeSystemInfoData(majorVersion: 10, minorVersion: 0, buildNumber: 22621)
        let info = SystemInfo(from: data, at: 0)!
        #expect(info.osVersionString == "10.0 Build 22621")
    }

    @Test func cpuVendorString() {
        let data = makeSystemInfoData()
        let info = SystemInfo(from: data, at: 0)!
        #expect(info.cpuInfo.vendorString == "GenuineIntel")
        #expect(info.cpuInfo.isX86 == true)
    }

    @Test func cpuVersionFields() {
        let data = makeSystemInfoData()
        let info = SystemInfo(from: data, at: 0)!
        // versionInfo = 0x000806EC
        #expect(info.cpuInfo.stepping == 0xC)    // bits 0-3
        #expect(info.cpuInfo.model == 0xE)       // bits 4-7
        #expect(info.cpuInfo.family == 6)         // bits 8-11
        #expect(info.cpuInfo.extendedModel == 8)  // bits 16-19
    }

    @Test func cpuDisplayModel() {
        let data = makeSystemInfoData()
        let info = SystemInfo(from: data, at: 0)!
        // family=6, so displayModel = model + (extendedModel << 4) = 0xE + (0x8 << 4) = 0x8E
        #expect(info.cpuInfo.displayModel == 0x8E)
    }

    @Test func cpuDisplayFamilyNormal() {
        let data = makeSystemInfoData()
        let info = SystemInfo(from: data, at: 0)!
        // family=6, not 15, so displayFamily = family = 6
        #expect(info.cpuInfo.displayFamily == 6)
    }

    @Test func processorArchitectureDisplayNames() {
        #expect(ProcessorArchitecture.intel.displayName == "x86 (Intel)")
        #expect(ProcessorArchitecture.amd64.displayName == "x64 (AMD64)")
        #expect(ProcessorArchitecture.arm64.displayName == "ARM64")
        #expect(ProcessorArchitecture.arm.displayName == "ARM")
        #expect(ProcessorArchitecture.unknown.displayName == "Unknown")
    }

    @Test func productTypeDisplayNames() {
        #expect(ProductType.workstation.displayName == "Workstation")
        #expect(ProductType.domainController.displayName == "Domain Controller")
        #expect(ProductType.server.displayName == "Server")
    }

    @Test func platformIdDisplayNames() {
        #expect(PlatformId.win32s.displayName == "Win32s")
        #expect(PlatformId.win32Windows.displayName == "Windows 9x")
        #expect(PlatformId.win32NT.displayName == "Windows NT")
    }

    @Test func nonX86CpuInfo() {
        // ARM64 architecture
        var data = Data(repeating: 0, count: 56)
        data.writeUInt16(12, at: 0)   // arm64
        data.writeUInt16(0, at: 2)
        data.writeUInt16(0, at: 4)
        data.writeUInt8(4, at: 6)
        data.writeUInt8(1, at: 7)
        data.writeUInt32(10, at: 8)
        data.writeUInt32(0, at: 12)
        data.writeUInt32(22000, at: 16)
        data.writeUInt32(2, at: 20)
        data.writeUInt32(0, at: 24)
        data.writeUInt16(0, at: 28)
        // Non-x86: processorFeatures[2]
        data.writeUInt64(0x1234567890ABCDEF, at: 32)
        data.writeUInt64(0xFEDCBA0987654321, at: 40)

        let info = SystemInfo(from: data, at: 0)
        #expect(info != nil)
        #expect(info?.processorArchitecture == .arm64)
        #expect(info?.cpuInfo.isX86 == false)
        #expect(info?.cpuInfo.processorFeatures?.count == 2)
        #expect(info?.cpuInfo.vendorString == "N/A")
    }

    @Test func failsOnTruncatedData() {
        let data = Data(repeating: 0, count: 20)
        #expect(SystemInfo(from: data, at: 0) == nil)
    }
}

// MARK: - ThreadInfo Tests

@Suite("ThreadInfo")
struct ThreadInfoTests {
    private func makeThreadData(
        threadId: UInt32 = 42,
        suspendCount: UInt32 = 0,
        priorityClass: UInt32 = 32,
        priority: UInt32 = 8,
        teb: UInt64 = 0x7FFD00000000,
        stackStart: UInt64 = 0x100000,
        stackSize: UInt32 = 0x10000,
        stackRva: UInt32 = 500,
        ctxSize: UInt32 = 1232,
        ctxRva: UInt32 = 1000
    ) -> Data {
        var data = Data(repeating: 0, count: 48)
        data.writeUInt32(threadId, at: 0)
        data.writeUInt32(suspendCount, at: 4)
        data.writeUInt32(priorityClass, at: 8)
        data.writeUInt32(priority, at: 12)
        data.writeUInt64(teb, at: 16)
        // Stack (MinidumpMemoryDescriptor at 24): start(8) + dataSize(4) + rva(4)
        data.writeUInt64(stackStart, at: 24)
        data.writeUInt32(stackSize, at: 32)
        data.writeUInt32(stackRva, at: 36)
        // Context location at 40: dataSize(4) + rva(4)
        data.writeUInt32(ctxSize, at: 40)
        data.writeUInt32(ctxRva, at: 44)
        return data
    }

    @Test func parsesValidThread() {
        let data = makeThreadData()
        let thread = ThreadInfo(from: data, at: 0)
        #expect(thread != nil)
        #expect(thread?.id == 42)
        #expect(thread?.priority == 8)
        #expect(thread?.teb == 0x7FFD00000000)
    }

    @Test func priorityDescriptions() {
        func priority(_ p: UInt32) -> String {
            let data = makeThreadData(priority: p)
            return ThreadInfo(from: data, at: 0)!.priorityDescription
        }
        #expect(priority(0) == "Idle")
        #expect(priority(3) == "Below Normal")
        #expect(priority(8) == "Normal")
        #expect(priority(10) == "Above Normal")
        #expect(priority(15) == "High")
        #expect(priority(20) == "Realtime")
        #expect(priority(100) == "Unknown (100)")
    }

    @Test func stackMemoryDescriptor() {
        let data = makeThreadData(stackStart: 0xABCD0000, stackSize: 0x8000, stackRva: 200)
        let thread = ThreadInfo(from: data, at: 0)!
        #expect(thread.stack.startOfMemoryRange == 0xABCD0000)
        #expect(thread.stack.dataSize == 0x8000)
        #expect(thread.stack.rva == 200)
        #expect(thread.stack.endAddress == 0xABCD0000 + 0x8000)
    }

    @Test func contextNotSetByDefault() {
        let data = makeThreadData()
        let thread = ThreadInfo(from: data, at: 0)!
        #expect(thread.context == nil)
    }

    @Test func failsOnTruncatedData() {
        let data = Data(repeating: 0, count: 30)  // Need 48
        #expect(ThreadInfo(from: data, at: 0) == nil)
    }

    @Test func structSize() {
        #expect(ThreadInfo.size == 48)
    }
}

// MARK: - ThreadList Tests

@Suite("ThreadList")
struct ThreadListTests {
    @Test func parsesEmptyList() {
        var data = Data(repeating: 0, count: 4)
        data.writeUInt32(0, at: 0)  // count = 0
        let list = ThreadList(from: data, at: 0)
        #expect(list != nil)
        #expect(list?.threads.count == 0)
    }

    @Test func rejectsCountExceedingMax() {
        var data = Data(repeating: 0, count: 4)
        data.writeUInt32(ThreadList.maxThreads + 1, at: 0)
        #expect(ThreadList(from: data, at: 0) == nil)
    }

    @Test func lookupThreadById() {
        // Build a list with 1 thread
        var data = Data(repeating: 0, count: 4 + 48)
        data.writeUInt32(1, at: 0)
        // Thread at offset 4
        data.writeUInt32(99, at: 4)  // threadId
        data.writeUInt32(0, at: 8)   // suspendCount
        data.writeUInt32(32, at: 12) // priorityClass
        data.writeUInt32(8, at: 16)  // priority
        data.writeUInt64(0, at: 20)  // teb
        data.writeUInt64(0, at: 28)  // stack start
        data.writeUInt32(0, at: 36)  // stack dataSize
        data.writeUInt32(0, at: 40)  // stack rva
        data.writeUInt32(0, at: 44)  // ctx dataSize
        data.writeUInt32(0, at: 48)  // ctx rva

        let list = ThreadList(from: data, at: 0)!
        #expect(list.thread(withId: 99) != nil)
        #expect(list.thread(withId: 1) == nil)
    }
}

// MARK: - ModuleInfo Tests

@Suite("ModuleInfo")
struct ModuleInfoTests {
    private func makeModuleData(
        baseAddress: UInt64 = 0x7FF800000000,
        sizeOfImage: UInt32 = 0x100000,
        checksum: UInt32 = 0xABCD,
        timeDateStamp: UInt32 = 1700000000,
        moduleNameRva: UInt32 = 0
    ) -> Data {
        var data = Data(repeating: 0, count: 108)
        data.writeUInt64(baseAddress, at: 0)
        data.writeUInt32(sizeOfImage, at: 8)
        data.writeUInt32(checksum, at: 12)
        data.writeUInt32(timeDateStamp, at: 16)
        data.writeUInt32(moduleNameRva, at: 20)
        // Version info at offset 24 - skip (no valid signature)
        return data
    }

    @Test func parsesBasicFields() {
        let data = makeModuleData()
        let module = ModuleInfo(from: data, at: 0)
        #expect(module != nil)
        #expect(module?.baseAddress == 0x7FF800000000)
        #expect(module?.sizeOfImage == 0x100000)
    }

    @Test func endAddress() {
        let data = makeModuleData(baseAddress: 0x1000, sizeOfImage: 0x2000)
        let module = ModuleInfo(from: data, at: 0)!
        #expect(module.endAddress == 0x3000)
    }

    @Test func endAddressOverflow() {
        let data = makeModuleData(baseAddress: UInt64.max - 100, sizeOfImage: 200)
        let module = ModuleInfo(from: data, at: 0)!
        #expect(module.endAddress == UInt64.max)
    }

    @Test func containsAddress() {
        let data = makeModuleData(baseAddress: 0x1000, sizeOfImage: 0x2000)
        let module = ModuleInfo(from: data, at: 0)!
        #expect(module.contains(address: 0x1000))
        #expect(module.contains(address: 0x2FFF))
        #expect(!module.contains(address: 0x0FFF))
        #expect(!module.contains(address: 0x3000))
    }

    @Test func offsetForAddress() {
        let data = makeModuleData(baseAddress: 0x1000, sizeOfImage: 0x2000)
        let module = ModuleInfo(from: data, at: 0)!
        #expect(module.offset(for: 0x1500) == 0x500)
        #expect(module.offset(for: 0x1000) == 0)
        #expect(module.offset(for: 0x5000) == nil)
    }

    @Test func shortNameFromWindowsPath() {
        let data = makeModuleData()
        var module = ModuleInfo(from: data, at: 0)!
        module.setName("C:\\Windows\\System32\\ntdll.dll")
        #expect(module.shortName == "ntdll.dll")
    }

    @Test func shortNameFromUnixPath() {
        let data = makeModuleData()
        var module = ModuleInfo(from: data, at: 0)!
        module.setName("/usr/lib/libfoo.so")
        #expect(module.shortName == "libfoo.so")
    }

    @Test func shortNameNoPath() {
        let data = makeModuleData()
        var module = ModuleInfo(from: data, at: 0)!
        module.setName("myapp.exe")
        #expect(module.shortName == "myapp.exe")
    }

    @Test func structSize() {
        #expect(ModuleInfo.size == 108)
    }
}

// MARK: - ModuleVersion Tests

@Suite("ModuleVersion")
struct ModuleVersionTests {
    private func makeVersionData(
        fileVersionHigh: UInt32 = 0x000A0000,  // 10.0
        fileVersionLow: UInt32 = 0x5895_0001,  // 22677.1
        productVersionHigh: UInt32 = 0x000A0000,
        productVersionLow: UInt32 = 0x5895_0001,
        fileType: UInt32 = 2  // DLL
    ) -> Data {
        var data = Data(repeating: 0, count: 52)
        data.writeUInt32(0xFEEF04BD, at: 0)  // signature
        data.writeUInt32(0x00010000, at: 4)   // structVersion
        data.writeUInt32(fileVersionHigh, at: 8)
        data.writeUInt32(fileVersionLow, at: 12)
        data.writeUInt32(productVersionHigh, at: 16)
        data.writeUInt32(productVersionLow, at: 20)
        data.writeUInt32(0, at: 24)   // fileFlagsMask
        data.writeUInt32(0, at: 28)   // fileFlags
        data.writeUInt32(0x40004, at: 32) // fileOS (NT + Win32)
        data.writeUInt32(fileType, at: 36)
        data.writeUInt32(0, at: 40)   // fileSubtype
        data.writeUInt32(0, at: 44)   // fileDateHigh
        data.writeUInt32(0, at: 48)   // fileDateLow
        return data
    }

    @Test func parsesValidVersion() {
        let data = makeVersionData()
        let version = ModuleVersion(from: data, at: 0)
        #expect(version != nil)
        #expect(version?.signature == 0xFEEF04BD)
    }

    @Test func rejectsWrongSignature() {
        var data = makeVersionData()
        data.writeUInt32(0xDEADBEEF, at: 0)
        #expect(ModuleVersion(from: data, at: 0) == nil)
    }

    @Test func fileVersionString() {
        // fileVersionHigh = 0x000A_0000 -> major=10, minor=0
        // fileVersionLow = 0x5895_0001 -> build=22677, revision=1
        let data = makeVersionData()
        let version = ModuleVersion(from: data, at: 0)!
        #expect(version.fileVersion == "10.0.22677.1")
    }

    @Test func productVersionString() {
        let data = makeVersionData()
        let version = ModuleVersion(from: data, at: 0)!
        #expect(version.productVersion == "10.0.22677.1")
    }

    @Test func fileTypeDescriptions() {
        func desc(_ type: UInt32) -> String {
            let data = makeVersionData(fileType: type)
            return ModuleVersion(from: data, at: 0)!.fileTypeDescription
        }
        #expect(desc(1) == "Application")
        #expect(desc(2) == "DLL")
        #expect(desc(3) == "Driver")
        #expect(desc(4) == "Font")
        #expect(desc(5) == "VXD")
        #expect(desc(7) == "Static Library")
        #expect(desc(99) == "Unknown")
    }
}

// MARK: - ModuleList Tests

@Suite("ModuleList")
struct ModuleListTests {
    @Test func rejectsCountExceedingMax() {
        var data = Data(repeating: 0, count: 4)
        data.writeUInt32(ModuleList.maxModules + 1, at: 0)
        #expect(ModuleList(from: data, at: 0) == nil)
    }

    @Test func resolveAddressInModule() {
        // Build a module list with 1 module
        var data = Data(repeating: 0, count: 4 + 108 + 50)
        data.writeUInt32(1, at: 0)
        // Module at offset 4
        data.writeUInt64(0x7FF800000000, at: 4)
        data.writeUInt32(0x100000, at: 12)
        data.writeUInt32(0, at: 16) // checksum
        data.writeUInt32(0, at: 20) // timestamp
        let nameRva: UInt32 = UInt32(4 + 108) // After module data
        data.writeUInt32(nameRva, at: 24) // moduleNameRva
        // Write module name as MINIDUMP_STRING at nameRva
        let name = "test.dll"
        let utf16 = Array(name.utf16)
        data.writeUInt32(UInt32(utf16.count * 2), at: Int(nameRva))
        for (i, u) in utf16.enumerated() {
            data.writeUInt16(u, at: Int(nameRva) + 4 + i * 2)
        }

        let list = ModuleList(from: data, at: 0)
        #expect(list != nil)
        #expect(list?.modules.count == 1)

        let resolved = list?.resolve(address: 0x7FF800001000)
        #expect(resolved == "test.dll+0x1000")
    }

    @Test func resolveAddressNotInModule() {
        var data = Data(repeating: 0, count: 4)
        data.writeUInt32(0, at: 0)
        let list = ModuleList(from: data, at: 0)!
        let resolved = list.resolve(address: 0xDEAD)
        #expect(resolved == "0x000000000000DEAD")
    }
}

// MARK: - ThreadContext Tests

@Suite("ThreadContext")
struct ThreadContextTests {
    private func makeContextData(
        contextFlags: UInt32 = 0x0010000F,
        rax: UInt64 = 1, rbx: UInt64 = 2, rcx: UInt64 = 3, rdx: UInt64 = 4,
        rsp: UInt64 = 0x80000, rbp: UInt64 = 0x80100,
        rip: UInt64 = 0x7FF800001234,
        eflags: UInt32 = 0x0246  // PF+ZF+IF
    ) -> Data {
        var data = Data(repeating: 0, count: ThreadContext.size)
        // P1Home-P6Home at 0-47 (zeros)
        data.writeUInt32(contextFlags, at: 48)
        data.writeUInt32(0, at: 52) // mxCsr
        // Segment registers at 56
        data.writeUInt16(0x33, at: 56) // CS
        data.writeUInt16(0x2B, at: 58) // DS
        data.writeUInt16(0x2B, at: 60) // ES
        data.writeUInt16(0x53, at: 62) // FS
        data.writeUInt16(0x2B, at: 64) // GS
        data.writeUInt16(0x2B, at: 66) // SS
        data.writeUInt32(eflags, at: 68)
        // Debug registers at 72 (zeros)
        // General purpose at 120
        data.writeUInt64(rax, at: 120)
        data.writeUInt64(rcx, at: 128)
        data.writeUInt64(rdx, at: 136)
        data.writeUInt64(rbx, at: 144)
        data.writeUInt64(rsp, at: 152)
        data.writeUInt64(rbp, at: 160)
        data.writeUInt64(0, at: 168) // rsi
        data.writeUInt64(0, at: 176) // rdi
        data.writeUInt64(0, at: 184) // r8
        data.writeUInt64(0, at: 192) // r9
        data.writeUInt64(0, at: 200) // r10
        data.writeUInt64(0, at: 208) // r11
        data.writeUInt64(0, at: 216) // r12
        data.writeUInt64(0, at: 224) // r13
        data.writeUInt64(0, at: 232) // r14
        data.writeUInt64(0, at: 240) // r15
        data.writeUInt64(rip, at: 248)
        return data
    }

    @Test func parsesRegisters() {
        let data = makeContextData()
        let ctx = ThreadContext(from: data, at: 0)
        #expect(ctx != nil)
        #expect(ctx?.rax == 1)
        #expect(ctx?.rbx == 2)
        #expect(ctx?.rcx == 3)
        #expect(ctx?.rdx == 4)
        #expect(ctx?.rip == 0x7FF800001234)
    }

    @Test func segmentRegisters() {
        let data = makeContextData()
        let ctx = ThreadContext(from: data, at: 0)!
        #expect(ctx.segCs == 0x33)
        #expect(ctx.segDs == 0x2B)
        let segs = ctx.segmentRegisters
        #expect(segs.count == 6)
        #expect(segs[0].name == "CS")
    }

    @Test func eflagsDecoding() {
        // 0x0246 = PF(0x04) + ZF(0x40) + IF(0x200)
        let data = makeContextData(eflags: 0x0246)
        let ctx = ThreadContext(from: data, at: 0)!
        let flags = ctx.eflagsDescription
        #expect(flags.contains("PF"))
        #expect(flags.contains("ZF"))
        #expect(flags.contains("IF"))
        #expect(!flags.contains("CF"))
        #expect(!flags.contains("OF"))
    }

    @Test func eflagsAllFlags() {
        let allFlags: UInt32 = 0x0001 | 0x0004 | 0x0010 | 0x0040 | 0x0080 | 0x0100 | 0x0200 | 0x0400 | 0x0800
        let data = makeContextData(eflags: allFlags)
        let ctx = ThreadContext(from: data, at: 0)!
        let flags = ctx.eflagsDescription
        #expect(flags.count == 9)
        #expect(flags.contains("CF"))
        #expect(flags.contains("PF"))
        #expect(flags.contains("AF"))
        #expect(flags.contains("ZF"))
        #expect(flags.contains("SF"))
        #expect(flags.contains("TF"))
        #expect(flags.contains("IF"))
        #expect(flags.contains("DF"))
        #expect(flags.contains("OF"))
    }

    @Test func generalRegistersArray() {
        let data = makeContextData(rax: 0xAA, rbx: 0xBB)
        let ctx = ThreadContext(from: data, at: 0)!
        let regs = ctx.generalRegisters
        #expect(regs.count == 17)  // RAX through R15 + RIP
        #expect(regs[0].name == "RAX")
        #expect(regs[0].value == 0xAA)
        #expect(regs[1].name == "RBX")
        #expect(regs[1].value == 0xBB)
    }

    @Test func debugRegistersArray() {
        let data = makeContextData()
        let ctx = ThreadContext(from: data, at: 0)!
        let debugRegs = ctx.debugRegisters
        #expect(debugRegs.count == 6)
        #expect(debugRegs[0].name == "DR0")
    }

    @Test func xmmRegistersWithFloatSave() {
        var data = makeContextData(contextFlags: 0x0010000F | 0x8)  // Add CONTEXT_FLOATING_POINT
        // XMM base = offset + 256 + 160 = 416
        data.writeUInt64(0x1111111111111111, at: 416)      // XMM0 low
        data.writeUInt64(0x2222222222222222, at: 416 + 8)  // XMM0 high

        let ctx = ThreadContext(from: data, at: 0)!
        #expect(ctx.floatSaveValid == true)
        #expect(ctx.xmm0 != nil)
        #expect(ctx.xmm0?.low == 0x1111111111111111)
        #expect(ctx.xmm0?.high == 0x2222222222222222)
    }

    @Test func xmmRegistersWithoutFloatSave() {
        let data = makeContextData(contextFlags: 0x01000000)  // No CONTEXT_FLOATING_POINT
        let ctx = ThreadContext(from: data, at: 0)!
        #expect(ctx.floatSaveValid == false)
        #expect(ctx.xmm0 == nil)
        #expect(ctx.xmmRegisters.isEmpty)
    }

    @Test func xmmHexString() {
        let reg = XMMRegister(low: 0x0000000000000001, high: 0x0000000000000002)
        #expect(reg.hexString == "00000000000000020000000000000001")
    }

    @Test func failsOnTruncatedData() {
        let data = Data(repeating: 0, count: 100)
        #expect(ThreadContext(from: data, at: 0) == nil)
    }

    @Test func structSize() {
        #expect(ThreadContext.size == 1232)
    }
}

// MARK: - MemoryProtection Tests

@Suite("MemoryProtection")
struct MemoryProtectionTests {
    @Test func shortDescriptions() {
        #expect(MemoryProtection.readWrite.shortDescription == "RW")
        #expect(MemoryProtection.readonly.shortDescription == "R")
        #expect(MemoryProtection.execute.shortDescription == "X")
        #expect(MemoryProtection.executeRead.shortDescription == "RX")
        #expect(MemoryProtection.executeReadWrite.shortDescription == "RWX")
        #expect(MemoryProtection.noAccess.shortDescription == "-")
        #expect(MemoryProtection.writeCopy.shortDescription == "WC")
        #expect(MemoryProtection.executeWriteCopy.shortDescription == "XWC")
    }

    @Test func combinedFlags() {
        let prot = MemoryProtection([.readWrite, .guard_])
        #expect(prot.shortDescription == "RW+G")
    }

    @Test func emptyProtection() {
        let prot = MemoryProtection(rawValue: 0)
        #expect(prot.shortDescription == "?")
    }

    @Test func noCacheFlag() {
        let prot = MemoryProtection([.readonly, .noCache])
        #expect(prot.shortDescription == "R+NC")
    }
}

// MARK: - MemoryRegion Tests

@Suite("MemoryRegion")
struct MemoryRegionTests {
    @Test func containsAddress() {
        let region = MemoryRegion(baseAddress: 0x1000, regionSize: 0x2000, dataRva: 100)
        #expect(region.contains(address: 0x1000))
        #expect(region.contains(address: 0x2FFF))
        #expect(!region.contains(address: 0x0FFF))
        #expect(!region.contains(address: 0x3000))
    }

    @Test func endAddressNormal() {
        let region = MemoryRegion(baseAddress: 0x1000, regionSize: 0x2000, dataRva: nil)
        #expect(region.endAddress == 0x3000)
    }

    @Test func endAddressOverflow() {
        let region = MemoryRegion(baseAddress: UInt64.max - 10, regionSize: 100, dataRva: nil)
        #expect(region.endAddress == UInt64.max)
    }
}

// MARK: - MemoryState and MemoryType Tests

@Suite("MemoryState")
struct MemoryStateTests {
    @Test func displayNames() {
        #expect(MemoryState.commit.displayName == "Commit")
        #expect(MemoryState.reserve.displayName == "Reserve")
        #expect(MemoryState.free.displayName == "Free")
    }
}

@Suite("MemoryType")
struct MemoryTypeTests {
    @Test func displayNames() {
        #expect(MemoryType.image.displayName == "Image")
        #expect(MemoryType.mapped.displayName == "Mapped")
        #expect(MemoryType.private.displayName == "Private")
    }
}

// MARK: - MemoryInfo Tests

@Suite("MemoryInfo")
struct MemoryInfoTests {
    @Test func parsesValidEntry() {
        var data = Data(repeating: 0, count: 48)
        data.writeUInt64(0x7FF800000000, at: 0)  // baseAddress
        data.writeUInt64(0x7FF800000000, at: 8)  // allocationBase
        data.writeUInt32(0x04, at: 16)            // allocationProtect = RW
        // 4 bytes padding
        data.writeUInt64(0x10000, at: 24)         // regionSize
        data.writeUInt32(0x1000, at: 32)          // state = commit
        data.writeUInt32(0x20, at: 36)            // protect = executeRead
        data.writeUInt32(0x1000000, at: 40)       // type = image

        let info = MemoryInfo(from: data, at: 0)
        #expect(info != nil)
        #expect(info?.baseAddress == 0x7FF800000000)
        #expect(info?.regionSize == 0x10000)
        #expect(info?.state == .commit)
        #expect(info?.type == .image)
        #expect(info?.protect.shortDescription == "RX")
    }

    @Test func endAddress() {
        var data = Data(repeating: 0, count: 48)
        data.writeUInt64(0x1000, at: 0)
        data.writeUInt64(0, at: 8)
        data.writeUInt32(0, at: 16)
        data.writeUInt64(0x2000, at: 24)
        data.writeUInt32(0x1000, at: 32)
        data.writeUInt32(0, at: 36)
        data.writeUInt32(0x20000, at: 40)

        let info = MemoryInfo(from: data, at: 0)!
        #expect(info.endAddress == 0x3000)
    }
}

// MARK: - MiscInfo Tests

@Suite("MiscInfo")
struct MiscInfoTests {
    private func makeMiscInfoV1(
        processId: UInt32 = 1234,
        createTime: UInt32 = 1700000000,
        userTime: UInt32 = 300,
        kernelTime: UInt32 = 60
    ) -> Data {
        var data = Data(repeating: 0, count: 24)
        data.writeUInt32(24, at: 0)     // sizeOfInfo
        data.writeUInt32(0x03, at: 4)   // flags: processId + processTimes
        data.writeUInt32(processId, at: 8)
        data.writeUInt32(createTime, at: 12)
        data.writeUInt32(userTime, at: 16)
        data.writeUInt32(kernelTime, at: 20)
        return data
    }

    @Test func parsesV1Fields() {
        let data = makeMiscInfoV1()
        let info = MiscInfo(from: data, at: 0)
        #expect(info != nil)
        #expect(info?.processId == 1234)
        #expect(info?.processUserTime == 300)
        #expect(info?.processKernelTime == 60)
    }

    @Test func processUptime() {
        let data = makeMiscInfoV1(userTime: 3661, kernelTime: 100)
        let info = MiscInfo(from: data, at: 0)!
        // Total = 3761 seconds = 1:02:41
        #expect(info.processUptime == "1:02:41")
    }

    @Test func processUptimeMinutesOnly() {
        let data = makeMiscInfoV1(userTime: 120, kernelTime: 30)
        let info = MiscInfo(from: data, at: 0)!
        // Total = 150 seconds = 2:30
        #expect(info.processUptime == "2:30")
    }

    @Test func formattedCreateTime() {
        let data = makeMiscInfoV1(createTime: 1700000000)
        let info = MiscInfo(from: data, at: 0)!
        #expect(info.formattedCreateTime != nil)
    }

    @Test func integrityLevelDescriptions() {
        func makeWithIntegrity(_ level: UInt32) -> MiscInfo {
            var data = Data(repeating: 0, count: 232)
            data.writeUInt32(232, at: 0)
            data.writeUInt32(0x10, at: 4) // processIntegrity flag
            data.writeUInt32(level, at: 44)
            return MiscInfo(from: data, at: 0)!
        }
        #expect(makeWithIntegrity(0x0000).integrityLevelDescription == "Untrusted")
        #expect(makeWithIntegrity(0x1000).integrityLevelDescription == "Low")
        #expect(makeWithIntegrity(0x2000).integrityLevelDescription == "Medium")
        #expect(makeWithIntegrity(0x2100).integrityLevelDescription == "Medium Plus")
        #expect(makeWithIntegrity(0x3000).integrityLevelDescription == "High")
        #expect(makeWithIntegrity(0x4000).integrityLevelDescription == "System")
        #expect(makeWithIntegrity(0x5000).integrityLevelDescription == "Protected Process")
        #expect(makeWithIntegrity(0x9999).integrityLevelDescription == "Level 39321")
    }

    @Test func noIntegrityWithoutFlag() {
        var data = Data(repeating: 0, count: 232)
        data.writeUInt32(232, at: 0)
        data.writeUInt32(0x01, at: 4) // processId only, no integrity
        let info = MiscInfo(from: data, at: 0)!
        #expect(info.integrityLevelDescription == nil)
    }

    @Test func processorFrequency() {
        var data = Data(repeating: 0, count: 44)
        data.writeUInt32(44, at: 0)
        data.writeUInt32(0x04, at: 4) // processorPower
        data.writeUInt32(3600, at: 24) // maxMhz
        data.writeUInt32(2400, at: 28) // currentMhz
        let info = MiscInfo(from: data, at: 0)!
        #expect(info.processorFrequency == "2400 MHz (max: 3600 MHz)")
    }

    @Test func rejectsTooSmallSize() {
        var data = Data(repeating: 0, count: 24)
        data.writeUInt32(12, at: 0)  // sizeOfInfo too small (min is 24)
        #expect(MiscInfo(from: data, at: 0) == nil)
    }

    @Test func rejectsOutOfBounds() {
        var data = Data(repeating: 0, count: 30)
        data.writeUInt32(100, at: 0)  // claims 100 bytes but only 30 available
        #expect(MiscInfo(from: data, at: 0) == nil)
    }

    @Test func minSize() {
        #expect(MiscInfo.minSize == 24)
    }
}

// MARK: - HandleEntry Tests

@Suite("HandleEntry")
struct HandleEntryTests {
    private func makeHandleEntryData(
        handle: UInt64 = 0x100,
        grantedAccess: UInt32 = 0x001F0003,
        v2: Bool = false
    ) -> Data {
        let size = v2 ? HandleEntry.sizeV2 : HandleEntry.sizeV1
        var data = Data(repeating: 0, count: size)
        data.writeUInt64(handle, at: 0)
        data.writeUInt32(0, at: 8)  // typeNameRva
        data.writeUInt32(0, at: 12) // objectNameRva
        data.writeUInt32(0, at: 16) // attributes
        data.writeUInt32(grantedAccess, at: 20)
        data.writeUInt32(1, at: 24) // handleCount
        data.writeUInt32(1, at: 28) // pointerCount
        if v2 {
            data.writeUInt32(0, at: 32) // objectInfoRva
        }
        return data
    }

    @Test func parsesV1Entry() {
        let data = makeHandleEntryData(handle: 0x200)
        let entry = HandleEntry(from: data, at: 0, descriptorSize: HandleEntry.sizeV1)
        #expect(entry != nil)
        #expect(entry?.handle == 0x200)
        #expect(entry?.objectInfoRva == nil)
    }

    @Test func parsesV2Entry() {
        let data = makeHandleEntryData(v2: true)
        let entry = HandleEntry(from: data, at: 0, descriptorSize: HandleEntry.sizeV2)
        #expect(entry != nil)
        #expect(entry?.objectInfoRva != nil)
    }

    @Test func handleHex() {
        let data = makeHandleEntryData(handle: 0x1FC)
        let entry = HandleEntry(from: data, at: 0, descriptorSize: HandleEntry.sizeV1)!
        #expect(entry.handleHex == "0x1FC")
    }

    @Test func accessHex() {
        let data = makeHandleEntryData(grantedAccess: 0x001F0003)
        let entry = HandleEntry(from: data, at: 0, descriptorSize: HandleEntry.sizeV1)!
        #expect(entry.accessHex == "0x001F0003")
    }

    @Test func sizes() {
        #expect(HandleEntry.sizeV1 == 32)
        #expect(HandleEntry.sizeV2 == 40)
    }
}

// MARK: - HandleDataList Tests

@Suite("HandleDataList")
struct HandleDataListTests {
    @Test func parsesEmptyList() {
        var data = Data(repeating: 0, count: 16)
        data.writeUInt32(16, at: 0) // sizeOfHeader
        data.writeUInt32(32, at: 4) // sizeOfDescriptor (v1)
        data.writeUInt32(0, at: 8)  // numberOfDescriptors
        data.writeUInt32(0, at: 12) // reserved

        let list = HandleDataList(from: data, at: 0)
        #expect(list != nil)
        #expect(list?.entries.isEmpty == true)
    }

    @Test func isVersion2() {
        var data = Data(repeating: 0, count: 16)
        data.writeUInt32(16, at: 0)
        data.writeUInt32(40, at: 4) // v2 size
        data.writeUInt32(0, at: 8)

        let list = HandleDataList(from: data, at: 0)!
        #expect(list.isVersion2 == true)
    }

    @Test func rejectsExceedingMax() {
        var data = Data(repeating: 0, count: 16)
        data.writeUInt32(16, at: 0)
        data.writeUInt32(32, at: 4)
        data.writeUInt32(HandleDataList.maxEntries + 1, at: 8)

        #expect(HandleDataList(from: data, at: 0) == nil)
    }

    @Test func handleTypesSummary() {
        var data = Data(repeating: 0, count: 16 + 32 * 2 + 100)
        data.writeUInt32(16, at: 0)
        data.writeUInt32(32, at: 4)
        data.writeUInt32(2, at: 8)

        // Entry 1
        let e1 = 16
        data.writeUInt64(1, at: e1)
        let typeRva1 = UInt32(16 + 64)
        data.writeUInt32(typeRva1, at: e1 + 8)
        data.writeUInt32(0, at: e1 + 12)
        data.writeUInt32(0, at: e1 + 16)
        data.writeUInt32(0, at: e1 + 20)
        data.writeUInt32(0, at: e1 + 24)
        data.writeUInt32(0, at: e1 + 28)

        // Entry 2
        let e2 = 16 + 32
        data.writeUInt64(2, at: e2)
        data.writeUInt32(typeRva1, at: e2 + 8) // Same type
        data.writeUInt32(0, at: e2 + 12)
        data.writeUInt32(0, at: e2 + 16)
        data.writeUInt32(0, at: e2 + 20)
        data.writeUInt32(0, at: e2 + 24)
        data.writeUInt32(0, at: e2 + 28)

        // Write type name at typeRva1
        let typeName = "Event"
        let utf16 = Array(typeName.utf16)
        data.writeUInt32(UInt32(utf16.count * 2), at: Int(typeRva1))
        for (i, u) in utf16.enumerated() {
            data.writeUInt16(u, at: Int(typeRva1) + 4 + i * 2)
        }

        let list = HandleDataList(from: data, at: 0)!
        #expect(list.entries.count == 2)
        let summary = list.handleTypesSummary
        #expect(summary.count == 1)
        #expect(summary[0].type == "Event")
        #expect(summary[0].count == 2)
    }
}

// MARK: - UnloadedModule Tests

@Suite("UnloadedModule")
struct UnloadedModuleTests {
    private func makeUnloadedModuleData(
        baseAddress: UInt64 = 0x7FF800000000,
        sizeOfImage: UInt32 = 0x50000,
        moduleNameRva: UInt32 = 0
    ) -> Data {
        var data = Data(repeating: 0, count: UnloadedModule.size)
        data.writeUInt64(baseAddress, at: 0)
        data.writeUInt32(sizeOfImage, at: 8)
        data.writeUInt32(0, at: 12) // checksum
        data.writeUInt32(1700000000, at: 16) // timestamp
        data.writeUInt32(moduleNameRva, at: 20)
        return data
    }

    @Test func parsesValidModule() {
        let data = makeUnloadedModuleData()
        let module = UnloadedModule(from: data, at: 0)
        #expect(module != nil)
        #expect(module?.baseAddress == 0x7FF800000000)
        #expect(module?.sizeOfImage == 0x50000)
    }

    @Test func containsAddress() {
        let data = makeUnloadedModuleData(baseAddress: 0x1000, sizeOfImage: 0x2000)
        let module = UnloadedModule(from: data, at: 0)!
        #expect(module.contains(address: 0x1000))
        #expect(module.contains(address: 0x2FFF))
        #expect(!module.contains(address: 0x3000))
    }

    @Test func endAddressOverflow() {
        let data = makeUnloadedModuleData(baseAddress: UInt64.max - 5, sizeOfImage: 100)
        let module = UnloadedModule(from: data, at: 0)!
        #expect(module.endAddress == UInt64.max)
    }

    @Test func shortNameFromPath() {
        let data = makeUnloadedModuleData()
        var module = UnloadedModule(from: data, at: 0)!
        module.setName("C:\\Windows\\System32\\old.dll")
        #expect(module.shortName == "old.dll")
    }

    @Test func shortNameNoPath() {
        let data = makeUnloadedModuleData()
        var module = UnloadedModule(from: data, at: 0)!
        module.setName("simple.dll")
        #expect(module.shortName == "simple.dll")
    }

    @Test func timestamp() {
        let data = makeUnloadedModuleData()
        let module = UnloadedModule(from: data, at: 0)!
        #expect(module.timestamp.timeIntervalSince1970 == 1700000000)
    }

    @Test func structSize() {
        #expect(UnloadedModule.size == 24)
    }
}

// MARK: - UnloadedModuleList Tests

@Suite("UnloadedModuleList")
struct UnloadedModuleListTests {
    @Test func wasUnloaded() {
        // Build a list with header(16) + 1 module(24)
        var data = Data(repeating: 0, count: 16 + 24)
        data.writeUInt32(16, at: 0)  // sizeOfHeader
        data.writeUInt32(24, at: 4)  // sizeOfEntry
        data.writeUInt32(1, at: 8)   // numberOfEntries
        // Module at offset 16
        data.writeUInt64(0x5000, at: 16)  // baseAddress
        data.writeUInt32(0x1000, at: 24)  // sizeOfImage
        data.writeUInt32(0, at: 28)       // checksum
        data.writeUInt32(0, at: 32)       // timestamp
        data.writeUInt32(0, at: 36)       // moduleNameRva

        let list = UnloadedModuleList(from: data, at: 0)
        #expect(list != nil)
        #expect(list?.wasUnloaded(address: 0x5500) == true)
        #expect(list?.wasUnloaded(address: 0x1000) == false)
    }

    @Test func rejectsExceedingMax() {
        var data = Data(repeating: 0, count: 16)
        data.writeUInt32(16, at: 0)
        data.writeUInt32(24, at: 4)
        data.writeUInt32(UnloadedModuleList.maxModules + 1, at: 8)
        #expect(UnloadedModuleList(from: data, at: 0) == nil)
    }

    @Test func rejectsZeroEntrySize() {
        var data = Data(repeating: 0, count: 16)
        data.writeUInt32(16, at: 0)
        data.writeUInt32(0, at: 4)  // zero entry size
        data.writeUInt32(1, at: 8)
        #expect(UnloadedModuleList(from: data, at: 0) == nil)
    }

    @Test func rejectsTooSmallEntrySize() {
        var data = Data(repeating: 0, count: 16)
        data.writeUInt32(16, at: 0)
        data.writeUInt32(10, at: 4)  // too small (min is 24)
        data.writeUInt32(1, at: 8)
        #expect(UnloadedModuleList(from: data, at: 0) == nil)
    }
}

// MARK: - ThreadNameEntry Tests

@Suite("ThreadNameEntry")
struct ThreadNameEntryTests {
    @Test func parsesValidEntry() {
        var data = Data(repeating: 0, count: 12)
        data.writeUInt32(42, at: 0)
        data.writeUInt64(200, at: 4)

        let entry = ThreadNameEntry(from: data, at: 0)
        #expect(entry != nil)
        #expect(entry?.threadId == 42)
        #expect(entry?.threadNameRva == 200)
    }

    @Test func failsOnTruncatedData() {
        let data = Data(repeating: 0, count: 8)
        #expect(ThreadNameEntry(from: data, at: 0) == nil)
    }

    @Test func structSize() {
        #expect(ThreadNameEntry.size == 12)
    }
}

// MARK: - ThreadNameList Tests

@Suite("ThreadNameList")
struct ThreadNameListTests {
    @Test func lookupByThreadId() {
        // Header: count(4) + entry(12) + name string
        var data = Data(repeating: 0, count: 4 + 12 + 20)
        data.writeUInt32(1, at: 0) // count
        // Entry at offset 4
        data.writeUInt32(55, at: 4)  // threadId
        let nameRva = UInt32(4 + 12)
        data.writeUInt64(UInt64(nameRva), at: 8) // threadNameRva
        // Write name
        let name = "Main"
        let utf16 = Array(name.utf16)
        data.writeUInt32(UInt32(utf16.count * 2), at: Int(nameRva))
        for (i, u) in utf16.enumerated() {
            data.writeUInt16(u, at: Int(nameRva) + 4 + i * 2)
        }

        let list = ThreadNameList(from: data, at: 0)
        #expect(list != nil)
        #expect(list?.name(for: 55) == "Main")
        #expect(list?.hasName(for: 55) == true)
        #expect(list?.name(for: 99) == nil)
        #expect(list?.hasName(for: 99) == false)
    }

    @Test func rejectsExceedingMax() {
        var data = Data(repeating: 0, count: 4)
        data.writeUInt32(ThreadNameList.maxEntries + 1, at: 0)
        #expect(ThreadNameList(from: data, at: 0) == nil)
    }
}

// MARK: - MinidumpType Flags Tests

@Suite("MinidumpType Flags")
struct MinidumpTypeFlagsTests {
    @Test func allFlagDescriptions() {
        let flags: UInt64 = 0x00FFFFFF  // All flags set
        let descs = MinidumpType.descriptions(for: flags)
        #expect(descs.contains("WithDataSegs"))
        #expect(descs.contains("WithFullMemory"))
        #expect(descs.contains("WithHandleData"))
        #expect(descs.contains("FilterMemory"))
        #expect(descs.contains("ScanMemory"))
        #expect(descs.contains("WithUnloadedModules"))
        #expect(descs.contains("WithThreadInfo"))
    }

    @Test func singleFlag() {
        let descs = MinidumpType.descriptions(for: 0x00000002)
        #expect(descs == ["WithFullMemory"])
    }
}

// MARK: - CodeViewRecord Tests

@Suite("CodeViewRecord")
struct CodeViewRecordTests {
    @Test func parsesPDB70() {
        // RSDS format: sig(4) + GUID(16) + age(4) + name(variable)
        let name = "test.pdb"
        let nameBytes = Array(name.utf8) + [0]  // null-terminated
        let totalSize = 24 + nameBytes.count
        var data = Data(repeating: 0, count: totalSize)
        data.writeUInt32(0x53445352, at: 0) // "RSDS"
        // GUID bytes (simplified)
        data.writeUInt32(0x01020304, at: 4)
        data.writeUInt16(0x0506, at: 8)
        data.writeUInt16(0x0708, at: 10)
        for i in 0..<8 {
            data[12 + i] = UInt8(i + 9)
        }
        data.writeUInt32(1, at: 20)  // age
        // PDB name
        for (i, b) in nameBytes.enumerated() {
            data[24 + i] = b
        }

        let record = CodeViewRecord(from: data, at: 0, size: totalSize)
        #expect(record != nil)
        #expect(record?.pdbName == "test.pdb")
        #expect(record?.age == 1)
        #expect(record?.pdbGuid != nil)
    }

    @Test func pdbShortName() {
        let totalSize = 60
        var data = Data(repeating: 0, count: totalSize)
        data.writeUInt32(0x53445352, at: 0)
        data.writeUInt32(0, at: 4)
        data.writeUInt16(0, at: 8)
        data.writeUInt16(0, at: 10)
        for i in 0..<8 { data[12 + i] = 0 }
        data.writeUInt32(1, at: 20)
        let path = "C:\\build\\test.pdb"
        let pathBytes = Array(path.utf8) + [0]
        for (i, b) in pathBytes.enumerated() {
            data[24 + i] = b
        }

        let record = CodeViewRecord(from: data, at: 0, size: totalSize)!
        #expect(record.pdbShortName == "test.pdb")
    }

    @Test func rejectsUnknownSignature() {
        var data = Data(repeating: 0, count: 30)
        data.writeUInt32(0xDEADBEEF, at: 0)
        #expect(CodeViewRecord(from: data, at: 0, size: 30) == nil)
    }

    @Test func rejectsTooSmallData() {
        let data = Data(repeating: 0, count: 10)
        #expect(CodeViewRecord(from: data, at: 0, size: 10) == nil)
    }

    @Test func signatures() {
        #expect(CodeViewRecord.signaturePDB70 == 0x53445352)
        #expect(CodeViewRecord.signaturePDB20 == 0x3031424E)
    }
}

// MARK: - MiscInfoFlags Tests

@Suite("MiscInfoFlags")
struct MiscInfoFlagsTests {
    @Test func flagValues() {
        #expect(MiscInfoFlags.processId.rawValue == 0x01)
        #expect(MiscInfoFlags.processTimes.rawValue == 0x02)
        #expect(MiscInfoFlags.processorPower.rawValue == 0x04)
        #expect(MiscInfoFlags.processIntegrity.rawValue == 0x10)
        #expect(MiscInfoFlags.timezone.rawValue == 0x40)
        #expect(MiscInfoFlags.buildString.rawValue == 0x100)
    }

    @Test func containsCheck() {
        let flags = MiscInfoFlags(rawValue: 0x03)
        #expect(flags.contains(.processId))
        #expect(flags.contains(.processTimes))
        #expect(!flags.contains(.processorPower))
    }
}

// MARK: - MinidumpMemoryDescriptor Tests

@Suite("MinidumpMemoryDescriptor")
struct MinidumpMemoryDescriptorTests {
    @Test func parsesValid() {
        var data = Data(repeating: 0, count: 16)
        data.writeUInt64(0x7FFE0000, at: 0)
        data.writeUInt32(0x1000, at: 8)
        data.writeUInt32(500, at: 12)

        let desc = MinidumpMemoryDescriptor(from: data, at: 0)
        #expect(desc != nil)
        #expect(desc?.startOfMemoryRange == 0x7FFE0000)
        #expect(desc?.dataSize == 0x1000)
        #expect(desc?.rva == 500)
    }

    @Test func endAddressOverflow() {
        var data = Data(repeating: 0, count: 16)
        data.writeUInt64(UInt64.max - 5, at: 0)
        data.writeUInt32(100, at: 8)
        data.writeUInt32(0, at: 12)

        let desc = MinidumpMemoryDescriptor(from: data, at: 0)!
        #expect(desc.endAddress == UInt64.max)
    }
}

// MARK: - StackFrame Tests

@Suite("StackFrame")
struct StackFrameTests {
    @Test func displayAddressWithModule() {
        // Create a minimal module
        var moduleData = Data(repeating: 0, count: 108)
        moduleData.writeUInt64(0x7FF800000000, at: 0)
        moduleData.writeUInt32(0x100000, at: 8)
        var module = ModuleInfo(from: moduleData, at: 0)!
        module.setName("test.dll")

        let frame = StackFrame(
            address: 0x7FF800001234,
            module: module,
            offsetInModule: 0x1234,
            frameType: .instructionPointer,
            confidence: .high
        )
        #expect(frame.displayAddress == "test.dll+0x1234")
    }

    @Test func displayAddressWithoutModule() {
        let frame = StackFrame(
            address: 0xDEADBEEF,
            module: nil,
            offsetInModule: nil,
            frameType: .returnAddress,
            confidence: .low
        )
        #expect(frame.displayAddress == "0x00000000DEADBEEF")
    }

    @Test func frameTypes() {
        #expect(StackFrame.FrameType.instructionPointer.rawValue == "instructionPointer")
        #expect(StackFrame.FrameType.returnAddress.rawValue == "returnAddress")
        #expect(StackFrame.FrameType.framePointer.rawValue == "framePointer")
    }

    @Test func frameConfidences() {
        #expect(StackFrame.FrameConfidence.high.rawValue == "high")
        #expect(StackFrame.FrameConfidence.medium.rawValue == "medium")
        #expect(StackFrame.FrameConfidence.low.rawValue == "low")
    }
}

// MARK: - BlameResult Tests

@Suite("BlameResult")
struct BlameResultTests {
    @Test func reasonDescriptions() {
        #expect(BlameResult.BlameReason.directCrash.rawValue == "directCrash")
        #expect(BlameResult.BlameReason.firstNonSystemFrame.rawValue == "firstNonSystemFrame")
        #expect(BlameResult.BlameReason.graphicsDriver.rawValue == "graphicsDriver")
        #expect(BlameResult.BlameReason.thirdPartyInCallChain.rawValue == "thirdPartyInCallChain")
    }
}

// MARK: - CrashSummary Tests

@Suite("CrashSummary")
struct CrashSummaryTests {
    @Test func fieldsPopulated() {
        let summary = CrashSummary(
            exceptionType: "ACCESS_VIOLATION",
            exceptionDescription: "Invalid memory access",
            faultingAddress: 0xDEAD,
            faultingModule: nil,
            probableCause: "Null pointer dereference",
            recommendation: "Check code"
        )
        #expect(summary.exceptionType == "ACCESS_VIOLATION")
        #expect(summary.faultingAddress == 0xDEAD)
        #expect(!summary.probableCause.isEmpty)
        #expect(!summary.recommendation.isEmpty)
    }
}

// MARK: - AnalysisConfidence Tests

@Suite("AnalysisConfidence")
struct AnalysisConfidenceTests {
    @Test func displayNames() {
        #expect(AnalysisConfidence.high.displayName == "High")
        #expect(AnalysisConfidence.medium.displayName == "Medium")
        #expect(AnalysisConfidence.low.displayName == "Low")
    }

    @Test func rawValues() {
        #expect(AnalysisConfidence.high.rawValue == "high")
        #expect(AnalysisConfidence.medium.rawValue == "medium")
        #expect(AnalysisConfidence.low.rawValue == "low")
    }
}
