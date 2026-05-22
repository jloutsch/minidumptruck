import Foundation

/// A single 128-bit NEON / FP register value (V0–V31 on ARM64).
public struct NEONRegister: Sendable, Equatable, Codable {
    public let low: UInt64
    public let high: UInt64

    public init(low: UInt64, high: UInt64) {
        self.low = low
        self.high = high
    }

    /// 32-character hex string (high bits first), matching the ARM64 NEON
    /// `V<n>` display convention used by WinDbg.
    public var hexString: String {
        String(format: "%016llX%016llX", high, low)
    }
}

/// ARM64 (AArch64) CPU context — `CONTEXT_ARM64` from Windows. 912 bytes
/// (`DECLSPEC_ALIGN(16)`).
///
/// Layout (offsets in bytes, sourced from WinNT.h `_CONTEXT` for ARM64
/// and cross-checked against the `minidump-common` Rust crate):
///
/// ```
///  0   ContextFlags    u32
///  4   Cpsr            u32
///  8   X[0..30]        31 × u64       (X29 = Fp, X30 = Lr)
///  256 Sp              u64
///  264 Pc              u64
///  272 V[0..31]        32 × u128      NEON / FP regs
///  784 Fpcr            u32
///  788 Fpsr            u32
///  792 Bcr[0..7]       8 × u32        breakpoint control
///  824 Bvr[0..7]       8 × u64        breakpoint value
///  888 Wcr[0..1]       2 × u32        watchpoint control
///  896 Wvr[0..1]       2 × u64        watchpoint value
///  912 (end)
/// ```
public struct ARM64Context: Sendable, Codable {
    public static let size = 912

    public let contextFlags: UInt32
    /// Current Program Status Register — N/Z/C/V flags + execution state.
    public let cpsr: UInt32

    /// X0…X30, 31 general-purpose 64-bit registers. `xRegs[29]` is the
    /// frame pointer (FP), `xRegs[30]` is the link register (LR /
    /// return address for leaf calls).
    public let xRegs: [UInt64]  // count == 31

    public let sp: UInt64
    public let pc: UInt64

    /// NEON / FP registers V0–V31. Populated only when the saved
    /// context flags indicate the FP state is valid (`CONTEXT_ARM64 | 0x4
    /// = CONTEXT_FLOATING_POINT`). `nil` otherwise so callers can
    /// distinguish "all zeroes" from "not captured".
    public let vRegs: [NEONRegister]?

    public let fpcr: UInt32
    public let fpsr: UInt32

    /// FP saved (CONTEXT_FLOATING_POINT bit set in contextFlags).
    public var floatSaveValid: Bool { (contextFlags & 0x4) != 0 }

    public init?(from data: Data, at offset: Int) {
        guard offset >= 0, offset + Self.size <= data.count else { return nil }

        guard let contextFlags = data.readUInt32(at: offset + 0),
              let cpsr = data.readUInt32(at: offset + 4)
        else { return nil }

        self.contextFlags = contextFlags
        self.cpsr = cpsr

        // X0..X30 at offset 8
        var x: [UInt64] = []
        x.reserveCapacity(31)
        for i in 0..<31 {
            guard let v = data.readUInt64(at: offset + 8 + i * 8) else { return nil }
            x.append(v)
        }
        self.xRegs = x

        guard let sp = data.readUInt64(at: offset + 256),
              let pc = data.readUInt64(at: offset + 264)
        else { return nil }
        self.sp = sp
        self.pc = pc

        // V0..V31 NEON registers at offset 272, 16 bytes each
        if (contextFlags & 0x4) != 0 {
            var v: [NEONRegister] = []
            v.reserveCapacity(32)
            for i in 0..<32 {
                let o = offset + 272 + i * 16
                guard let lo = data.readUInt64(at: o),
                      let hi = data.readUInt64(at: o + 8)
                else { return nil }
                v.append(NEONRegister(low: lo, high: hi))
            }
            self.vRegs = v
        } else {
            self.vRegs = nil
        }

        guard let fpcr = data.readUInt32(at: offset + 784),
              let fpsr = data.readUInt32(at: offset + 788)
        else { return nil }
        self.fpcr = fpcr
        self.fpsr = fpsr
    }

    /// Memberwise init for tests + synthetic dumps. No defaults on the
    /// load-bearing fields — callers must supply realistic values so a
    /// test that exercises stack walking or register display sees data
    /// consistent with what a real dump would carry.
    public init(
        contextFlags: UInt32,
        cpsr: UInt32,
        xRegs: [UInt64],
        sp: UInt64,
        pc: UInt64,
        vRegs: [NEONRegister]? = nil,
        fpcr: UInt32 = 0,
        fpsr: UInt32 = 0
    ) {
        precondition(xRegs.count == 31,
                     "ARM64Context.xRegs must contain exactly 31 entries (X0–X30); got \(xRegs.count)")
        if let vRegs {
            precondition(vRegs.count == 32,
                         "ARM64Context.vRegs must contain 32 NEON registers when present; got \(vRegs.count)")
        }
        self.contextFlags = contextFlags
        self.cpsr = cpsr
        self.xRegs = xRegs
        self.sp = sp
        self.pc = pc
        self.vRegs = vRegs
        self.fpcr = fpcr
        self.fpsr = fpsr
    }

    // MARK: - Convenience accessors

    /// Frame pointer == X29 by AAPCS64 calling convention.
    public var fp: UInt64 { xRegs[29] }

    /// Link register == X30. Return address for the *current* leaf
    /// frame; spilled to `[fp, #8]` on non-leaf frames.
    public var lr: UInt64 { xRegs[30] }

    /// All GPRs as name/value pairs in display order. WinDbg prints X0
    /// through X28, then FP/LR/SP/PC; we mirror that.
    public var generalRegisters: [(name: String, value: UInt64)] {
        var rows: [(String, UInt64)] = []
        rows.reserveCapacity(35)
        for i in 0..<29 {
            rows.append(("X\(i)", xRegs[i]))
        }
        rows.append(("FP", fp))       // X29
        rows.append(("LR", lr))       // X30
        rows.append(("SP", sp))
        rows.append(("PC", pc))
        return rows
    }

    /// NEON / FP registers as name/hex pairs. Empty when FP state was
    /// not captured.
    public var neonRegisters: [(name: String, value: String)] {
        guard let vRegs else { return [] }
        return vRegs.enumerated().map { (idx, reg) in ("V\(idx)", reg.hexString) }
    }

    /// Decoded CPSR condition flags (NZCV). Matches the format used in
    /// WinDbg's `r` output: e.g. `[N Z C V]` if all set, `[]` if none.
    public var cpsrFlags: [String] {
        var flags: [String] = []
        if cpsr & 0x8000_0000 != 0 { flags.append("N") }  // Negative
        if cpsr & 0x4000_0000 != 0 { flags.append("Z") }  // Zero
        if cpsr & 0x2000_0000 != 0 { flags.append("C") }  // Carry
        if cpsr & 0x1000_0000 != 0 { flags.append("V") }  // Overflow
        return flags
    }
}
