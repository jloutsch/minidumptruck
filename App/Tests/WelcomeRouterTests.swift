import Foundation
import Testing
@testable import MiniDumpTruckCore

/// Build a minimal valid minidump body so the tests can construct a real
/// `ParsedMinidump` for the `.openInPlace` case.
private func makeMinimalMinidumpBytes() -> Data {
    var d = Data(repeating: 0, count: 32)
    func w32(_ v: UInt32, _ o: Int) { for i in 0..<4 { d[o+i] = UInt8((v >> (i*8)) & 0xFF) } }
    func w16(_ v: UInt16, _ o: Int) { d[o] = UInt8(v & 0xFF); d[o+1] = UInt8((v >> 8) & 0xFF) }
    w32(0x504D444D, 0)
    w16(0xA793, 4)
    w32(0, 8)
    w32(32, 12)
    w32(0, 16)
    w32(1700000000, 20)
    return d
}

@Suite("WelcomeRouter")
struct WelcomeRouterTests {
    @Test func openInPlaceRoutesToOpenDocument() throws {
        let bytes = makeMinimalMinidumpBytes()
        let parsed = try MinidumpParser.parse(data: bytes)
        let action = WelcomeRouter.route(.openInPlace(parsedDump: parsed, fileSize: bytes.count))
        if case .openDocument(_, let size) = action {
            #expect(size == bytes.count)
        } else {
            Issue.record("expected .openDocument, got \(action)")
        }
    }

    @Test func openInWindowsRoutesToOpenWindows() {
        let urls = [
            URL(fileURLWithPath: "/tmp/a.dmp"),
            URL(fileURLWithPath: "/tmp/b.dmp")
        ]
        let action = WelcomeRouter.route(.openInWindows(urls))
        if case .openWindows(let routed) = action {
            #expect(routed == urls)
        } else {
            Issue.record("expected .openWindows, got \(action)")
        }
    }

    @Test func needsPickRoutesToShowPicker() throws {
        // Need a real ZipArchive to populate .needsPick. Use the same
        // SyntheticZipBuilder helper that ZipReaderTests defines.
        let zipBytes = SyntheticZipBuilder.build([
            .init(name: "a.dmp", uncompressed: Data("x".utf8), method: .store),
            .init(name: "b.dmp", uncompressed: Data("y".utf8), method: .store)
        ])
        let archive = try ZipArchive(data: zipBytes)
        let action = WelcomeRouter.route(.needsPick(
            archive: archive,
            dumpEntries: archive.entries,
            zipName: "crashes.zip"
        ))
        if case .showPicker(_, let entries, let zipName) = action {
            #expect(entries.count == 2)
            #expect(zipName == "crashes.zip")
        } else {
            Issue.record("expected .showPicker, got \(action)")
        }
    }

    @Test func failedRoutesToShowAlertWithFriendlyMessage() {
        let action = WelcomeRouter.route(.failed(.zipNoMinidumps(zipName: "crashes.zip")))
        if case .showAlert(let title, let message) = action {
            #expect(title == "Cannot Open File")
            #expect(message.contains("crashes.zip"))
            #expect(message.contains(".dmp"))
        } else {
            Issue.record("expected .showAlert, got \(action)")
        }
    }

    @Test func failedWithNotAMinidumpHasFriendlyMessage() {
        let action = WelcomeRouter.route(.failed(.notAMinidump(firstBytes: [0x7F, 0x45, 0x4C, 0x46])))
        if case .showAlert(let title, let message) = action {
            #expect(title == "Cannot Open File")
            #expect(message.contains("does not look like a Windows minidump"))
        } else {
            Issue.record("expected .showAlert, got \(action)")
        }
    }

    @Test func failedWithZipParseFailedSurfacesUnderlyingZipError() {
        let action = WelcomeRouter.route(.failed(.zipParseFailed(.encrypted)))
        if case .showAlert(_, let message) = action {
            #expect(message.contains("encrypted"))
        } else {
            Issue.record("expected .showAlert, got \(action)")
        }
    }
}
