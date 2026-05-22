import Foundation
import Testing
@testable import MiniDumpTruckCore

/// Build a real `MDMP`-prefixed minidump body for tests.
/// Returns the smallest synthetic dump that `MinidumpParser.parse` accepts.
// makeMinimalMinidumpBytes() consolidated in TestHelpers.swift (#10).

private func writeTempFile(name: String, body: Data) throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("\(name)-\(UUID().uuidString)")
    try body.write(to: url)
    return url
}

@Suite("InputPipeline.ingest")
struct InputPipelineIngestTests {
    @Test func directMinidumpFileOpensInPlace() async throws {
        let url = try writeTempFile(name: "direct", body: makeMinimalMinidumpBytes())
        defer { try? FileManager.default.removeItem(at: url) }
        let outcome = await InputPipeline.ingest(url: url)
        switch outcome {
        case .openInPlace(_, let size):
            #expect(size == 32)
        default:
            Issue.record("expected .openInPlace, got \(outcome)")
        }
    }

    @Test func textFileFailsAsNotAMinidump() async throws {
        let url = try writeTempFile(name: "text", body: Data("hello".utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        let outcome = await InputPipeline.ingest(url: url)
        if case .failed(.notAMinidump) = outcome {
            // expected
        } else {
            Issue.record("expected .failed(.notAMinidump), got \(outcome)")
        }
    }

    @Test func zipWithOneDumpOpensInPlace() async throws {
        let dump = makeMinimalMinidumpBytes()
        let zip = SyntheticZipBuilder.build([
            .init(name: "crash.dmp", uncompressed: dump, method: .store)
        ])
        let url = try writeTempFile(name: "one-dump", body: zip)
        defer { try? FileManager.default.removeItem(at: url) }
        let outcome = await InputPipeline.ingest(url: url)
        switch outcome {
        case .openInPlace(_, let size):
            #expect(size == dump.count)
        default:
            Issue.record("expected .openInPlace, got \(outcome)")
        }
    }

    @Test func zipWithThreeDumpsReturnsNeedsPick() async throws {
        let zip = SyntheticZipBuilder.build([
            .init(name: "a.dmp", uncompressed: makeMinimalMinidumpBytes(), method: .store),
            .init(name: "b.dmp", uncompressed: makeMinimalMinidumpBytes(), method: .store),
            .init(name: "c.dmp", uncompressed: makeMinimalMinidumpBytes(), method: .store)
        ])
        let url = try writeTempFile(name: "multi-dump", body: zip)
        defer { try? FileManager.default.removeItem(at: url) }
        let outcome = await InputPipeline.ingest(url: url)
        switch outcome {
        case .needsPick(_, let entries, let name):
            #expect(entries.count == 3)
            #expect(entries.map(\.name) == ["a.dmp", "b.dmp", "c.dmp"])
            #expect(name == url.lastPathComponent)
        default:
            Issue.record("expected .needsPick, got \(outcome)")
        }
    }

    @Test func zipWithZeroDumpsFailsCleanly() async throws {
        let zip = SyntheticZipBuilder.build([
            .init(name: "readme.txt", uncompressed: Data("hello".utf8), method: .store)
        ])
        let url = try writeTempFile(name: "no-dump", body: zip)
        defer { try? FileManager.default.removeItem(at: url) }
        let outcome = await InputPipeline.ingest(url: url)
        if case .failed(.zipNoMinidumps(let zipName)) = outcome {
            #expect(zipName == url.lastPathComponent)
        } else {
            Issue.record("expected .failed(.zipNoMinidumps), got \(outcome)")
        }
    }

    @Test func zipWithOneCorruptDumpFailsAsCorruptedMinidump() async throws {
        // A zip entry named .dmp but whose body isn't a real minidump.
        let zip = SyntheticZipBuilder.build([
            .init(name: "fake.dmp", uncompressed: Data("not a real dump".utf8), method: .store)
        ])
        let url = try writeTempFile(name: "fake-dump", body: zip)
        defer { try? FileManager.default.removeItem(at: url) }
        let outcome = await InputPipeline.ingest(url: url)
        if case .failed(.corruptedMinidump) = outcome {
            // expected
        } else {
            Issue.record("expected .failed(.corruptedMinidump), got \(outcome)")
        }
    }

    @Test func encryptedZipFailsAsZipParseFailed() async throws {
        var zip = SyntheticZipBuilder.build([
            .init(name: "secret.dmp", uncompressed: Data("x".utf8), method: .store)
        ])
        // ZipArchive currently reads the encrypted flag from the CD record,
        // but mirror real encrypted ZIPs by also setting the LFH GP flag,
        // so this test stays accurate if the check ever moves.
        let cdSig: [UInt8] = [0x50, 0x4B, 0x01, 0x02]
        if let r = zip.range(of: Data(cdSig)) { zip[r.lowerBound + 8] = 0x01 }
        let lfhSig: [UInt8] = [0x50, 0x4B, 0x03, 0x04]
        if let r = zip.range(of: Data(lfhSig)) { zip[r.lowerBound + 6] = 0x01 }
        let url = try writeTempFile(name: "encrypted-zip", body: zip)
        defer { try? FileManager.default.removeItem(at: url) }
        let outcome = await InputPipeline.ingest(url: url)
        if case .failed(.zipParseFailed(.encrypted)) = outcome {
            // expected
        } else {
            Issue.record("expected .failed(.zipParseFailed(.encrypted)), got \(outcome)")
        }
    }

    @Test func zipWithOneDumpDeflatedOpensInPlace() async throws {
        let dump = makeMinimalMinidumpBytes()
        let zip = SyntheticZipBuilder.build([
            .init(name: "crash.dmp", uncompressed: dump, method: .deflate)
        ])
        let url = try writeTempFile(name: "one-dump-deflate", body: zip)
        defer { try? FileManager.default.removeItem(at: url) }
        let outcome = await InputPipeline.ingest(url: url)
        switch outcome {
        case .openInPlace(_, let size):
            #expect(size == dump.count)
        default:
            Issue.record("expected .openInPlace, got \(outcome)")
        }
    }
}

@Suite("InputPipeline.extractSelected")
struct InputPipelineExtractTests {
    @Test func extractsSelectedToTempfilesAndReturnsUrls() async throws {
        let dumpA = makeMinimalMinidumpBytes()
        let dumpB = makeMinimalMinidumpBytes()
        let zipBytes = SyntheticZipBuilder.build([
            .init(name: "a.dmp", uncompressed: dumpA, method: .store),
            .init(name: "b.dmp", uncompressed: dumpB, method: .store)
        ])
        let archive = try ZipArchive(data: zipBytes)
        let outcome = await InputPipeline.extractSelected(archive.entries,
                                                          from: archive,
                                                          sourceName: "crashes.zip")
        switch outcome {
        case .openInWindows(let urls):
            #expect(urls.count == 2)
            for url in urls {
                let body = try Data(contentsOf: url)
                #expect(body.prefix(4) == Data([0x4D, 0x44, 0x4D, 0x50]))
            }
            // All files share the same tempdir — remove it once after verifying all.
            if let first = urls.first {
                try? FileManager.default.removeItem(at: first.deletingLastPathComponent())
            }
        default:
            Issue.record("expected .openInWindows, got \(outcome)")
        }
    }

    @Test func extractSelectedWithEmptyEntriesReturnsEmptyWindows() async throws {
        let zipBytes = SyntheticZipBuilder.build([
            .init(name: "a.dmp", uncompressed: makeMinimalMinidumpBytes(), method: .store)
        ])
        let archive = try ZipArchive(data: zipBytes)
        let outcome = await InputPipeline.extractSelected([], from: archive, sourceName: "empty.zip")
        switch outcome {
        case .openInWindows(let urls):
            #expect(urls.isEmpty)
        default:
            Issue.record("expected .openInWindows([]), got \(outcome)")
        }
    }

    @Test func sanitizesEntryFilenamesAgainstPathTraversal() async throws {
        let dump = makeMinimalMinidumpBytes()
        let zipBytes = SyntheticZipBuilder.build([
            .init(name: "../../escape.dmp", uncompressed: dump, method: .store)
        ])
        let archive = try ZipArchive(data: zipBytes)
        let outcome = await InputPipeline.extractSelected(archive.entries,
                                                          from: archive,
                                                          sourceName: "evil.zip")
        switch outcome {
        case .openInWindows(let urls):
            #expect(urls.count == 1)
            // The written file's lastPathComponent must be the sanitized name
            // (no parent-traversal), and the parent directory must be the
            // tempdir we created — not anywhere outside it.
            let url = urls[0]
            #expect(url.lastPathComponent == "escape.dmp")
            #expect(url.deletingLastPathComponent().lastPathComponent.hasPrefix("zip-"))
            #expect(url.path.hasPrefix(TempStore.root().path), "extracted file must be under TempStore root")
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        default:
            Issue.record("expected .openInWindows, got \(outcome)")
        }
    }
}
