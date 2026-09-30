import Foundation
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

@main
struct MediaRegressionTests {
    struct Failure: Error { let message: String }
    static var assertions = 0
    static func expect(_ result: @autoclosure () -> Bool, _ message: String) throws {
        assertions += 1
        if !result() { throw Failure(message: message) }
    }

    static func fixturePNG() throws -> Data {
        guard let context = CGContext(data: nil, width: 2400, height: 1600, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let color = CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(), components: [0.12, 0.45, 0.85, 1]) else {
            throw Failure(message: "Could not create the local image fixture")
        }
        context.setFillColor(color)
        context.fill(CGRect(x: 0, y: 0, width: 2400, height: 1600))
        guard let image = context.makeImage() else { throw Failure(message: "Could not create fixture CGImage") }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw Failure(message: "Could not create fixture encoder")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw Failure(message: "Could not encode fixture") }
        return data as Data
    }

    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FeedBarMediaTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let image = FeedMedia(kind: "image", url: "https://pbs.twimg.com/media/fixture.jpg", altText: "A local test fixture", width: 2400, height: 1600)
        let video = FeedMedia(kind: "video", url: "https://video.twimg.com/fixture.mp4", previewURL: "https://pbs.twimg.com/media/poster.jpg", altText: "Video fixture")
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        var post = FeedPost(id: "123", platform: "x", author: "Fixture", handle: "fixture", text: "",
                            timestamp: date, likes: 0, reposts: 0, comments: 0, media: [image, video])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var legacy = try JSONSerialization.jsonObject(with: encoder.encode(post)) as! [String: Any]
        legacy.removeValue(forKey: "media")
        let legacyPost = try decoder.decode(FeedPost.self, from: JSONSerialization.data(withJSONObject: legacy))
        try expect(legacyPost.media.isEmpty, "Existing text-only feeds must decode without a media key")
        try expect(legacyPost.id == post.id && legacyPost.timestamp == date, "Legacy fields must remain unchanged")
        var withoutMedia = post
        withoutMedia.media = []
        try expect(withoutMedia != post, "Same-ID posts with newly hydrated media must compare unequal")
        try expect(withoutMedia.stableIdentifier == post.stableIdentifier, "Media updates must retain row identity")
        let updatedCaption = FeedPost(id: post.id, platform: post.platform, author: post.author, handle: post.handle,
                                      text: "A newly hydrated caption", timestamp: post.timestamp, likes: post.likes,
                                      reposts: post.reposts, comments: post.comments, score: post.score, media: post.media)
        try expect(updatedCaption != post && updatedCaption.stableIdentifier == post.stableIdentifier,
                   "Caption updates must change value equality without changing identity")
        var previewReady = post
        previewReady.media[0].localPreviewFile = previewReady.media[0].cacheKey + ".jpg"
        try expect(previewReady != post && previewReady.stableIdentifier == post.stableIdentifier,
                   "An asynchronously saved preview must change the post value without changing identity")
        try expect(Set([withoutMedia, post, updatedCaption, previewReady]).count == 4,
                   "Hashable must follow full post values rather than only their stable ID")
        let roundTrip = try decoder.decode(FeedPost.self, from: encoder.encode(post))
        try expect(roundTrip.media == [image, video] && roundTrip.text.isEmpty, "Media-only and mixed attachments must survive serialization")
        let minimal = try decoder.decode(FeedMedia.self, from: Data("{\"kind\":\"image\",\"url\":\"https://example.com/photo.jpg\"}".utf8))
        try expect(minimal.altText.isEmpty && minimal.localPreviewFile == nil, "Optional media metadata must support absent fields")
        try expect(image.cacheKey.count == 64 && image.cacheKey.allSatisfy { $0.isHexDigit }, "Cache keys must be safe SHA256 hex names")
        try expect(image.cacheKey == "c489e9d5b2679e4dff9e3ffc5f5deb0e5237b578c4967599550b82a656b70287",
                   "Existing valid preview keys must not change during fallback-identity repair")
        var cached = image
        cached.localPreviewFile = "ignored.jpg"
        try expect(cached.cacheKey == image.cacheKey, "Cache identity must not change when the local path changes")
        for host in ["pbs.twimg.com", "scontent.cdninstagram.com", "scontent.fbcdn.net"] {
            let original = FeedMedia(kind: "image", url: "https://\(host)/media/asset.jpg?signature=old&size=large#old")
            let renewed = FeedMedia(kind: "image", url: "https://\(host)/media/asset.jpg?signature=new&size=small#new")
            let otherPath = FeedMedia(kind: "image", url: "https://\(host)/media/other-asset.jpg?signature=new")
            try expect(original.cacheKey == renewed.cacheKey, "Renewed recognized CDN URLs must preserve a cached image")
            try expect(original.cacheKey != otherPath.cacheKey, "Distinct CDN asset paths must remain distinct")
        }
        let samePathA = FeedMedia(kind: "image", url: "https://pbs.twimg.com/media/asset.jpg")
        let samePathB = FeedMedia(kind: "image", url: "https://scontent.cdninstagram.com/media/asset.jpg")
        try expect(samePathA.cacheKey != samePathB.cacheKey, "Different CDN hosts must remain distinct")
        let otherHostA = FeedMedia(kind: "image", url: "https://example.com/photo?id=one")
        let otherHostB = FeedMedia(kind: "image", url: "https://example.com/photo?id=two")
        try expect(otherHostA.cacheKey != otherHostB.cacheKey, "Unrecognized hosts must preserve query-based identity")
        let spoofedA = FeedMedia(kind: "image", url: "https://twimg.com.attacker.test/photo?id=one")
        let spoofedB = FeedMedia(kind: "image", url: "https://twimg.com.attacker.test/photo?id=two")
        try expect(spoofedA.cacheKey != spoofedB.cacheKey, "CDN lookalike domains must preserve full URL identity")
        try expect(video.previewRemoteURL?.absoluteString.hasSuffix("poster.jpg") == true, "Video previews must use the poster image")
        try expect(video.playbackURL?.absoluteString.hasSuffix("fixture.mp4") == true, "Playable videos must retain their HTTP URL")
        try expect(image.playbackURL == nil, "Image URLs must not be treated as playable videos")
        let posterless = FeedMedia(kind: "video", url: "https://video.twimg.com/fixture.mp4")
        try expect(posterless.previewRemoteURL == nil, "A video URL must never become its own image preview")
        let mislabeledPoster = FeedMedia(kind: "video", previewURL: "https://video.twimg.com/fixture.mp4")
        try expect(mislabeledPoster.previewRemoteURL == nil, "Known video formats must not be accepted as poster URLs")
        for unsupported in ["", "blob:https://example.com/poster", "https://video.twimg.com/unusable.mp4"] {
            let first = FeedMedia(kind: "image", url: image.url, previewURL: unsupported)
            let second = FeedMedia(kind: "image", url: "https://pbs.twimg.com/media/other.jpg", previewURL: unsupported)
            try expect(first.previewRemoteURL == image.previewRemoteURL && first.cacheKey == image.cacheKey,
                       "An unusable poster must use the actual fallback image's cache identity")
            try expect(first.cacheKey != second.cacheKey, "Distinct fallback images must never collide through an unusable poster")
        }
        let rawSpelling = "https://example.com/image with spaces.png"
        let rawImage = FeedMedia(kind: "image", url: rawSpelling)
        let rawPoster = FeedMedia(kind: "image", previewURL: rawSpelling)
        try expect(rawImage.cacheKey == rawPoster.cacheKey, "Choosing a usable preview must preserve normal URL spelling identity")
        try expect(rawImage.cacheKey == "0791707fb7edab04c44f4baffa8442731d9d31fe705548d861982cd2961a5e0e",
                   "Non-CDN URL spelling must keep its previous cache key")
        let blobVideo = FeedMedia(kind: "video", url: "blob:https://x.com/123", previewURL: "https://pbs.twimg.com/media/poster.jpg")
        try expect(blobVideo.playbackURL == nil && blobVideo.previewRemoteURL != nil, "Blob-backed video should preserve its poster without claiming playback")
        for unsafe in ["file:///etc/passwd", "blob:https://example.com/123", "data:image/png;base64,aGVsbG8=", "/relative.png", "http://localhost/a.jpg", "http://127.0.0.1/a", "http://192.168.1.2/a", "http://10.0.0.3/a", "http://172.20.0.1/a", "http://169.254.169.254/a", "http://[::1]/a", "http://user:pass@example.com/a"] {
            try expect(FeedMedia.remoteURL(unsafe) == nil, "Unsafe media URL was accepted: \(unsafe)")
        }
        try expect(FeedMedia.remoteURL("https://images.example.com/a.png?size=large") != nil, "Normal public image URLs must remain supported")

        let png = try fixturePNG()
        cached.localPreviewFile = try FeedMediaCache.savePreview(data: png, for: cached, directory: root)
        try expect(cached.localPreviewFile == cached.cacheKey + ".jpg", "Cache filenames must come only from the hash")
        guard let url = FeedMediaCache.imageURL(for: cached, directory: root),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            throw Failure(message: "Saved preview was not readable")
        }
        try expect(max(width, height) == 1000 && min(width, height) > 0, "Large source images must downsample before storage")
        try expect(CGImageSourceGetType(source) as String? == UTType.jpeg.identifier, "Cached previews must be standard JPEG images")
        try expect(FeedMediaCache.image(for: cached, directory: root) != nil, "UI image helpers must read saved previews")
        try expect(FeedMediaCache.imageURL(for: image, directory: root) == nil, "A remote attachment without a saved cache reference must not imply an image download")
        let before = try Data(contentsOf: url)
        for (format, complete) in [("JPEG", before), ("PNG", png)] {
            for count in [complete.count / 10, complete.count / 2, complete.count * 99 / 100, complete.count - 1] {
                do {
                    try FeedMediaCache.savePreview(data: Data(complete.prefix(count)), for: cached, directory: root)
                    throw Failure(message: "A truncated \(format) source became a permanent partial preview")
                } catch FeedMediaCacheError.invalidImage { assertions += 1 }
                try expect(tryData(url) == before, "Rejecting a truncated \(format) replacement must preserve the last good preview")
                try expect(FeedMediaCache.imageURL(for: cached, directory: root) == url,
                           "The retained preview must remain readable after a failed \(format) replacement")
            }
        }
        var completeJPEG = FeedMedia(kind: "image", url: "https://pbs.twimg.com/media/complete-source.jpg")
        completeJPEG.localPreviewFile = try FeedMediaCache.savePreview(data: before, for: completeJPEG, directory: root)
        try expect(FeedMediaCache.imageURL(for: completeJPEG, directory: root) != nil,
                   "Complete JPEG sources must remain supported alongside PNG")
        for (format, complete) in [("JPEG", before), ("PNG", png)] {
            var withTrailer = FeedMedia(kind: "image", url: "https://pbs.twimg.com/media/trailer-\(format)")
            withTrailer.localPreviewFile = try FeedMediaCache.savePreview(data: complete + Data("\nouter container trailer\n".utf8),
                                                                         for: withTrailer, directory: root)
            try expect(FeedMediaCache.imageURL(for: withTrailer, directory: root) != nil,
                       "A complete \(format) followed by trailing bytes must remain readable")
        }
        // APP1 data may itself contain a complete JPEG thumbnail; its EOI is not
        // the main image's EOI. Segment lengths must keep these distinct.
        let embedded = Data("Fixture thumbnail\0".utf8) + before
        precondition(embedded.count + 2 < 65_536)
        let segment = Data([0xff, 0xe1, UInt8((embedded.count + 2) >> 8), UInt8((embedded.count + 2) & 0xff)]) + embedded
        var withEmbeddedThumbnail = FeedMedia(kind: "image", url: "https://pbs.twimg.com/media/embedded-thumbnail.jpg")
        withEmbeddedThumbnail.localPreviewFile = try FeedMediaCache.savePreview(
            data: before.prefix(2) + segment + before.dropFirst(2) + Data("trailer".utf8),
            for: withEmbeddedThumbnail, directory: root)
        try expect(FeedMediaCache.imageURL(for: withEmbeddedThumbnail, directory: root) != nil,
                   "A complete main JPEG must remain supported when metadata contains a thumbnail and a trailer follows EOI")
        let partialWithThumbnail = before.prefix(2) + segment + before.dropFirst(2).prefix(before.count / 2)
        let fakePNGEnd = Data([0, 0, 0, 0, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82])
        for partial in [Data(partialWithThumbnail), Data(png.prefix(png.count / 2)) + fakePNGEnd] {
            do {
                try FeedMediaCache.savePreview(data: partial, for: cached, directory: root)
                throw Failure(message: "Marker bytes inside a partial image were mistaken for a complete image")
            } catch FeedMediaCacheError.invalidImage { assertions += 1 }
            try expect(tryData(url) == before, "Rejecting embedded/fake end markers must preserve the good preview")
        }
        do {
            try FeedMediaCache.savePreview(data: Data("corrupt image".utf8), for: cached, directory: root)
            throw Failure(message: "Corrupt images were accepted")
        } catch is FeedMediaCacheError { assertions += 1 }
        try expect(tryData(url) == before, "A failed decode must retain the previous cached preview")
        do {
            try FeedMediaCache.savePreview(data: Data(repeating: 0, count: FeedMediaCache.maximumInputBytes + 1), for: cached, directory: root)
            throw Failure(message: "Oversized image payloads were accepted")
        } catch FeedMediaCacheError.dataTooLarge { assertions += 1 }
        do {
            try FeedMediaCache.savePreview(data: png, for: posterless, directory: root)
            throw Failure(message: "A video without an image poster was cached as an image")
        } catch FeedMediaCacheError.noPreviewURL { assertions += 1 }
        var traversal = cached
        for path in ["../outside.jpg", "/tmp/outside.jpg", "other.jpg", cached.cacheKey + ".JPG"] {
            traversal.localPreviewFile = path
            try expect(FeedMediaCache.imageURL(for: traversal, directory: root) == nil, "Unexpected preview filenames must be rejected")
        }

        post.media[0] = cached
        try FeedStore.save(FeedSnapshot(sources: ["x": FeedSourceState(posts: [post], status: "ready")]), directory: root)
        let restored = try FeedStore.load(directory: root)
        try expect(restored.posts.first?.media.first?.localPreviewFile == cached.localPreviewFile, "Shared snapshots must retain local preview references")

        try Data("corrupt cached image".utf8).write(to: url, options: .atomic)
        try expect(FeedMediaCache.image(for: cached, directory: root) == nil, "Corrupt local cache data must return no image without network fallback")
        try expect(FeedMediaCache.imageURL(for: cached, directory: root) == nil, "Corrupt cache entries must be cache misses so the collector can retry")
        try before.prefix(before.count / 2).write(to: url, options: .atomic)
        try expect(FeedMediaCache.imageURL(for: cached, directory: root) == nil, "A truncated JPEG must permit a download retry")
        _ = try FeedMediaCache.savePreview(data: png, for: cached, directory: root)

        let symlinkRoot = root.appendingPathComponent("symlink-test")
        try FileManager.default.createDirectory(at: symlinkRoot, withIntermediateDirectories: true)
        let mediaFolder = symlinkRoot.appendingPathComponent("Media")
        try FileManager.default.createSymbolicLink(at: mediaFolder, withDestinationURL: root.appendingPathComponent("Media"))
        try expect(FeedMediaCache.imageURL(for: cached, directory: symlinkRoot) == nil, "Cache directories must not follow symlinks")
        do {
            try FeedMediaCache.savePreview(data: png, for: cached, directory: symlinkRoot)
            throw Failure(message: "Saving through a symlinked cache directory was allowed")
        } catch FeedMediaCacheError.unsafeCachePath { assertions += 1 }
        try FileManager.default.removeItem(at: url)
        let elsewhere = root.appendingPathComponent("outside.jpg")
        try png.write(to: elsewhere)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: elsewhere)
        try expect(FeedMediaCache.imageURL(for: cached, directory: root) == nil, "Individual cache files must not follow symlinks")
        do {
            try FeedMediaCache.savePreview(data: png, for: cached, directory: root)
            throw Failure(message: "Saving over a symlinked cache file was allowed")
        } catch FeedMediaCacheError.unsafeCachePath { assertions += 1 }
        try expect(tryData(elsewhere) == png, "A rejected cache operation must not alter its symlink target")
        print("Passed \(assertions) isolated media model, legacy storage, and image-cache checks.")
    }

    static func tryData(_ url: URL) -> Data? { try? Data(contentsOf: url) }
}
