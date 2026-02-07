import Foundation

/// x64 CPU context (CONTEXT_AMD64) - 1232 bytes
/// Reference: https://docs.rs/minidump-common/latest/minidump_common/format/struct.CONTEXT_AMD64.html
public struct ThreadContext {
    public static let size = 1232
    public static let contextFlagsOffset = 48

    // Context flags
    public let contextFlags: UInt32

    // Segment registers
    public let segCs: UInt16
    public let segDs: UInt16
    public let segEs: UInt16
    public let segFs: UInt16
    public let segGs: UInt16
    public let segSs: UInt16

    // MxCsr (SSE control/status)
    public let mxCsr: UInt32

    // Flags
    public let eflags: UInt32

    // Debug registers
    public let dr0: UInt64
    public let dr1: UInt64
    public let dr2: UInt64
    public let dr3: UInt64
    public let dr6: UInt64
    public let dr7: UInt64

    // General purpose registers
    public let rax: UInt64
    public let rcx: UInt64
    public let rdx: UInt64
    public let rbx: UInt64
    public let rsp: UInt64
    public let rbp: UInt64
    public let rsi: UInt64
    public let rdi: UInt64
    public let r8: UInt64
    public let r9: UInt64
    public let r10: UInt64
    public let r11: UInt64
    public let r12: UInt64
    public let r13: UInt64
    public let r14: UInt64
    public let r15: UInt64

    // Instruction pointer
    public let rip: UInt64

    // XMM registers (from FXSAVE area at offset 256)
    public let xmm0: (UInt64, UInt64)?
    public let xmm1: (UInt64, UInt64)?
    public let xmm2: (UInt64, UInt64)?
    public let xmm3: (UInt64, UInt64)?
    public let xmm4: (UInt64, UInt64)?
    public let xmm5: (UInt64, UInt64)?
    public let xmm6: (UInt64, UInt64)?
    public let xmm7: (UInt64, UInt64)?
    public let xmm8: (UInt64, UInt64)?
    public let xmm9: (UInt64, UInt64)?
    public let xmm10: (UInt64, UInt64)?
    public let xmm11: (UInt64, UInt64)?
    public let xmm12: (UInt64, UInt64)?
    public let xmm13: (UInt64, UInt64)?
    public let xmm14: (UInt64, UInt64)?
    public let xmm15: (UInt64, UInt64)?

    // Floating point state stored separately
    public let floatSaveValid: Bool

    public init?(from data: Data, at offset: Int) {
        guard offset >= 0, offset + Self.size <= data.count else { return nil }

        // Context flags at offset 48 (after P1Home through P6Home at 0-47)
        guard let contextFlags = data.readUInt32(at: offset + 48) else { return nil }
        self.contextFlags = contextFlags

        // MxCsr at offset 52
        guard let mxCsr = data.readUInt32(at: offset + 52) else { return nil }
        self.mxCsr = mxCsr

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

        // Float save area starts at offset 256 (512 bytes XMM_SAVE_AREA32 / FXSAVE)
        // CONTEXT_FLOATING_POINT = CONTEXT_AMD64 | 0x8 = 0x00100008
        self.floatSaveValid = (contextFlags & 0x8) != 0

        // XMM registers within FXSAVE area: XMM0-XMM15 at offset 256+160 = 416
        // FXSAVE layout: 160 bytes header, then 16 XMM regs at 16 bytes each
        if floatSaveValid {
            let xmmBase = offset + 256 + 160  // offset 416
            func readXmm(_ idx: Int) -> (UInt64, UInt64)? {
                let o = xmmBase + idx * 16
                guard let lo = data.readUInt64(at: o),
                      let hi = data.readUInt64(at: o + 8) else { return nil }
                return (lo, hi)
            }
            self.xmm0 = readXmm(0);   self.xmm1 = readXmm(1)
            self.xmm2 = readXmm(2);   self.xmm3 = readXmm(3)
            self.xmm4 = readXmm(4);   self.xmm5 = readXmm(5)
            self.xmm6 = readXmm(6);   self.xmm7 = readXmm(7)
            self.xmm8 = readXmm(8);   self.xmm9 = readXmm(9)
            self.xmm10 = readXmm(10); self.xmm11 = readXmm(11)
            self.xmm12 = readXmm(12); self.xmm13 = readXmm(13)
            self.xmm14 = readXmm(14); self.xmm15 = readXmm(15)
        } else {
            self.xmm0 = nil;  self.xmm1 = nil;  self.xmm2 = nil;  self.xmm3 = nil
            self.xmm4 = nil;  self.xmm5 = nil;  self.xmm6 = nil;  self.xmm7 = nil
            self.xmm8 = nil;  self.xmm9 = nil;  self.xmm10 = nil; self.xmm11 = nil
            self.xmm12 = nil; self.xmm13 = nil; self.xmm14 = nil; self.xmm15 = nil
        }
    }

    /// All general purpose registers as name-value pairs
    public var generalRegisters: [(name: String, value: UInt64)] {
        [
            ("RAX", rax), ("RBX", rbx), ("RCX", rcx), ("RDX", rdx),
            ("RSI", rsi), ("RDI", rdi), ("RBP", rbp), ("RSP", rsp),
            ("R8", r8), ("R9", r9), ("R10", r10), ("R11", r11),
            ("R12", r12), ("R13", r13), ("R14", r14), ("R15", r15),
            ("RIP", rip)
        ]
    }

    /// Debug registers as name-value pairs
    public var debugRegisters: [(name: String, value: UInt64)] {
        [
            ("DR0", dr0), ("DR1", dr1), ("DR2", dr2), ("DR3", dr3),
            ("DR6", dr6), ("DR7", dr7)
        ]
    }

    /// Segment registers as name-value pairs
    public var segmentRegisters: [(name: String, value: UInt16)] {
        [
            ("CS", segCs), ("DS", segDs), ("ES", segEs),
            ("FS", segFs), ("GS", segGs), ("SS", segSs)
        ]
    }

    /// XMM registers as name-value pairs (formatted as hex string)
    public var xmmRegisters: [(name: String, value: String)] {
        let regs: [(String, (UInt64, UInt64)?)] = [
            ("XMM0", xmm0), ("XMM1", xmm1), ("XMM2", xmm2), ("XMM3", xmm3),
            ("XMM4", xmm4), ("XMM5", xmm5), ("XMM6", xmm6), ("XMM7", xmm7),
            ("XMM8", xmm8), ("XMM9", xmm9), ("XMM10", xmm10), ("XMM11", xmm11),
            ("XMM12", xmm12), ("XMM13", xmm13), ("XMM14", xmm14), ("XMM15", xmm15)
        ]
        return regs.compactMap { name, val in
            guard let (lo, hi) = val else { return nil }
            return (name, String(format: "%016llX%016llX", hi, lo))
        }
    }

    /// Decode EFLAGS into individual flags
    public var eflagsDescription: [String] {
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
