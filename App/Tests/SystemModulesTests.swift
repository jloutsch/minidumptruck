import Foundation
import Testing
@testable import MiniDumpTruckCore

@Suite("SystemModules Tests")
struct SystemModulesTests {

    // MARK: - System Module Detection

    @Test func kernel32IsSystemModule() {
        #expect(SystemModules.isSystemModule("kernel32.dll") == true)
        #expect(SystemModules.isSystemModule("KERNEL32.DLL") == true)
        #expect(SystemModules.isSystemModule("C:\\Windows\\System32\\kernel32.dll") == true)
    }

    @Test func ntdllIsSystemModule() {
        #expect(SystemModules.isSystemModule("ntdll.dll") == true)
        #expect(SystemModules.isSystemModule("C:\\Windows\\System32\\ntdll.dll") == true)
    }

    @Test func kernelbaseIsSystemModule() {
        #expect(SystemModules.isSystemModule("kernelbase.dll") == true)
    }

    @Test func user32IsSystemModule() {
        #expect(SystemModules.isSystemModule("user32.dll") == true)
    }

    @Test func vcRuntimeIsSystemModule() {
        #expect(SystemModules.isSystemModule("vcruntime140.dll") == true)
        #expect(SystemModules.isSystemModule("vcruntime140d.dll") == true)
        #expect(SystemModules.isSystemModule("msvcp140.dll") == true)
        #expect(SystemModules.isSystemModule("ucrtbase.dll") == true)
    }

    @Test func system32PathIsSystemModule() {
        #expect(SystemModules.isSystemModule("C:\\Windows\\System32\\somemodule.dll") == true)
        #expect(SystemModules.isSystemModule("C:\\Windows\\SysWOW64\\somemodule.dll") == true)
    }

    @Test func winSxSPathIsSystemModule() {
        #expect(SystemModules.isSystemModule("C:\\Windows\\WinSxS\\x86_microsoft.vc90.crt\\msvcr90.dll") == true)
    }

    // MARK: - Graphics Driver Detection

    @Test func intelGraphicsDriver() {
        #expect(SystemModules.isGraphicsDriver("igxelpicd64.dll") == true)
        #expect(SystemModules.isGraphicsDriver("C:\\Windows\\System32\\igxelpicd64.dll") == true)
        #expect(SystemModules.isSystemModule("igxelpicd64.dll") == false)  // Graphics drivers are NOT system modules
    }

    @Test func nvidiaGraphicsDriver() {
        #expect(SystemModules.isGraphicsDriver("nvoglv64.dll") == true)
        #expect(SystemModules.isGraphicsDriver("nvd3dumx.dll") == true)
        #expect(SystemModules.isGraphicsDriver("nvcuda64.dll") == true)
    }

    @Test func amdGraphicsDriver() {
        #expect(SystemModules.isGraphicsDriver("aticfx64.dll") == true)
        #expect(SystemModules.isGraphicsDriver("atidxx64.dll") == true)
        #expect(SystemModules.isGraphicsDriver("amdvlk64.dll") == true)
    }

    @Test func vulkanLoader() {
        #expect(SystemModules.isGraphicsDriver("vulkan-1.dll") == true)
    }

    // MARK: - Non-System Modules

    @Test func applicationModuleNotSystem() {
        #expect(SystemModules.isSystemModule("myapp.exe") == false)
        #expect(SystemModules.isSystemModule("C:\\Program Files\\MyApp\\myapp.exe") == false)
    }

    @Test func thirdPartyDllNotSystem() {
        #expect(SystemModules.isSystemModule("thirdparty.dll") == false)
        #expect(SystemModules.isSystemModule("D:\\Games\\game.dll") == false)
    }

    @Test func graphicsDriverNotSystem() {
        // Graphics drivers should NOT be classified as system modules
        // This is intentional for blame analysis
        #expect(SystemModules.isSystemModule("igxelpicd64.dll") == false)
        #expect(SystemModules.isSystemModule("nvoglv64.dll") == false)
        #expect(SystemModules.isSystemModule("aticfx64.dll") == false)
    }

    // MARK: - Category Tests

    @Test func categorySystem() {
        let category = SystemModules.category(for: "kernel32.dll")
        #expect(category == .system)
        #expect(category.displayName == "System")
        #expect(category.shouldBlame == false)
    }

    @Test func categoryGraphicsDriver() {
        let category = SystemModules.category(for: "igxelpicd64.dll")
        #expect(category == .graphicsDriver)
        #expect(category.displayName == "Graphics Driver")
        #expect(category.shouldBlame == true)
    }

    @Test func categoryApplication() {
        let category = SystemModules.category(for: "C:\\Program Files\\MyApp\\myapp.exe")
        #expect(category == .application)
        #expect(category.displayName == "Application")
        #expect(category.shouldBlame == true)
    }

    @Test func categoryThirdParty() {
        let category = SystemModules.category(for: "unknown.dll")
        #expect(category == .thirdParty)
        #expect(category.displayName == "Third-Party")
        #expect(category.shouldBlame == true)
    }

    @Test func categoryWindowsPath() {
        // Even unknown DLLs in Windows path should be system
        let category = SystemModules.category(for: "C:\\Windows\\unknownsystem.dll")
        #expect(category == .system)
    }

    // MARK: - Path Handling

    @Test func backslashPath() {
        #expect(SystemModules.isSystemModule("C:\\Windows\\System32\\kernel32.dll") == true)
    }

    @Test func forwardSlashPath() {
        #expect(SystemModules.isSystemModule("C:/Windows/System32/kernel32.dll") == true)
    }

    @Test func mixedCasePath() {
        #expect(SystemModules.isSystemModule("C:\\WINDOWS\\SYSTEM32\\KERNEL32.DLL") == true)
        #expect(SystemModules.isSystemModule("c:\\windows\\system32\\kernel32.dll") == true)
    }

    @Test func justFilename() {
        #expect(SystemModules.isSystemModule("ntdll.dll") == true)
        #expect(SystemModules.isGraphicsDriver("nvoglv64.dll") == true)
    }

    // MARK: - Blame Logic

    @Test func systemModuleShouldNotBlame() {
        let category = SystemModules.category(for: "ntdll.dll")
        #expect(category.shouldBlame == false)
    }

    @Test func graphicsDriverShouldBlame() {
        let category = SystemModules.category(for: "igxelpicd64.dll")
        #expect(category.shouldBlame == true)
    }

    @Test func applicationShouldBlame() {
        let category = SystemModules.category(for: "C:\\Program Files\\Game\\game.exe")
        #expect(category.shouldBlame == true)
    }

    @Test func thirdPartyShouldBlame() {
        let category = SystemModules.category(for: "plugin.dll")
        #expect(category.shouldBlame == true)
    }

    // MARK: - Edge Cases

    @Test func emptyString() {
        #expect(SystemModules.isSystemModule("") == false)
        #expect(SystemModules.isGraphicsDriver("") == false)
        #expect(SystemModules.category(for: "") == .thirdParty)
    }

    @Test func dllExtensionVariations() {
        // Our database uses lowercase .dll, so uppercase won't match without the path
        // This tests that the lowercase conversion works
        #expect(SystemModules.isSystemModule("KERNEL32.DLL") == true)
        #expect(SystemModules.isGraphicsDriver("NVOGLV64.DLL") == true)
    }

    @Test func programDataPath() {
        let category = SystemModules.category(for: "C:\\ProgramData\\App\\helper.dll")
        #expect(category == .application)
    }
}
