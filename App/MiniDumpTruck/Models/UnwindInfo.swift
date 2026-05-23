import Foundation

/// One opcode in a PE module's `UNWIND_INFO` record. Each `UNWIND_CODE`
/// encodes a single prologue operation we may need to reverse when
/// walking the stack.
///
/// Wire format (2 bytes per code):
///
///     0   CodeOffset : u8   // byte offset in the prologue
///     1   UnwindOp   : 4    // operation type
///     1   OpInfo     : 4    // operation-specific (register index etc.)
///
/// Each opcode consumes 1, 2, or 3 slots in the code array. The
/// follow-up slots carry frame offsets or register save offsets.
public struct UnwindCode: Sendable {
    public let codeOffset: UInt8
    public let unwindOp: UInt8          // 0..10 valid; >10 reserved
    public let opInfo: UInt8

    public init(codeOffset: UInt8, unwindOp: UInt8, opInfo: UInt8) {
        self.codeOffset = codeOffset
        self.unwindOp = unwindOp
        self.opInfo = opInfo
    }
}

/// x64 unwind operation codes (UNW_OP_* constants from winnt.h).
///
/// Reference: https://learn.microsoft.com/en-us/cpp/build/exception-handling-x64
public enum UnwindOpCode: UInt8 {
    case pushNonvol         = 0   // push register; OpInfo = reg
    case allocLarge         = 1   // large stack allocation; 1 or 2 slots follow
    case allocSmall         = 2   // small alloc; size = 8*(OpInfo+1)
    case setFPReg           = 3   // set frame pointer to RSP+FrameOffset*16
    case saveNonvol         = 4   // save register; 1 slot follows
    case saveNonvolFar      = 5   // save register (far); 2 slots follow
    case epilog             = 6   // v2-only marker; opcode bytes carry epilog info
    case spareCode          = 7   // reserved / unused in current toolchains
    case saveXMM128         = 8   // save XMM; 1 slot follows
    case saveXMM128Far      = 9   // save XMM (far); 2 slots follow
    case pushMachFrame      = 10  // interrupt frame; pushes machframe
}

/// Parsed `UNWIND_INFO` record from a PE module's `.xdata` section.
/// Contains the metadata + opcode sequence the stack walker uses to
/// reverse the prologue.
///
/// Wire format:
///
///     0  Version       : 3    // 1 (occasionally 2 for newer)
///     0  Flags         : 5    // EHANDLER, UHANDLER, CHAININFO
///     1  SizeOfProlog  : u8   // bytes in the function's prologue
///     2  CountOfCodes  : u8   // number of UNWIND_CODE slots
///     3  FrameRegister : 4    // 0 = no frame pointer
///     3  FrameOffset   : 4    // scaled by 16
///     4..(4 + 2*N)    : UNWIND_CODE[N]
///     padding to 4-byte boundary
///     optionally: ExceptionHandler RVA (u32) or chained RUNTIME_FUNCTION (12 bytes)
public struct UnwindInfo: Sendable {

    /// Flags bitfield values.
    public struct Flags: OptionSet, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let exceptionHandler   = Flags(rawValue: 0x1)  // UNW_FLAG_EHANDLER
        public static let terminationHandler = Flags(rawValue: 0x2)  // UNW_FLAG_UHANDLER
        public static let chainInfo          = Flags(rawValue: 0x4)  // UNW_FLAG_CHAININFO
    }

    public let version: UInt8
    public let flags: Flags
    public let sizeOfProlog: UInt8
    public let countOfCodes: UInt8
    public let frameRegister: UInt8        // register index, 0 = none
    public let frameOffset: UInt8          // scale by 16 when used
    public let codes: [UnwindCode]

    /// If `flags.contains(.chainInfo)`, the runtime function that
    /// follows this UNWIND_INFO. We chase the chain to handle frames
    /// described by multiple `UNWIND_INFO` records (common in
    /// epilogs spread across compiler-managed boundaries).
    public let chainedFunction: RuntimeFunction?

    /// DoS cap: real prologues use at most a few dozen codes; an
    /// attacker-claimed 255 would force a 510-byte allocation, but
    /// chained records and exploitable bugs warrant a strict ceiling.
    public static let maxCodes = 255

    public init?(from data: Data, at offset: Int) {
        // Use readUInt8(at:) consistently — direct `data[offset]`
        // subscript traps when `data` is a slice (which is what
        // MemoryReader.read returns: `Data` value-typed but indexed
        // by the original buffer's startIndex). The readUInt8
        // extension correctly accounts for startIndex.
        guard data.count >= offset + 4,
              let versionAndFlags = data.readUInt8(at: offset),
              let sizeOfProlog = data.readUInt8(at: offset + 1),
              let countOfCodes = data.readUInt8(at: offset + 2),
              let frameRegAndOffset = data.readUInt8(at: offset + 3) else {
            return nil
        }
        self.version = versionAndFlags & 0x07
        self.flags = Flags(rawValue: (versionAndFlags >> 3) & 0x1F)
        self.sizeOfProlog = sizeOfProlog
        self.countOfCodes = countOfCodes
        self.frameRegister = frameRegAndOffset & 0x0F
        self.frameOffset = (frameRegAndOffset >> 4) & 0x0F

        guard self.version >= 1 && self.version <= 2 else { return nil }
        guard self.countOfCodes <= Self.maxCodes else { return nil }

        // Parse the opcode array.
        let codeStart = offset + 4
        let codeCount = Int(self.countOfCodes)
        let codeEnd = codeStart + codeCount * 2
        guard codeEnd <= data.count else { return nil }

        var codes: [UnwindCode] = []
        codes.reserveCapacity(codeCount)
        var i = 0
        while i < codeCount {
            let baseOff = codeStart + i * 2
            guard let codeByte = data.readUInt8(at: baseOff),
                  let opByte = data.readUInt8(at: baseOff + 1) else {
                return nil
            }
            codes.append(UnwindCode(
                codeOffset: codeByte,
                unwindOp: opByte & 0x0F,
                opInfo: (opByte >> 4) & 0x0F
            ))
            i += 1
        }
        self.codes = codes

        // After the opcode array, padding aligns to a 4-byte boundary.
        // Then optionally a chained RUNTIME_FUNCTION (when chainInfo
        // flag is set) or an exception handler RVA (when EHANDLER /
        // UHANDLER).
        let afterCodes = codeEnd
        let alignedAfterCodes = (afterCodes + 3) & ~3

        if self.flags.contains(.chainInfo) {
            guard alignedAfterCodes + RuntimeFunction.size <= data.count else { return nil }
            self.chainedFunction = RuntimeFunction(from: data, at: alignedAfterCodes)
        } else {
            self.chainedFunction = nil
        }
    }
}

/// Symbolic names for x64 general-purpose registers as encoded in
/// UNWIND_CODE.OpInfo for register-touching opcodes (pushNonvol,
/// saveNonvol, saveNonvolFar). The encoding is the standard x64
/// register-index ordering.
public enum X64Register: UInt8, Sendable {
    case rax = 0
    case rcx = 1
    case rdx = 2
    case rbx = 3
    case rsp = 4
    case rbp = 5
    case rsi = 6
    case rdi = 7
    case r8  = 8
    case r9  = 9
    case r10 = 10
    case r11 = 11
    case r12 = 12
    case r13 = 13
    case r14 = 14
    case r15 = 15
}
