import Foundation

/// Downloads only public media previews. It never imports WebKit cookies or
/// account headers, and bounds bytes while streaming rather than after download.
final class MediaPreviewDownloader: NSObject, URLSessionDataDelegate {
    static let maximumBytes = 12 * 1024 * 1024
    static let maximumConcurrent = 3
    private let configuration: URLSessionConfiguration
    private let cacheDirectory: URL?
    private lazy var session: URLSession = URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
    private var waiting: [Job] = []
    private var running: [Int: Job] = [:]

    private final class Job {
        let source: String
        let media: FeedMedia
        let completion: (String?) -> Void
        var task: URLSessionDataTask?
        var data = Data()
        var acceptedResponse = false
        var cancelled = false
        init(source: String, media: FeedMedia, completion: @escaping (String?) -> Void) {
            self.source = source; self.media = media; self.completion = completion
        }
    }

    init(configuration: URLSessionConfiguration = .ephemeral, cacheDirectory: URL? = nil) {
        // The optional configuration is a test seam for local URLProtocol fixtures.
        self.configuration = configuration
        self.cacheDirectory = cacheDirectory
        super.init()
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        configuration.httpMaximumConnectionsPerHost = Self.maximumConcurrent
        configuration.httpAdditionalHeaders = ["Accept": "image/*"]
    }

    /// Public CDN allowlist prevents page-controlled attachment URLs probing other services.
    static func isAllowedPreviewURL(_ url: URL) -> Bool {
        guard FeedMedia.remoteURL(url.absoluteString) != nil, let host = url.host?.lowercased() else { return false }
        return ["twimg.com", "cdninstagram.com", "fbcdn.net"].contains { host == $0 || host.hasSuffix("." + $0) }
    }

    func enqueue(_ media: FeedMedia, source: String, completion: @escaping (String?) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        var cached = media
        cached.localPreviewFile = cached.localPreviewFile ?? cached.cacheKey + ".jpg"
        if FeedMediaCache.imageURL(for: cached, directory: cacheDirectory) != nil {
            completion(cached.localPreviewFile)
            return
        }
        guard let url = media.previewRemoteURL, Self.isAllowedPreviewURL(url), waiting.count < 64 else {
            completion(nil)
            return
        }
        waiting.append(Job(source: source, media: media, completion: completion))
        pump()
    }

    func cancel(source: String? = nil) {
        dispatchPrecondition(condition: .onQueue(.main))
        let abandoned = waiting.filter { source == nil || $0.source == source }
        waiting.removeAll { source == nil || $0.source == source }
        abandoned.forEach { $0.completion(nil) }
        for job in running.values where source == nil || job.source == source {
            job.cancelled = true
            job.task?.cancel()
        }
    }

    private func pump() {
        while running.count < Self.maximumConcurrent, !waiting.isEmpty {
            let job = waiting.removeFirst()
            // Another in-flight attachment may have cached this same asset
            // while this job waited. Do not spend another network slot on it.
            var cached = job.media
            cached.localPreviewFile = cached.localPreviewFile ?? cached.cacheKey + ".jpg"
            if FeedMediaCache.imageURL(for: cached, directory: cacheDirectory) != nil {
                job.completion(cached.localPreviewFile)
                continue
            }
            guard let url = job.media.previewRemoteURL else { job.completion(nil); continue }
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
            request.httpShouldHandleCookies = false
            request.setValue("image/*", forHTTPHeaderField: "Accept")
            let task = session.dataTask(with: request)
            job.task = task
            running[task.taskIdentifier] = job
            task.resume()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let job = running[dataTask.taskIdentifier], !job.cancelled,
              let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let url = response.url, Self.isAllowedPreviewURL(url),
              response.expectedContentLength <= Int64(Self.maximumBytes),
              response.mimeType?.lowercased().hasPrefix("image/") == true else {
            completionHandler(.cancel)
            return
        }
        job.acceptedResponse = true
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let job = running[dataTask.taskIdentifier], !job.cancelled else { return }
        guard data.count <= Self.maximumBytes - job.data.count else {
            job.cancelled = true
            dataTask.cancel()
            return
        }
        job.data.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let job = running[task.taskIdentifier] else { return }
        guard error == nil, !job.cancelled, job.acceptedResponse, !job.data.isEmpty else {
            complete(task.taskIdentifier, filename: nil)
            return
        }
        let data = job.data
        let media = job.media
        let directory = cacheDirectory
        // Retain this concurrency slot until image validation/downsampling finishes.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let filename = try? FeedMediaCache.savePreview(data: data, for: media, directory: directory)
            DispatchQueue.main.async { self?.complete(task.taskIdentifier, filename: filename) }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, Self.isAllowedPreviewURL(url) else { completionHandler(nil); return }
        var clean = request
        clean.httpShouldHandleCookies = false
        clean.setValue(nil, forHTTPHeaderField: "Cookie")
        clean.setValue(nil, forHTTPHeaderField: "Authorization")
        completionHandler(clean)
    }

    private func complete(_ identifier: Int, filename: String?) {
        guard let job = running.removeValue(forKey: identifier) else { return }
        job.completion(job.cancelled ? nil : filename)
        pump()
    }
}
