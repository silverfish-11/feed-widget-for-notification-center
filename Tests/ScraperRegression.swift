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
        checkQuotedPosts()
        checkReplyContexts()
        checkDownloader()
        print("Scraper regression checks passed: failure retention, source isolation, confirmed-empty clearing, ISO dates, stable IDs, quoted/reply attribution, bounded parent enrichment, hydration and targeted caching, cached-media retention, bounded cookie-free preview downloads, deferred-media settling, bounded transient recovery, source-owned auth lifecycle.")
    }

    static func checkReplyContexts() {
        let parentURL = "https://pbs.twimg.com/media/reply-parent.jpg"
        let ownURL = "https://pbs.twimg.com/media/reply-own.jpg"
        let rawParent: [String: Any] = ["id": "700", "author": "Parent Fixture", "handle": "parent_fixture",
            "text": "Original parent", "media": [["kind": "image", "url": parentURL]]]
        let raw: [String: Any] = ["id": "701", "author": "Reply Fixture", "text": "Reply caption",
            "media": [["kind": "image", "url": ownURL]],
            "quotedPost": ["id": "702", "author": "Quote Fixture", "text": "Separate quote"],
            "replyContext": ["handles": ["@parent_fixture", "PARENT_FIXTURE", "invalid/path", "second"], "parent": rawParent]]
        let parsed = ScraperManager.parsePost(raw, platform: "x")!
        precondition(parsed.replyContext?.handles == ["parent_fixture", "second"])
        precondition(parsed.author == "Reply Fixture" && parsed.text == "Reply caption")
        precondition(parsed.replyContext?.parent?.id == "700" && parsed.replyContext?.parent?.text == "Original parent")
        precondition(parsed.media.count == 1 && parsed.media[0].url == ownURL && parsed.quotedPost?.id == "702")
        precondition(parsed.allMedia.count == 2)
        precondition(ScraperManager.parsePost(raw, platform: "ig")?.replyContext == nil)
        let unknown = ScraperManager.parsePost(["id": "701", "text": "Reply caption", "replyContext": ["handles": [], "parent": NSNull()]], platform: "x")!
        precondition(unknown.replyContext != nil && FeedReplyResolutionPolicy.needsResolution(unknown))
        var cached = parsed
        let parentKey = cached.replyContext!.parent!.media[0].cacheKey
        cached.replyContext?.parent?.media[0].localPreviewFile = parentKey + ".jpg"
        let missing = ScraperManager.parsePost(["id": "701", "text": "Updated reply"], platform: "x", previous: cached)!
        precondition(missing.replyContext == cached.replyContext)
        let sparse = ScraperManager.parsePost(["id": "701", "text": "Updated reply", "replyContext": ["handles": [], "parent": ["id": "700", "media": []]]], platform: "x", previous: cached)!
        precondition(sparse.replyContext == cached.replyContext)
        let conflicting = ScraperManager.parsePost(["id": "701", "text": "Updated reply", "replyContext": ["handles": ["other"], "parent": ["id": "999", "text": "Unrelated parent"]]], platform: "x", previous: cached)!
        precondition(conflicting.replyContext?.parent == cached.replyContext?.parent)
        let selfParent = ScraperManager.parsePost(["id": "701", "text": "Reply", "replyContext": ["handles": ["parent_fixture"], "parent": ["id": "701", "text": "Itself"]]], platform: "x")!
        precondition(selfParent.replyContext?.parent == nil)
        let unavailableRaw: [String: Any] = ["id": "701", "replyContext": ["handles": ["parent_fixture"], "parent": ["id": NSNull(), "isUnavailable": true]]]
        let unavailable = ScraperManager.parsePost(unavailableRaw, platform: "x", previous: cached)!
        precondition(unavailable.replyContext?.parent?.isUnavailable == true)
        precondition(unavailable.replyContext?.parent?.id == "700" && unavailable.replyContext?.parent?.media.isEmpty == true)
        precondition(!FeedReplyResolutionPolicy.needsResolution(unavailable))
        let unknownUnavailable = ScraperManager.parsePost(unavailableRaw, platform: "x")!
        precondition(unknownUnavailable.replyContext?.parent?.isUnavailable == true)
        precondition(unknownUnavailable.replyContext?.parent?.id == nil)
        // Reusing an image does not transfer ownership from the reply to the parent.
        var sharedImage = cached
        sharedImage.media = cached.replyContext!.parent!.media
        let noMediaPass = ScraperManager.parsePost(["id": "701", "text": "Reply", "media": [], "replyContext": ["handles": ["parent_fixture"], "parent": rawParent]], platform: "x", previous: sharedImage)!
        precondition(noMediaPass.media == sharedImage.media && noMediaPass.replyContext?.parent?.media == cached.replyContext?.parent?.media)
        var posts = [unknown, parsed]
        var detail = raw
        detail["author"] = "Never replace the outer author"
        detail["text"] = "Never replace the outer caption"
        precondition(ScraperManager.applyResolvedReply(detail, postID: "701", to: &posts))
        precondition(posts.count == 2 && posts[0].author == unknown.author && posts[0].text == unknown.text)
        precondition(posts[0].replyContext?.parent?.id == "700" && posts[1] == parsed)
        precondition(!ScraperManager.applyResolvedReply(detail, postID: "999", to: &posts))
        var wrong = detail; wrong["id"] = "999"
        precondition(!ScraperManager.applyResolvedReply(wrong, postID: "701", to: &posts))
        var removed: [FeedPost] = []
        precondition(!ScraperManager.applyResolvedReply(detail, postID: "701", to: &removed))
        var different = raw
        different["replyContext"] = ["handles": ["other"], "parent": ["id": "999", "text": "Other parent"]]
        precondition(!ScraperManager.applyResolvedReply(different, postID: "701", to: &posts))
        precondition(ScraperManager.applyResolvedReply(unavailableRaw, postID: "701", to: &posts))
        precondition(posts[0].replyContext?.parent?.isUnavailable == true)
        var parentPosts = [parsed]
        precondition(ScraperManager.applyCachedPreview("parent-cache.jpg", for: parentKey, to: &parentPosts))
        precondition(parentPosts[0].media[0].localPreviewFile == nil && parentPosts[0].replyContext?.parent?.media[0].localPreviewFile == "parent-cache.jpg")
        var gone = [unavailable]
        precondition(!ScraperManager.applyCachedPreview("late.jpg", for: parentKey, to: &gone))
        precondition(gone[0].replyContext?.parent?.media.isEmpty == true)
        var changed = parsed
        changed.replyContext?.parent?.text = "Hydrated parent caption"
        precondition(ScraperManager.readySignature(for: [changed]) != ScraperManager.readySignature(for: [parsed]))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let candidates = (1...20).map { index in FeedPost(id: String(index), platform: "x", author: "Fixture", handle: "fixture", text: "Reply", timestamp: now, likes: 0, reposts: 0, comments: 0, replyContext: FeedReplyContext(handles: ["parent"])) }
        precondition(FeedReplyResolutionPolicy.candidates(in: candidates, attemptedAt: [:], now: now) == ["1", "2", "3", "4", "5", "6"])
        precondition(FeedReplyResolutionPolicy.candidates(in: [candidates[0], candidates[0], candidates[1]], attemptedAt: [:], now: now) == ["1", "2"])
        precondition(FeedReplyResolutionPolicy.candidates(in: candidates, attemptedAt: ["1": now, "2": now.addingTimeInterval(-900)], now: now).first == "2")
        precondition(FeedReplyResolutionPolicy.candidates(in: [parsed, unavailable], attemptedAt: [:], now: now).isEmpty)
        var placeholder = parsed
        placeholder.replyContext?.parent?.media = [FeedMedia(kind: "video")]
        precondition(FeedReplyResolutionPolicy.needsResolution(placeholder))
        precondition(!FeedReplyResolutionPolicy.acceptsParent(["id": "701"], targetID: "701"))
        precondition(!FeedReplyResolutionPolicy.acceptsParent(["id": "invalid", "isUnavailable": true], targetID: "701"))
        precondition(!FeedReplyResolutionPolicy.acceptsParent(["text": "Unverified neighbor"], targetID: "701"))
        precondition(FeedReplyResolutionPolicy.acceptsParent(["isUnavailable": true], targetID: "701"))
        precondition(!FeedReplyResolutionPolicy.shouldFinishReady(firstReadyAt: now, now: now.addingTimeInterval(6), stablePasses: 4, hasUsableMedia: false, isUnavailable: false))
        precondition(!FeedReplyResolutionPolicy.shouldFinishReady(firstReadyAt: now, now: now.addingTimeInterval(6), stablePasses: 4, hasUsableMedia: true, isUnavailable: false))
        precondition(FeedReplyResolutionPolicy.shouldFinishReady(firstReadyAt: now, now: now.addingTimeInterval(8), stablePasses: 2, hasUsableMedia: true, isUnavailable: false))
        precondition(FeedReplyResolutionPolicy.shouldFinishReady(firstReadyAt: now, now: now.addingTimeInterval(15), stablePasses: 1, hasUsableMedia: false, isUnavailable: false))
        precondition(FeedReplyResolutionPolicy.shouldFinishReady(firstReadyAt: now, now: now.addingTimeInterval(3), stablePasses: 2, hasUsableMedia: false, isUnavailable: true))
    }

    static func checkQuotedPosts() {
        let quoteURL = "https://pbs.twimg.com/media/quoted.jpg?signature=old"
        let outerURL = "https://pbs.twimg.com/media/outer.jpg"
        let rawQuote: [String: Any] = ["id": "456", "author": "Quoted Author", "handle": "quoted_fixture",
                                      "text": "Quoted words", "timestamp": "2026-03-05T09:00:00.000Z",
                                      "media": [["kind": "image", "url": quoteURL]]]
        let raw: [String: Any] = ["id": "123", "author": "Outer Author", "handle": "outer_fixture", "text": "Outer words",
                                 "media": [["kind": "image", "url": outerURL]], "quotedPost": rawQuote]
        let parsed = ScraperManager.parsePost(raw, platform: "x")!
        precondition(parsed.author == "Outer Author" && parsed.handle == "outer_fixture" && parsed.text == "Outer words")
        precondition(parsed.media.count == 1 && parsed.media[0].url == outerURL)
        precondition(parsed.quotedPost?.id == "456" && parsed.quotedPost?.author == "Quoted Author" &&
                     parsed.quotedPost?.handle == "quoted_fixture" && parsed.quotedPost?.text == "Quoted words")
        precondition(parsed.quotedPost?.timestamp != nil && parsed.quotedPost?.media.first?.url == quoteURL)
        precondition(parsed.allMedia.count == 2)
        let quoteOnly = ScraperManager.parsePost(["id": "123", "quotedPost": rawQuote], platform: "x")!
        precondition(quoteOnly.text.isEmpty && quoteOnly.media.isEmpty && quoteOnly.quotedPost?.text == "Quoted words")
        var legacyFlattened = FeedPost(id: "123", platform: "x", author: "Quoted Author", handle: "quoted_fixture",
                                       text: "Quoted words", timestamp: quoteOnly.quotedPost!.timestamp!,
                                       likes: 0, reposts: 0, comments: 0, media: quoteOnly.quotedPost!.media)
        let legacyFilename = legacyFlattened.media[0].cacheKey + ".jpg"
        legacyFlattened.media[0].localPreviewFile = legacyFilename
        let migrated = ScraperManager.parsePost(["id": "123", "author": "Outer Author", "handle": "outer_fixture",
                                                 "text": "", "media": [], "quotedPost": rawQuote],
                                                platform: "x", previous: legacyFlattened)!
        precondition(migrated.text.isEmpty && migrated.author == "Outer Author" && migrated.media.isEmpty && migrated.timestamp == .distantPast,
                     "An old flattened quote must not survive as duplicated outer caption, attribution, date or media")
        precondition(migrated.quotedPost?.text == "Quoted words" && migrated.quotedPost?.media.count == 1)
        precondition(migrated.quotedPost?.media[0].localPreviewFile == legacyFilename)
        var sparseQuote = rawQuote
        sparseQuote["media"] = []
        sparseQuote.removeValue(forKey: "timestamp")
        let firstMigrationPass = ScraperManager.parsePost(["id": "123", "text": "", "media": [], "quotedPost": sparseQuote],
                                                         platform: "x", previous: legacyFlattened)!
        let secondMigrationPass = ScraperManager.parsePost(["id": "123", "text": "", "media": [], "quotedPost": rawQuote],
                                                          platform: "x", previous: firstMigrationPass)!
        precondition(secondMigrationPass.media.isEmpty && secondMigrationPass.quotedPost?.media[0].localPreviewFile == legacyFilename &&
                     secondMigrationPass.timestamp == .distantPast,
                     "Deferred quote images must move out of legacy parent fallback while retaining their cached preview")
        let explicitDate = ScraperManager.parsePost(["id": "123", "text": "", "timestamp": "2026-03-05T10:00:00Z", "quotedPost": rawQuote],
                                                   platform: "x", previous: firstMigrationPass)!
        precondition(explicitDate.timestamp > legacyFlattened.timestamp, "A fresh outer timestamp must win over migration fallback")
        let explicitParent = ScraperManager.parsePost(["id": "123", "text": "", "media": [["kind": "image", "url": quoteURL]],
                                                       "quotedPost": rawQuote], platform: "x", previous: firstMigrationPass)!
        precondition(explicitParent.media.count == 1 && explicitParent.quotedPost?.media.count == 1,
                     "An explicitly observed parent attachment must survive even when its image also appears in the quote")
        precondition(ScraperManager.parsePost(["id": "123", "quotedPost": ["media": [["kind": "image", "url": quoteURL]]]], platform: "x")?.quotedPost?.media.count == 1)
        precondition(ScraperManager.parsePost(["id": "123", "quotedPost": ["isUnavailable": true]], platform: "x")?.quotedPost?.isUnavailable == true)
        precondition(ScraperManager.parsePost(["id": "123", "quotedPost": [:]], platform: "x") == nil)
        precondition(ScraperManager.parsePost(["id": "123", "quotedPost": rawQuote], platform: "ig") == nil)
        var cached = parsed
        let quoteFilename = cached.quotedPost!.media[0].cacheKey + ".jpg"
        cached.quotedPost?.media[0].localPreviewFile = quoteFilename
        cached.quotedPost?.media.append(FeedMedia(kind: "image", url: "https://pbs.twimg.com/media/quoted-slide2.jpg"))
        var renewedQuote = rawQuote
        renewedQuote["media"] = [["kind": "image", "url": "https://pbs.twimg.com/media/quoted.jpg?signature=new"]]
        let renewed = ScraperManager.parsePost(["id": "123", "quotedPost": renewedQuote], platform: "x", previous: cached)!
        precondition(renewed.quotedPost?.media.count == 2 && renewed.quotedPost?.media[0].localPreviewFile == cached.quotedPost?.media[0].localPreviewFile)
        precondition(renewed.quotedPost?.media[0].url?.hasSuffix("signature=new") == true)
        let missing = ScraperManager.parsePost(["id": "123", "text": "Outer updated", "quotedPost": NSNull()], platform: "x", previous: cached)!
        precondition(missing.quotedPost == cached.quotedPost)
        let sparse = ScraperManager.parsePost(["id": "123", "quotedPost": ["id": "456", "text": "", "media": []]], platform: "x", previous: cached)!
        precondition(sparse.quotedPost == cached.quotedPost)
        let changedID = ScraperManager.parsePost(["id": "123", "quotedPost": ["id": "789", "text": "Different quote"]], platform: "x", previous: cached)!
        precondition(changedID.quotedPost?.id == "789" && changedID.quotedPost?.author == "" && changedID.quotedPost?.media.isEmpty == true)
        let wrongOuter = ScraperManager.parsePost(["id": "999", "text": "Different outer post"], platform: "x", previous: cached)!
        precondition(wrongOuter.quotedPost == nil && wrongOuter.media.isEmpty)
        let unavailable = ScraperManager.parsePost(["id": "123", "quotedPost": ["id": "456", "isUnavailable": true]], platform: "x", previous: cached)!
        precondition(unavailable.quotedPost?.isUnavailable == true && unavailable.quotedPost?.text.isEmpty == true && unavailable.quotedPost?.media.isEmpty == true)
        let afterUnavailable = ScraperManager.parsePost(["id": "123", "quotedPost": ["id": "456", "media": []]], platform: "x", previous: unavailable)!
        precondition(afterUnavailable.quotedPost == unavailable.quotedPost)
        let missingAfterUnavailable = ScraperManager.parsePost(["id": "123"], platform: "x", previous: unavailable)!
        precondition(missingAfterUnavailable.quotedPost == unavailable.quotedPost)
        let firstReady = Date(timeIntervalSince1970: 1_700_000_000)
        precondition(ScraperManager.shouldFinishReady(firstReadyAt: firstReady, now: firstReady.addingTimeInterval(9), stablePasses: 2, posts: [quoteOnly]))
        for field in ["author", "text", "timestamp", "media", "unavailable"] {
            var changed = quoteOnly
            switch field {
            case "author": changed.quotedPost?.author = "Hydrated Name"
            case "text": changed.quotedPost?.text = "Hydrated text"
            case "timestamp": changed.quotedPost?.timestamp = firstReady
            case "media": changed.quotedPost?.media = []
            default: changed.quotedPost?.isUnavailable = true
            }
            precondition(ScraperManager.readySignature(for: [changed]) != ScraperManager.readySignature(for: [quoteOnly]))
        }
        var current = [quoteOnly]
        let key = quoteOnly.quotedPost!.media[0].cacheKey
        precondition(ScraperManager.applyCachedPreview(key + ".jpg", for: key, to: &current))
        precondition(current[0].media.isEmpty && current[0].quotedPost?.media[0].localPreviewFile == key + ".jpg")
        precondition(!ScraperManager.applyCachedPreview(key + ".jpg", for: key, to: &current))
        current = [unavailable, changedID]
        precondition(!ScraperManager.applyCachedPreview(key + ".jpg", for: key, to: &current))
        precondition(current == [unavailable, changedID], "A late preview must not resurrect a removed quote or alter a different quote")
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
        let quoteMedia = FeedMedia(kind: "image", url: "https://pbs.twimg.com/media/asyncQuote.png")
        let outerMedia = FeedMedia(kind: "image", url: "https://pbs.twimg.com/media/asyncOuter.png")
        var posts = [FeedPost(id: "321", platform: "x", author: "Outer", handle: "outer_fixture", text: "Outer caption",
                              timestamp: .distantPast, likes: 0, reposts: 0, comments: 0, media: [outerMedia],
                              quotedPost: FeedQuotedPost(id: "654", author: "Quoted", text: "Quoted caption", media: [quoteMedia]))]
        var quoteFinished = false
        downloader.enqueue(quoteMedia, source: "fixture") { filename in
            precondition(filename != nil)
            precondition(ScraperManager.applyCachedPreview(filename!, for: quoteMedia.cacheKey, to: &posts))
            quoteFinished = true
        }
        let quoteDeadline = Date().addingTimeInterval(8)
        while !quoteFinished && Date() < quoteDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        precondition(quoteFinished && posts[0].media[0].localPreviewFile == nil)
        precondition(posts[0].quotedPost?.media[0].localPreviewFile == quoteMedia.cacheKey + ".jpg")
        precondition(FeedMediaCache.imageURL(for: posts[0].quotedPost!.media[0], directory: directory) != nil)
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
