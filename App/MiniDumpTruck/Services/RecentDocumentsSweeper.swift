import Foundation

/// Abstracts the slice of `NSDocumentController` we need so the sweeper
/// can be unit-tested without touching the AppKit singleton.
public protocol RecentDocumentsHost: AnyObject {
    var recentDocumentURLs: [URL] { get }
    func clearRecentDocuments(_ sender: Any?)
    func noteNewRecentDocumentURL(_ url: URL)
}

/// Remove URLs that point inside the zip-extraction cache from a recent-
/// documents host. AppKit does not expose a "remove one" API, so this
/// clears the list and re-adds survivors via the public API.
///
/// Pure with respect to its inputs: takes the host + a filter predicate
/// and mutates only the host. Returning `true` means the list was
/// rebuilt; `false` means no cache entries were present and the host
/// was untouched.
@discardableResult
public func sweepCacheEntries(
    from host: RecentDocumentsHost,
    isCacheURL: (URL) -> Bool
) -> Bool {
    let urls = host.recentDocumentURLs
    let keep = urls.filter { !isCacheURL($0) }
    guard keep.count != urls.count else { return false }
    host.clearRecentDocuments(nil)
    for url in keep { host.noteNewRecentDocumentURL(url) }
    return true
}
