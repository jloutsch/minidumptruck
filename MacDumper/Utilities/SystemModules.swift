import Foundation

/// Database of known Windows system modules for blame analysis
enum SystemModules {
    /// Core Windows system DLLs (should skip for blame)
    private static let windowsSystemModules: Set<String> = [
        // Core NT
        "ntdll.dll",
        "ntoskrnl.exe",
        "ntkrnlmp.exe",
        "ntkrnlpa.exe",

        // Win32 Core
        "kernel32.dll",
        "kernelbase.dll",
        "user32.dll",
        "gdi32.dll",
        "gdi32full.dll",

        // Runtime
        "msvcrt.dll",
        "ucrtbase.dll",
        "vcruntime140.dll",
        "vcruntime140d.dll",
        "vcruntime140_1.dll",
        "vcruntime140_1d.dll",
        "msvcp140.dll",
        "msvcp140d.dll",
        "msvcp140_1.dll",
        "msvcp140_2.dll",
        "concrt140.dll",

        // COM/OLE
        "ole32.dll",
        "oleaut32.dll",
        "combase.dll",
        "rpcrt4.dll",

        // Security
        "sechost.dll",
        "bcrypt.dll",
        "bcryptprimitives.dll",
        "crypt32.dll",
        "advapi32.dll",
        "cryptbase.dll",

        // Networking
        "ws2_32.dll",
        "winhttp.dll",
        "wininet.dll",
        "urlmon.dll",

        // Shell
        "shell32.dll",
        "shlwapi.dll",
        "shcore.dll",

        // Windows Internals
        "win32u.dll",
        "cfgmgr32.dll",
        "setupapi.dll",
        "wintrust.dll",
        "imagehlp.dll",
        "dbghelp.dll",
        "version.dll",
        "psapi.dll",

        // IMM/Input
        "imm32.dll",
        "msctf.dll",

        // CLR/.NET
        "clr.dll",
        "clrjit.dll",
        "mscorwks.dll",
        "coreclr.dll",
        "mscoreei.dll",

        // DirectX Base
        "d3d11.dll",
        "d3d12.dll",
        "dxgi.dll",
        "d3d9.dll",
        "d3d10.dll",
        "d3d10_1.dll",
        "d2d1.dll",
        "dwrite.dll",
        "dcomp.dll",

        // Media Foundation
        "mf.dll",
        "mfplat.dll",
        "mfreadwrite.dll",

        // Windows Runtime
        "windowscodecs.dll",
        "propsys.dll",
        "profapi.dll",

        // Power/Performance
        "powrprof.dll",
        "ntmarta.dll"
    ]

    /// Known graphics drivers (special blame category)
    private static let graphicsDriverPatterns: Set<String> = [
        // Intel
        "igxelpicd64.dll",
        "igxelpicd32.dll",
        "igxelpgicd64.dll",
        "igxelpgicd32.dll",
        "ig9icd64.dll",
        "ig9icd32.dll",
        "igd10iumd64.dll",
        "igd10iumd32.dll",
        "igd11dxva64.dll",
        "igd12umd64.dll",
        "igdumdim64.dll",
        "igdumdim32.dll",
        "igdusc64.dll",
        "igc64.dll",
        "igc32.dll",
        "intelocl64.dll",
        "igdfcl64.dll",

        // NVIDIA
        "nvoglv64.dll",
        "nvoglv32.dll",
        "nvd3dumx.dll",
        "nvd3dum.dll",
        "nvwgf2umx.dll",
        "nvwgf2um.dll",
        "nvcuda64.dll",
        "nvcuda32.dll",
        "nvcuda.dll",
        "nvapi64.dll",
        "nvapi.dll",
        "nvinit.dll",
        "nvumdshimx.dll",
        "nvldumdx.dll",
        "nvopencl64.dll",
        "nvopencl32.dll",

        // AMD/ATI
        "aticfx64.dll",
        "aticfx32.dll",
        "atidxx64.dll",
        "atidxx32.dll",
        "amdxc64.dll",
        "amdxc32.dll",
        "amdvlk64.dll",
        "amdvlk32.dll",
        "atioglxx.dll",
        "atio6axx.dll",
        "atig6txx.dll",
        "atiumd64.dll",
        "atiumdag.dll",
        "amdocl64.dll",
        "amdocl.dll",

        // Vulkan loaders
        "vulkan-1.dll",
        "amdvlk64.dll"
    ]

    /// Extract the filename from a Windows path
    private static func shortName(from moduleName: String) -> String {
        // Handle both forward and backslash paths
        let name = moduleName.lowercased()
        if let lastBackslash = name.lastIndex(of: "\\") {
            return String(name[name.index(after: lastBackslash)...])
        }
        if let lastSlash = name.lastIndex(of: "/") {
            return String(name[name.index(after: lastSlash)...])
        }
        return name
    }

    /// Check if module is a Windows system module
    static func isSystemModule(_ moduleName: String) -> Bool {
        let short = shortName(from: moduleName)

        // Graphics drivers are never system modules for blame purposes
        if graphicsDriverPatterns.contains(short) {
            return false
        }

        // Check exact matches
        if windowsSystemModules.contains(short) {
            return true
        }

        // Check path patterns
        let lowerPath = moduleName.lowercased()
        if lowerPath.contains("\\windows\\system32\\") ||
           lowerPath.contains("\\windows\\syswow64\\") ||
           lowerPath.contains("\\windows\\winsxs\\") {
            return true
        }

        return false
    }

    /// Check if module is a graphics driver
    static func isGraphicsDriver(_ moduleName: String) -> Bool {
        let short = shortName(from: moduleName)
        return graphicsDriverPatterns.contains(short)
    }

    /// Get module category for analysis
    static func category(for moduleName: String) -> ModuleCategory {
        let short = shortName(from: moduleName)

        // Check graphics drivers first (highest priority)
        if graphicsDriverPatterns.contains(short) {
            return .graphicsDriver
        }

        if windowsSystemModules.contains(short) {
            return .system
        }

        let path = moduleName.lowercased()
        if path.contains("\\windows\\") {
            return .system
        }
        if path.contains("\\program files") || path.contains("\\programdata") {
            return .application
        }

        return .thirdParty
    }

    enum ModuleCategory {
        case system         // Windows OS modules
        case graphicsDriver // GPU drivers
        case application    // Main application modules
        case thirdParty     // Third-party DLLs

        var shouldBlame: Bool {
            switch self {
            case .system: return false
            case .graphicsDriver: return true
            case .application: return true
            case .thirdParty: return true
            }
        }

        var displayName: String {
            switch self {
            case .system: return "System"
            case .graphicsDriver: return "Graphics Driver"
            case .application: return "Application"
            case .thirdParty: return "Third-Party"
            }
        }
    }
}
