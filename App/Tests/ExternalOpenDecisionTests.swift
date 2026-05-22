import Foundation
import Testing
@testable import MiniDumpTruckCore

@Suite("ExternalOpenDecision")
struct ExternalOpenDecisionTests {
    @Test func openInPlaceRoutesToShowDocument() throws {
        let bytes = makeMinimalMinidumpBytes()
        let parsed = try MinidumpParser.parse(data: bytes)
        let action = externalOpenAction(for: .openInPlace(parsedDump: parsed, fileSize: bytes.count))
        if case .showDocument(_, let size) = action {
            #expect(size == bytes.count)
        } else {
            Issue.record("expected .showDocument, got something else")
        }
    }

    @Test func openInWindowsRoutesToDeferToWelcomeView() {
        let urls = [
            URL(fileURLWithPath: "/tmp/a.dmp"),
            URL(fileURLWithPath: "/tmp/b.dmp")
        ]
        let action = externalOpenAction(for: .openInWindows(urls))
        if case .deferToWelcomeView(let outcome) = action {
            if case .openInWindows(let routed) = outcome {
                #expect(routed == urls)
            } else {
                Issue.record("deferred outcome lost original payload")
            }
        } else {
            Issue.record("expected .deferToWelcomeView, got something else")
        }
    }

    @Test func failedRoutesToDeferToWelcomeView() {
        let action = externalOpenAction(for: .failed(.notAMinidump(firstBytes: [0x7F, 0x45, 0x4C, 0x46])))
        if case .deferToWelcomeView = action {} else {
            Issue.record("failed outcome must defer to WelcomeView for alert UI")
        }
    }

    @Test func needsPickRoutesToDeferToWelcomeView() throws {
        let zipBytes = SyntheticZipBuilder.build([
            .init(name: "a.dmp", uncompressed: Data("x".utf8), method: .store),
            .init(name: "b.dmp", uncompressed: Data("y".utf8), method: .store)
        ])
        let archive = try ZipArchive(data: zipBytes)
        let action = externalOpenAction(for: .needsPick(
            archive: archive,
            dumpEntries: archive.entries,
            zipName: "crashes.zip"
        ))
        if case .deferToWelcomeView = action {} else {
            Issue.record("needsPick must defer to WelcomeView for picker sheet")
        }
    }
}
