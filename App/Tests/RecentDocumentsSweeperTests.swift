import Foundation
import Testing
@testable import MiniDumpTruckCore

/// In-memory `RecentDocumentsHost` so the sweeper can be exercised
/// without touching the real `NSDocumentController.shared` singleton —
/// which would pollute the test runner's prefs plist.
private final class FakeRecentsHost: RecentDocumentsHost {
    private(set) var recentDocumentURLs: [URL] = []
    private(set) var clearCallCount = 0

    func clearRecentDocuments(_ sender: Any?) {
        recentDocumentURLs = []
        clearCallCount += 1
    }

    func noteNewRecentDocumentURL(_ url: URL) {
        recentDocumentURLs.append(url)
    }
}

@Suite("RecentDocumentsSweeper")
struct RecentDocumentsSweeperTests {
    @Test func sweepKeepsAllNonCacheEntries() {
        let host = FakeRecentsHost()
        let cacheURL = URL(fileURLWithPath: "/private/var/cache/extract/a.dmp")
        let outsideA = URL(fileURLWithPath: "/Users/x/Desktop/crash.dmp")
        let outsideB = URL(fileURLWithPath: "/Users/x/Downloads/other.dmp")
        host.noteNewRecentDocumentURL(outsideA)
        host.noteNewRecentDocumentURL(cacheURL)
        host.noteNewRecentDocumentURL(outsideB)

        let rebuilt = sweepCacheEntries(from: host, isCacheURL: { $0 == cacheURL })

        #expect(rebuilt == true)
        #expect(host.recentDocumentURLs == [outsideA, outsideB],
                "non-cache URLs survive in original order; cache URL is dropped")
        #expect(host.clearCallCount == 1)
    }

    @Test func sweepIsNoOpWhenNoCacheEntries() {
        let host = FakeRecentsHost()
        let a = URL(fileURLWithPath: "/Users/x/Desktop/a.dmp")
        let b = URL(fileURLWithPath: "/Users/x/Desktop/b.dmp")
        host.noteNewRecentDocumentURL(a)
        host.noteNewRecentDocumentURL(b)

        let rebuilt = sweepCacheEntries(from: host, isCacheURL: { _ in false })

        #expect(rebuilt == false)
        #expect(host.recentDocumentURLs == [a, b])
        #expect(host.clearCallCount == 0,
                "early-return guard must skip clearRecentDocuments when nothing to remove")
    }

    @Test func sweepHandlesEmptyHost() {
        let host = FakeRecentsHost()
        let rebuilt = sweepCacheEntries(from: host, isCacheURL: { _ in true })
        #expect(rebuilt == false)
        #expect(host.recentDocumentURLs.isEmpty)
        #expect(host.clearCallCount == 0)
    }

    @Test func sweepHandlesAllCacheEntries() {
        let host = FakeRecentsHost()
        host.noteNewRecentDocumentURL(URL(fileURLWithPath: "/cache/a.dmp"))
        host.noteNewRecentDocumentURL(URL(fileURLWithPath: "/cache/b.dmp"))

        let rebuilt = sweepCacheEntries(from: host, isCacheURL: { _ in true })

        #expect(rebuilt == true)
        #expect(host.recentDocumentURLs.isEmpty)
        #expect(host.clearCallCount == 1)
    }
}
