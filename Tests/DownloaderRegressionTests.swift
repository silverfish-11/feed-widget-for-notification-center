import Foundation
import AppKit

@main struct DownloaderRegressionTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FeedBarDownloadProbe-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
                                      samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        for x in 0..<2 { for y in 0..<2 { bitmap.setColor(NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 1), atX: x, y: y) } }
        LocalPreviewProtocol.image = bitmap.representation(using: .png, properties: [:])!
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LocalPreviewProtocol.self]
        let downloader = MediaPreviewDownloader(configuration: config, cacheDirectory: root)
        let duplicate = FeedMedia(kind: "image", url: "https://pbs.twimg.com/media/duplicate.png")
        var duplicates = 0
        for _ in 0..<7 {
            downloader.enqueue(duplicate, source: "x") { name in
                precondition(name != nil)
                duplicates += 1
            }
        }
        spin { duplicates == 7 }
        precondition((1...MediaPreviewDownloader.maximumConcurrent).contains(LocalPreviewProtocol.count), "Queued duplicates downloaded an already cached image")
        print("Queued duplicate previews: \(duplicates) completions, \(LocalPreviewProtocol.count) initial requests; remaining jobs reuse cache.")
        var xCancelled = 0
        var igSucceeded = 0
        for index in 0..<4 {
            downloader.enqueue(FeedMedia(kind: "image", url: "https://pbs.twimg.com/media/slow-\(index).png"), source: "x") { name in
                precondition(name == nil)
                xCancelled += 1
            }
        }
        for index in 0..<3 {
            downloader.enqueue(FeedMedia(kind: "image", url: "https://pbs.twimg.com/media/ig-\(index).png"), source: "ig") { name in
                precondition(name != nil)
                igSucceeded += 1
            }
        }
        downloader.cancel(source: "x")
        spin { xCancelled == 4 && igSucceeded == 3 }
        print("Cancel source: x callbacks=\(xCancelled), other-source images=\(igSucceeded)")
        let before = LocalPreviewProtocol.count
        var rotatedDone = false
        var rotated = duplicate
        rotated.url = duplicate.url! + "?token=renewed"
        downloader.enqueue(rotated, source: "x") { name in precondition(name != nil); rotatedDone = true }
        spin { rotatedDone }
        precondition(before == LocalPreviewProtocol.count, "A renewed signed URL did not recover the existing cache file")
        print("Downloader regression checks passed: queued cache reuse, source cancellation, independent-source completion, signed URL orphan recovery.")
        downloader.cancel()
    }
    static func spin(until predicate: () -> Bool) {
        let deadline = Date().addingTimeInterval(5)
        while !predicate(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        precondition(predicate(), "Downloader fixture timed out")
    }
}

/// Intercepts every URL; these fixtures never contact a CDN or read app storage.
private final class LocalPreviewProtocol: URLProtocol, @unchecked Sendable {
    static var image = Data()
    private static var requests = 0
    private static let lock = NSLock()
    static var count: Int { lock.lock(); defer { lock.unlock() }; return requests }
    private let stateLock = NSLock()
    private var stopped = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.requests += 1; Self.lock.unlock()
        let delay = request.url!.lastPathComponent.hasPrefix("slow") ? 0.2 : 0.01
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [self] in
            stateLock.lock(); defer { stateLock.unlock() }
            guard !stopped else { return }
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                headerFields: ["Content-Type": "image/png"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Self.image)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() { stateLock.lock(); stopped = true; stateLock.unlock() }
}
