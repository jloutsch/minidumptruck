import Foundation

/// Processor architecture types
public enum ProcessorArchitecture: UInt16 {
    case intel    = 0
    case mips     = 1
    case alpha    = 2
    case ppc      = 3
    case shx      = 4
    case arm      = 5
    case ia64     = 6
    case alpha64  = 7
    case msil     = 8
    case amd64    = 9
    case ia32OnWin64 = 10
    case neutral  = 11
    case arm64    = 12
    case arm32OnWin64 = 13
    case ia32OnArm64 = 14
    case unknown  = 0xFFFF

    public var displayName: String {
        switch self {
        case .intel: return "x86 (Intel)"
        case .mips: return "MIPS"
        case .alpha: return "Alpha"
        case .ppc: return "PowerPC"
        case .shx: return "SHX"
        case .arm: return "ARM"
        case .ia64: return "IA-64 (Itanium)"
        case .alpha64: return "Alpha64"
        case .msil: return "MSIL"
        case .amd64: return "x64 (AMD64)"
        case .ia32OnWin64: return "x86 on x64"
        case .neutral: return "Neutral"
        case .arm64: return "ARM64"
        case .arm32OnWin64: return "ARM32 on x64"
        case .ia32OnArm64: return "x86 on ARM64"
        case .unknown: return "Unknown"
        }
    }
}

/// Windows product types
public enum ProductType: UInt8 {
    case workstation = 1
    case domainController = 2
    case server = 3

    public var displayName: String {
        switch self {
        case .workstation: return "Workstation"
        case .domainController: return "Domain Controller"
        case .server: return "Server"
        }
    }
}

/// Windows platform IDs
public enum PlatformId: UInt32 {
    case dos = 300
    case os2 = 400
    case win32s = 0
    case win32Windows = 1
    case win32NT = 2
    case unix = 0x8000

    public var displayName: String {
        switch self {
        case .dos: return "DOS"
        case .os2: return "OS/2"
        case .win32s: return "Win32s"
        case .win32Windows: return "Windows 9x"
        case .win32NT: return "Windows NT"
        case .unix: return "Unix"
        }
    }
}

/// CPU information from vendor ID and features
public struct CpuInfo {
    public let vendorId: [UInt32]  // 3 x UInt32 for vendor string
    public let versionInfo: UInt32
    public let featureInfo: UInt32
    public let extendedFeatures: UInt32

    public var vendorString: String {
        var bytes: [UInt8] = []
        for val in vendorId {
            bytes.append(UInt8(val & 0xFF))
            bytes.append(UInt8((val >> 8) & 0xFF))
            bytes.append(UInt8((val >> 16) & 0xFF))
            bytes.append(UInt8((val >> 24) & 0xFF))
        }
        return String(bytes: bytes, encoding: .ascii)?.trimmingCharacters(in: .whitespaces) ?? "Unknown"
    }

    public var stepping: UInt32 { versionInfo & 0xF }
    public var model: UInt32 { (versionInfo >> 4) & 0xF }
    public var family: UInt32 { (versionInfo >> 8) & 0xF }
    public var extendedModel: UInt32 { (versionInfo >> 16) & 0xF }
    public var extendedFamily: UInt32 { (versionInfo >> 20) & 0xFF }

    public var displayModel: UInt32 {
        if family == 6 || family == 15 {
            return model + (extendedModel << 4)
        }
        return model
    }

    public var displayFamily: UInt32 {
        if family == 15 {
            return family + extendedFamily
        }
        return family
    }

    public init(vendorId: [UInt32], versionInfo: UInt32, featureInfo: UInt32, extendedFeatures: UInt32) {
        self.vendorId = vendorId
        self.versionInfo = versionInfo
        self.featureInfo = featureInfo
        self.extendedFeatures = extendedFeatures
    }
}

/// System information from the SystemInfoStream
public struct SystemInfo {
    public let processorArchitecture: ProcessorArchitecture
    public let processorLevel: UInt16
    public let processorRevision: UInt16
    public let numberOfProcessors: UInt8
    public let productType: ProductType
    public let majorVersion: UInt32
    public let minorVersion: UInt32
    public let buildNumber: UInt32
    public let platformId: PlatformId
    public let csdVersionRva: UInt32  // RVA to service pack string
    public let suiteFlags: UInt16
    public let cpuInfo: CpuInfo

    public var csdVersion: String?  // Populated after parsing

    public var osVersionString: String {
        "\(majorVersion).\(minorVersion) Build \(buildNumber)"
    }

    public var windowsVersionName: String {
        // Map major.minor.build to known Windows versions
        switch (majorVersion, minorVersion) {
        case (10, 0) where buildNumber >= 22000:
            return "Windows 11"
        case (10, 0):
            return "Windows 10"
        case (6, 3):
            return "Windows 8.1"
        case (6, 2):
            return "Windows 8"
        case (6, 1):
            return "Windows 7"
        case (6, 0):
            return "Windows Vista"
        case (5, 2):
            return "Windows Server 2003/XP x64"
        case (5, 1):
            return "Windows XP"
        case (5, 0):
            return "Windows 2000"
        default:
            return "Windows \(majorVersion).\(minorVersion)"
        }
    }

    public init?(from data: Data, at rva: UInt32) {
        let offset = Int(rva)
        guard offset >= 0, offset + 56 <= data.count else { return nil }

        guard let archRaw = data.readUInt16(at: offset),
              let processorLevel = data.readUInt16(at: offset + 2),
              let processorRevision = data.readUInt16(at: offset + 4),
              let numberOfProcessors = data.readUInt8(at: offset + 6),
              let productTypeRaw = data.readUInt8(at: offset + 7),
              let majorVersion = data.readUInt32(at: offset + 8),
              let minorVersion = data.readUInt32(at: offset + 12),
              let buildNumber = data.readUInt32(at: offset + 16),
              let platformIdRaw = data.readUInt32(at: offset + 20),
              let csdVersionRva = data.readUInt32(at: offset + 24),
              let suiteFlags = data.readUInt16(at: offset + 28)
        else { return nil }

        self.processorArchitecture = ProcessorArchitecture(rawValue: archRaw) ?? .unknown
        self.processorLevel = processorLevel
        self.processorRevision = processorRevision
        self.numberOfProcessors = numberOfProcessors
        self.productType = ProductType(rawValue: productTypeRaw) ?? .workstation
        self.majorVersion = majorVersion
        self.minorVersion = minorVersion
        self.buildNumber = buildNumber
        self.platformId = PlatformId(rawValue: platformIdRaw) ?? .win32NT
        self.csdVersionRva = csdVersionRva
        self.suiteFlags = suiteFlags

        // Parse CPU info (offset 32)
        guard let v0 = data.readUInt32(at: offset + 32),
              let v1 = data.readUInt32(at: offset + 36),
              let v2 = data.readUInt32(at: offset + 40),
              let versionInfo = data.readUInt32(at: offset + 44),
              let featureInfo = data.readUInt32(at: offset + 48),
              let extendedFeatures = data.readUInt32(at: offset + 52)
        else { return nil }

        self.cpuInfo = CpuInfo(
            vendorId: [v0, v1, v2],
            versionInfo: versionInfo,
            featureInfo: featureInfo,
            extendedFeatures: extendedFeatures
        )

        self.csdVersion = nil  // Will be set by parser if csdVersionRva is valid
    }

    public mutating func setCsdVersion(_ version: String?) {
        self.csdVersion = version
    }
}
