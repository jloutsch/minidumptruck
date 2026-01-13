import Foundation

/// x64 CPU context (CONTEXT_AMD64) - 1232 bytes
/// Reference: https://docs.rs/minidump-common/latest/minidump_common/format/struct.CONTEXT_AMD64.html
struct ThreadContext {
    static let size = 1232
    static let contextFlagsOffset = 48

    // Context flags
    let contextFlags: UInt32

    // Segment registers
    let segCs: UInt16
    let segDs: UInt16
    let segEs: UInt16
    let segFs: UInt16
    let segGs: UInt16
    let segSs: UInt16

    // Flags
    let eflags: UInt32

    // Debug registers
    let dr0: UInt64
    let dr1: UInt64
    let dr2: UInt64
    let dr3: UInt64
    let dr6: UInt64
    let dr7: UInt64

    // General purpose registers
    let rax: UInt64
    let rcx: UInt64
    let rdx: UInt64
    let rbx: UInt64
    let rsp: UInt64
    let rbp: UInt64
    let rsi: UInt64
    let rdi: UInt64
    let r8: UInt64
    let r9: UInt64
    let r10: UInt64
    let r11: UInt64
    let r12: UInt64
    let r13: UInt64
    let r14: UInt64
    let r15: UInt64

    // Instruction pointer
    let rip: UInt64

    // Floating point state stored separately
    let floatSaveValid: Bool

    init?(from data: Data, at offset: Int) {
        guard offset >= 0, offset + Self.size <= data.count else { return nil }

        // Context flags at offset 48 (after P1Home through P6Home at 0-47)
        guard let contextFlags = data.readUInt32(at: offset + 48) else { return nil }
        self.contextFlags = contextFlags

        // MxCsr at offset 52
        // Segment registers at offset 56
        guard let segCs = data.readUInt16(at: offset + 56),
              let segDs = data.readUInt16(at: offset + 58),
              let segEs = data.readUInt16(at: offset + 60),
              let segFs = data.readUInt16(at: offset + 62),
              let segGs = data.readUInt16(at: offset + 64),
              let segSs = data.readUInt16(at: offset + 66)
        else { return nil }

        self.segCs = segCs
        self.segDs = segDs
        self.segEs = segEs
        self.segFs = segFs
        self.segGs = segGs
        self.segSs = segSs

        // EFlags at offset 68
        guard let eflags = data.readUInt32(at: offset + 68) else { return nil }
        self.eflags = eflags

        // Debug registers at offset 72
        guard let dr0 = data.readUInt64(at: offset + 72),
              let dr1 = data.readUInt64(at: offset + 80),
              let dr2 = data.readUInt64(at: offset + 88),
              let dr3 = data.readUInt64(at: offset + 96),
              let dr6 = data.readUInt64(at: offset + 104),
              let dr7 = data.readUInt64(at: offset + 112)
        else { return nil }

        self.dr0 = dr0
        self.dr1 = dr1
        self.dr2 = dr2
        self.dr3 = dr3
        self.dr6 = dr6
        self.dr7 = dr7

        // General purpose registers at offset 120
        guard let rax = data.readUInt64(at: offset + 120),
              let rcx = data.readUInt64(at: offset + 128),
              let rdx = data.readUInt64(at: offset + 136),
              let rbx = data.readUInt64(at: offset + 144),
              let rsp = data.readUInt64(at: offset + 152),
              let rbp = data.readUInt64(at: offset + 160),
              let rsi = data.readUInt64(at: offset + 168),
              let rdi = data.readUInt64(at: offset + 176),
              let r8 = data.readUInt64(at: offset + 184),
              let r9 = data.readUInt64(at: offset + 192),
              let r10 = data.readUInt64(at: offset + 200),
              let r11 = data.readUInt64(at: offset + 208),
              let r12 = data.readUInt64(at: offset + 216),
              let r13 = data.readUInt64(at: offset + 224),
              let r14 = data.readUInt64(at: offset + 232),
              let r15 = data.readUInt64(at: offset + 240)
        else { return nil }

        self.rax = rax
        self.rcx = rcx
        self.rdx = rdx
        self.rbx = rbx
        self.rsp = rsp
        self.rbp = rbp
        self.rsi = rsi
        self.rdi = rdi
        self.r8 = r8
        self.r9 = r9
        self.r10 = r10
        self.r11 = r11
        self.r12 = r12
        self.r13 = r13
        self.r14 = r14
        self.r15 = r15

        // RIP at offset 248
        guard let rip = data.readUInt64(at: offset + 248) else { return nil }
        self.rip = rip

        // Float save area starts at offset 256 (512 bytes for XSAVE)
        self.floatSaveValid = (contextFlags & 0x8) != 0  // CONTEXT_FLOATING_POINT
    }

    /// All general purpose registers as name-value pairs
    var generalRegisters: [(name: String, value: UInt64)] {
        [
            ("RAX", rax), ("RBX", rbx), ("RCX", rcx), ("RDX", rdx),
            ("RSI", rsi), ("RDI", rdi), ("RBP", rbp), ("RSP", rsp),
            ("R8", r8), ("R9", r9), ("R10", r10), ("R11", r11),
            ("R12", r12), ("R13", r13), ("R14", r14), ("R15", r15),
            ("RIP", rip)
        ]
    }

    /// Debug registers as name-value pairs
    var debugRegisters: [(name: String, value: UInt64)] {
        [
            ("DR0", dr0), ("DR1", dr1), ("DR2", dr2), ("DR3", dr3),
            ("DR6", dr6), ("DR7", dr7)
        ]
    }

    /// Segment registers as name-value pairs
    var segmentRegisters: [(name: String, value: UInt16)] {
        [
            ("CS", segCs), ("DS", segDs), ("ES", segEs),
            ("FS", segFs), ("GS", segGs), ("SS", segSs)
        ]
    }

    /// Decode EFLAGS into individual flags
    var eflagsDescription: [String] {
        var flags: [String] = []
        if eflags & 0x0001 != 0 { flags.append("CF") }   // Carry
        if eflags & 0x0004 != 0 { flags.append("PF") }   // Parity
        if eflags & 0x0010 != 0 { flags.append("AF") }   // Auxiliary Carry
        if eflags & 0x0040 != 0 { flags.append("ZF") }   // Zero
        if eflags & 0x0080 != 0 { flags.append("SF") }   // Sign
        if eflags & 0x0100 != 0 { flags.append("TF") }   // Trap
        if eflags & 0x0200 != 0 { flags.append("IF") }   // Interrupt Enable
        if eflags & 0x0400 != 0 { flags.append("DF") }   // Direction
        if eflags & 0x0800 != 0 { flags.append("OF") }   // Overflow
        return flags
    }
}
