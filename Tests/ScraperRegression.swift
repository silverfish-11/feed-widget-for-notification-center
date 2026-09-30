import Foundation
import AppKit

@main
struct ScraperRegression {
    static func main() {
        let oldDate = Date(timeIntervalSince1970: 1_700_000_000)
        let old = FeedPost(id: "123", platform: "x", author: "A", handle: "a", text: "Saved", timestamp: oldDate, likes: 0, reposts: 0, comments: 0)
        let previous = FeedSourceState(posts: [old], status: "ready", message: "", lastAttempt: oldDate, lastSuccess: oldDate)
        for status in ["error", "loginRequired"] {
            let result = ScraperManager.applyingResult(to: previous, status: status, message: "Retry", posts: nil)
            precondition(result.posts.map(\.id) == ["123"] && result.lastSuccess == oldDate)
            precondition(result.status == status && result.message == "Retry")
        }
        let failedPayload = ScraperManager.applyingResult(to: previous, status: "error", message: "Bad result", posts: [])
        precondition(failedPayload.posts.count == 1)
        let now = oldDate.addingTimeInterval(60)
        let empty = ScraperManager.applyingResult(to: previous, status: "ready", message: "Empty", posts: [], now: now)
        precondition(empty.posts.isEmpty && empty.lastSuccess == now)
        var snapshot = FeedSnapshot(sources: ["x": previous, "ig": previous])
        snapshot.sources["x"] = empty
        precondition(snapshot.sources["ig"]?.posts.count == 1)
        let base: [String: Any] = ["id": "123", "text": "Actual post"]
        var seconds = base
        seconds["timestamp"] = "2026-03-05T10:00:00Z"
        var fractional = base
        fractional["timestamp"] = "2026-03-05T10:00:00.000Z"
        let a = ScraperManager.parsePost(seconds, platform: "x")!
        let b = ScraperManager.parsePost(fractional, platform: "x")!
        precondition(a.timestamp == b.timestamp && a.timestamp > .distantPast)
        precondition(ScraperManager.parsePost(base, platform: "x", previous: old)?.timestamp == oldDate)
        precondition(ScraperManager.parsePost(base, platform: "x")?.timestamp == .distantPast)
        precondition(ScraperManager.parsePost(["id": "x_0", "text": "Placeholder"], platform: "x") == nil)
        precondition(ScraperManager.parsePost(["id": "123", "text": "  "], platform: "x") == nil)
        precondition(ScraperManager.parsePost(["id": "Abc_-9", "text": "[Image post]"], platform: "ig") != nil)
        let remote = "https://pbs.twimg.com/media/example.jpg"
        let attachment = FeedMedia(kind: "image", url: remote, previewURL: remote)
        var saved = attachment
        saved.localPreviewFile = attachment.cacheKey + ".jpg"
        var oldMediaPost = old
        oldMediaPost.media = [saved]
        let mediaOnly: [String: Any] = ["id": "123", "text": "", "media": [["kind": "image", "url": remote, "previewURL": remote]]]
        let parsedMedia = ScraperManager.parsePost(mediaOnly, platform: "x", previous: oldMediaPost)!
        precondition(parsedMedia.media.count == 1 && parsedMedia.media[0].localPreviewFile == saved.localPreviewFile)
        let hydrationMiss: [String: Any] = ["id": "123", "text": "Caption loaded", "media": []]
        let retained = ScraperManager.parsePost(hydrationMiss, platform: "x", previous: parsedMedia)!
        precondition(retained.media == parsedMedia.media && retained.text == "Caption loaded")
        var carousel = oldMediaPost
        carousel.media.append(FeedMedia(kind: "image", url: "https://pbs.twimg.com/media/slide2.jpg"))
        let subset = ScraperManager.parsePost(mediaOnly, platform: "x", previous: carousel)!
        precondition(subset.media.count == 2 && subset.media[1].cacheKey == carousel.media[1].cacheKey)
        let blobVideo: [String: Any] = ["id": "123", "text": "", "media": [["kind": "video", "url": "blob:https://x.com/session", "previewURL": remote]]]
        precondition(ScraperManager.parsePost(blobVideo, platform: "x")!.media[0].playbackURL == nil)
        precondition(!MediaPreviewDownloader.isAllowedPreviewURL(URL(string: "https://twimg.com.attacker.test/image.jpg")!))
        precondition(!MediaPreviewDownloader.isAllowedPreviewURL(URL(string: "http://127.0.0.1/image.jpg")!))
        precondition(!ScraperManager.shouldFinishReady(firstReadyAt: oldDate, now: oldDate.addingTimeInterval(3), stablePasses: 3, posts: [parsedMedia]))
        precondition(!ScraperManager.shouldFinishReady(firstReadyAt: oldDate, now: oldDate.addingTimeInterval(9), stablePasses: 1, posts: [parsedMedia]))
        precondition(ScraperManager.shouldFinishReady(firstReadyAt: oldDate, now: oldDate.addingTimeInterval(9), stablePasses: 2, posts: [parsedMedia]))
        precondition(!ScraperManager.shouldFinishReady(firstReadyAt: oldDate, now: oldDate.addingTimeInterval(9), stablePasses: 5, posts: [old]))
        precondition(ScraperManager.shouldFinishReady(firstReadyAt: oldDate, now: oldDate.addingTimeInterval(15), stablePasses: 1, posts: [old]))
        precondition(ScraperManager.recoveryAction(status: "error", errorKind: "transient", retries: 0, navigationAge: 0.9, remaining: 49.1, canPoll: true) == .wait)
        precondition(ScraperManager.recoveryAction(status: "error", errorKind: "transient", retries: 0, navigationAge: 6, remaining: 44, canPoll: true) == .reload)
        precondition(ScraperManager.recoveryAction(status: "error", errorKind: "transient", retries: 1, navigationAge: 6, remaining: 36, canPoll: true) == .stop)
        precondition(ScraperManager.recoveryAction(status: "error", errorKind: "transient", retries: 0, navigationAge: 35, remaining: 15, canPoll: false) == .reload)
        precondition(ScraperManager.recoveryAction(status: "error", errorKind: "transient", retries: 0, navigationAge: 43, remaining: 7, canPoll: false) == .stop)
        for kind in ["authentication", "rateLimited", "unknown"] {
            precondition(ScraperManager.recoveryAction(status: "error", errorKind: kind, retries: 0, navigationAge: 0.9, remaining: 49, canPoll: true) == .stop)
        }
        precondition(ScraperManager.recoveryAction(status: "loginRequired", errorKind: "transient", retries: 0, navigationAge: 0.9, remaining: 49, canPoll: true) == .stop)
        precondition(ScraperManager.isTransientNavigationError(NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost)))
        for code in [NSURLErrorCancelled, NSURLErrorUserAuthenticationRequired, NSURLErrorServerCertificateUntrusted, NSURLErrorNotConnectedToInternet] {
            precondition(!ScraperManager.isTransientNavigationError(NSError(domain: NSURLErrorDomain, code: code)))
        }
        // The actual refresh policy protects popup owners after their main panel closes.
        precondition(ScraperManager.availableSources(["x", "ig"], loginKey: nil, popupSources: ["x"]) == ["ig"])
        precondition(ScraperManager.availableSources(["x", "ig"], loginKey: "ig", popupSources: ["x"]).isEmpty)
        precondition(ScraperManager.availableSources(["x", "ig"], loginKey: nil, popupSources: ["x", "x"]) == ["ig"])
        precondition(ScraperManager.availableSources(["x", "ig"], loginKey: nil, popupSources: []).count == 2)
        checkDownloader()
        print("Scraper regression checks passed: failure retention, source isolation, confirmed-empty clearing, ISO dates, stable IDs, cached-media retention, bounded cookie-free preview downloads, deferred-media settling, bounded transient recovery, source-owned auth lifecycle.")
    }

    static func checkDownloader() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("feedbar-download-tests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
                                      samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        for x in 0..<2 { for y in 0..<2 { bitmap.setColor(NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 1), atX: x, y: y) } }
        PreviewFixtureProtocol.image = bitmap.representation(using: .png, properties: [:])!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PreviewFixtureProtocol.self]
        let downloader = MediaPreviewDownloader(configuration: configuration, cacheDirectory: directory)
        var finished = 0
        var successful = 0
        for path in ["good1", "good2", "good3", "good4", "badMime", "oversizeHeader", "oversizeStream"] {
            let media = FeedMedia(kind: "image", url: "https://pbs.twimg.com/media/\(path).png")
            downloader.enqueue(media, source: "fixture") { filename in
                finished += 1
                if let filename {
                    successful += 1
                    var cached = media; cached.localPreviewFile = filename
                    precondition(FeedMediaCache.imageURL(for: cached, directory: directory) != nil)
                }
            }
        }
        let deadline = Date().addingTimeInterval(8)
        while finished < 7 && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        precondition(finished == 7 && successful == 4, "Preview bounds or image validation failed")
        precondition(PreviewFixtureProtocol.requestCount == 7 && PreviewFixtureProtocol.credentialsAbsent)
        downloader.cancel()
    }

}


/// Intercepts every request: these tests never connect to the media host.
private final class PreviewFixtureProtocol: URLProtocol {
    static var image = Data()
    static var requestCount = 0
    static var credentialsAbsent = true
    static let lock = NSLock()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.requestCount += 1
        Self.credentialsAbsent = Self.credentialsAbsent && request.value(forHTTPHeaderField: "Cookie") == nil && request.value(forHTTPHeaderField: "Authorization") == nil && !request.httpShouldHandleCookies
        Self.lock.unlock()
        let path = request.url!.lastPathComponent
        var headers = ["Content-Type": path.hasPrefix("badMime") ? "text/html" : "image/png"]
        if path.hasPrefix("oversizeHeader") { headers["Content-Length"] = String(MediaPreviewDownloader.maximumBytes + 1) }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        let data = path.hasPrefix("oversizeStream") ? Data(repeating: 0, count: MediaPreviewDownloader.maximumBytes + 1) : Self.image
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
