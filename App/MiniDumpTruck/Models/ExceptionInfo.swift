import Foundation

/// Exception information from ExceptionStream
public struct ExceptionInfo {
    public let threadId: UInt32
    public let exceptionCode: UInt32
    public let exceptionFlags: UInt32
    public let exceptionRecord: UInt64  // Pointer to nested exception record
    public let exceptionAddress: UInt64
    public let numberOfParameters: UInt32
    public let exceptionParameters: [UInt64]
    /// Location of the thread context at the time of the exception
    public let contextDataSize: UInt32?
    public let contextRva: UInt32?

    public var exceptionName: String {
        NTStatusCodes.name(for: exceptionCode)
    }

    public var exceptionDescription: String {
        NTStatusCodes.description(for: exceptionCode)
    }

    /// Decode ACCESS_VIOLATION parameters
    public var accessViolationDetails: String? {
        guard exceptionCode == 0xC0000005, exceptionParameters.count >= 2 else { return nil }

        let operation = exceptionParameters[0]
        let address = exceptionParameters[1]

        let operationStr: String
        switch operation {
        case 0: operationStr = "reading from"
        case 1: operationStr = "writing to"
        case 8: operationStr = "executing"
        default: operationStr = "accessing"
        }

        return "The instruction at 0x\(String(format: "%016llX", exceptionAddress)) tried \(operationStr) address 0x\(String(format: "%016llX", address))"
    }

    public init?(from data: Data, at rva: UInt32) {
        let offset = Int(rva)

        // MINIDUMP_EXCEPTION_STREAM: ThreadId(4) + alignment(4) + MINIDUMP_EXCEPTION(152) + MINIDUMP_LOCATION_DESCRIPTOR(8) = 168
        guard offset >= 0, offset + 168 <= data.count else { return nil }

        // ExceptionStream: ThreadId (4) + alignment (4) + ExceptionRecord
        guard let threadId = data.readUInt32(at: offset) else { return nil }
        self.threadId = threadId

        // Skip 4 bytes alignment
        // Exception record starts at offset + 8
        let recordOffset = offset + 8

        guard let exceptionCode = data.readUInt32(at: recordOffset),
              let exceptionFlags = data.readUInt32(at: recordOffset + 4),
              let exceptionRecord = data.readUInt64(at: recordOffset + 8),
              let exceptionAddress = data.readUInt64(at: recordOffset + 16),
              let numberOfParameters = data.readUInt32(at: recordOffset + 24)
        else { return nil }

        self.exceptionCode = exceptionCode
        self.exceptionFlags = exceptionFlags
        self.exceptionRecord = exceptionRecord
        self.exceptionAddress = exceptionAddress
        self.numberOfParameters = min(numberOfParameters, 15)  // Max 15 params

        // Skip 4 bytes alignment after numberOfParameters
        // Read parameters with overflow protection
        var params: [UInt64] = []
        let paramsBase = recordOffset + 32
        for i in 0..<Int(self.numberOfParameters) {
            let (paramOffset, mulOverflow) = i.multipliedReportingOverflow(by: 8)
            guard !mulOverflow else { break }
            let (finalOffset, addOverflow) = paramsBase.addingReportingOverflow(paramOffset)
            guard !addOverflow else { break }
            if let param = data.readUInt64(at: finalOffset) {
                params.append(param)
            }
        }
        self.exceptionParameters = params

        // ThreadContext location descriptor at offset 160 (after ThreadId(4) + alignment(4) + MINIDUMP_EXCEPTION(152))
        let contextLocOffset = offset + 160
        self.contextDataSize = data.readUInt32(at: contextLocOffset)
        self.contextRva = data.readUInt32(at: contextLocOffset + 4)
    }
}
