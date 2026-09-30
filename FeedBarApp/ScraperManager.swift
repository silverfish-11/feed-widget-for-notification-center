import Cocoa
import WebKit
import WidgetKit
import os

/// All state and WebKit callbacks live on the main thread. Each source gets one
/// navigation + bounded extraction attempt at a time; stale callbacks are ignored.
final class ScraperManager: NSObject, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate {
    var onUpdate: (() -> Void)?
    private(set) var snapshot: FeedSnapshot
    private(set) var storageError: String?
    private var webViews: [String: WKWebView] = [:]
    private var hostWindows: [String: NSWindow] = [:]
    private var loginWindow: NSPanel?
    private var loginKey: String?
    private var authenticationWindows: [NSWindow] = []
    private var authenticationSources: [ObjectIdentifier: String] = [:]
    private let settings: FeedSettings
    private lazy var refreshScheduler = FeedRefreshScheduler(settings: settings) { [weak self] in
        self?.scrapeAll()
    }
    private var timeoutWork: DispatchWorkItem?
    private var pollWork: DispatchWorkItem?
    private var pendingSources: [String] = []
    private var isRefreshing = false
    private var refreshRequested = false
    private var stopped = false
    private var active: Attempt?
    private var sourceGenerations: [String: UUID] = [:]
    private let mediaDownloader = MediaPreviewDownloader()
    private var mediaPublishWork: DispatchWorkItem?
    private let logger = Logger(subsystem: "com.feedbar.app", category: "scraper")
    private let sourceKeys = ["x", "ig"]
    private let feedURLs = ["x": URL(string: "https://x.com/home")!,
                            "ig": URL(string: "https://www.instagram.com/?variant=following")!]

    private struct Attempt {
        let id: UUID
        let key: String
        var navigation: WKNavigation?
        var navigationGeneration = UUID()
        let startedAt = Date()
        var navigationStartedAt = Date()
        var isLoading = true
        var isEvaluating = false
        var retryCount = 0
        var lastMessage = "The page did not finish loading."
        var firstReadyAt: Date?
        var latestReadyPosts: [FeedPost]?
        var readySignature: Int?
        var stableReadyPasses = 0
        var lastDiagnostics: String?
    }

    init(settings: FeedSettings = FeedSettings()) {
        self.settings = settings
        do {
            snapshot = try FeedStore.load()
        } catch {
            snapshot = FeedSnapshot()
            storageError = "Saved feed could not be read."
        }
        super.init()
        for key in sourceKeys {
            var state = snapshot.sources[key] ?? FeedSourceState()
            if state.status == "loading" {
                state.status = "error"
                state.message = "The previous refresh was interrupted. Refresh to retry."
            }
            snapshot.sources[key] = state
            makeWebView(key: key)
        }
    }

    private func makeWebView(key: String) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 900), configuration: configuration)
        // Use WebKit's native desktop user agent rather than an old mobile spoof.
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.autoresizingMask = [.width, .height]
        let window = NSWindow(contentRect: NSRect(x: -12000, y: -12000, width: 900, height: 900),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.stationary, .ignoresCycle]
        window.contentView = webView
        window.orderBack(nil)
        webViews[key] = webView
        hostWindows[key] = window
    }

    func startTimer() {
        dispatchPrecondition(condition: .onQueue(.main))
        stopped = false
        refreshScheduler.start()
    }

    /// Apply a new interval without disturbing an in-flight collection or
    /// triggering an extra immediate refresh.
    func rescheduleTimer() {
        dispatchPrecondition(condition: .onQueue(.main))
        refreshScheduler.reschedule()
    }

    func stop() {
        stopped = true
        sourceGenerations.removeAll()
        mediaDownloader.cancel()
        mediaPublishWork?.cancel()
        refreshScheduler.stop()
        timeoutWork?.cancel()
        pollWork?.cancel()
        active = nil
        pendingSources.removeAll()
        isRefreshing = false
        refreshRequested = false
        webViews.values.forEach { $0.stopLoading() }
    }

    /// A refresh really reloads the feed pages, then waits for asynchronous DOM rendering.
    func scrapeAll() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !stopped else { return }
        guard !isRefreshing else { refreshRequested = true; return }
        isRefreshing = true
        pendingSources = Self.availableSources(sourceKeys, loginKey: loginKey, popupSources: Array(authenticationSources.values))
        runNextSource()
    }

    private func runNextSource() {
        guard !stopped else { return }
        while let key = pendingSources.first {
            pendingSources.removeFirst()
            if sourceIsInUse(key) { continue }
            startSource(key)
            return
        }
        isRefreshing = false
        if refreshRequested {
            refreshRequested = false
            scrapeAll()
        }
    }

    private func startSource(_ key: String) {
        guard webViews[key] != nil, feedURLs[key] != nil else { runNextSource(); return }
        let id = UUID()
        sourceGenerations[key] = id
        mediaDownloader.cancel(source: key)
        logger.info("Refresh started source=\(key, privacy: .public)")
        active = Attempt(id: id, key: key)
        updateState(key) { state in
            state.status = "loading"
            state.message = "Refreshing feed…"
            state.lastAttempt = Date()
        }
        beginNavigation(id)
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, let attempt = self.active, attempt.id == id else { return }
            if let posts = attempt.latestReadyPosts {
                self.logger.info("Settling deadline source=\(attempt.key, privacy: .public) keepingPosts=\(posts.count)")
                self.finish(id, status: "ready", message: posts.isEmpty ? "No posts in this feed yet." : "\(posts.count) posts saved", posts: posts)
            } else {
                self.logger.error("Refresh timeout source=\(attempt.key, privacy: .public)")
                self.finish(id, status: "error", message: attempt.lastMessage + " Open login to check the page, then retry.")
            }
        }
        timeoutWork = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 50, execute: timeout)
    }

    private func beginNavigation(_ id: UUID) {
        guard var attempt = active, attempt.id == id, !stopped, !sourceIsInUse(attempt.key),
              let webView = webViews[attempt.key], let url = feedURLs[attempt.key] else { return }
        attempt.navigation = nil
        attempt.navigationGeneration = UUID()
        attempt.navigationStartedAt = Date()
        attempt.isLoading = true
        attempt.isEvaluating = false
        active = attempt // Old navigation callbacks cannot match after this point.
        webView.stopLoading()
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 35)
        active?.navigation = webView.load(request)
    }

    private func sourceIsInUse(_ key: String) -> Bool {
        !Self.availableSources([key], loginKey: loginKey, popupSources: Array(authenticationSources.values)).contains(key)
    }

    private func poll(_ id: UUID) {
        guard let attempt = active, attempt.id == id, !stopped, !sourceIsInUse(attempt.key),
              !attempt.isLoading, !attempt.isEvaluating,
              let webView = webViews[attempt.key] else { return }
        active?.isEvaluating = true
        let navigationGeneration = attempt.navigationGeneration
        let script = attempt.key == "x" ? JSScripts.xExtraction : JSScripts.igExtraction
        webView.evaluateJavaScript(script) { [weak self] result, error in
            guard let self, !self.stopped, let current = self.active, current.id == id,
                  current.navigationGeneration == navigationGeneration else { return }
            self.active?.isEvaluating = false
            guard error == nil, let string = result as? String,
                  let data = string.data(using: .utf8),
                  let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let status = payload["status"] as? String else {
                self.active?.lastMessage = "The page could not be read."
                self.schedulePoll(id)
                return
            }
            if let counts = payload["diagnostics"] as? [String: Any] {
                let fields = ["articles", "images", "loadedImages", "videos", "attachments", "quotes", "quoteAttachments"].map { name in
                    "\(name)=\(max(0, min(100_000, counts[name] as? Int ?? 0)))"
                }.joined(separator: " ")
                if fields != self.active?.lastDiagnostics {
                    self.logger.info("DOM source=\(current.key, privacy: .public) \(fields, privacy: .public)")
                    self.active?.lastDiagnostics = fields
                }
            }
            let message = payload["message"] as? String ?? "The feed has not rendered yet."
            if status == "loginRequired" || status == "error" {
                self.handleFailure(id, status: status, message: message,
                                   errorKind: payload["errorKind"] as? String, canPoll: true)
                return
            }
            if status == "ready", let raw = payload["posts"] as? [[String: Any]] {
                let previous = self.snapshot.sources[current.key]?.posts ?? []
                // Keep media already observed in this attempt if a later virtualized
                // DOM pass temporarily drops an attachment or carousel slide.
                let priorByID = Dictionary((previous + (current.latestReadyPosts ?? [])).map { ($0.id, $0) },
                                           uniquingKeysWith: { _, latest in latest })
                var seen = Set<String>()
                let posts = raw.compactMap { item -> FeedPost? in
                    let prior = (item["id"] as? String).flatMap { priorByID[$0] }
                    guard let post = Self.parsePost(item, platform: current.key, previous: prior),
                          seen.insert(post.id).inserted else { return nil }
                    return post
                }.sorted { $0.timestamp == $1.timestamp ? $0.id < $1.id : $0.timestamp > $1.timestamp }
                // A selector failure must not erase the last good feed.
                if !posts.isEmpty || (raw.isEmpty && payload["emptyConfirmed"] as? Bool == true) {
                    let hash = Self.readySignature(for: posts)
                    guard var settled = self.active, settled.id == id else { return }
                    settled.firstReadyAt = settled.firstReadyAt ?? Date()
                    settled.latestReadyPosts = posts
                    settled.stableReadyPasses = settled.readySignature == hash ? settled.stableReadyPasses + 1 : 1
                    settled.readySignature = hash
                    self.active = settled
                    if let firstReady = settled.firstReadyAt,
                       Self.shouldFinishReady(firstReadyAt: firstReady, now: Date(), stablePasses: settled.stableReadyPasses, posts: posts) {
                        self.finish(id, status: "ready", message: posts.isEmpty ? "No posts in this feed yet." : "\(posts.count) posts saved", posts: posts)
                    } else {
                        self.active?.lastMessage = "Waiting for captions and media to finish loading."
                        self.schedulePoll(id)
                    }
                    return
                }
            }
            self.active?.lastMessage = message
            self.schedulePoll(id)
        }
    }

    private func handleFailure(_ id: UUID, status: String = "error", message: String,
                               errorKind: String?, canPoll: Bool) {
        guard let attempt = active, attempt.id == id, !stopped else { return }
        active?.lastMessage = message
        // A temporary replacement of a loaded DOM must not throw away valid data;
        // the original deadline will commit the last readable candidate.
        if status == "error", errorKind == "transient", canPoll, attempt.latestReadyPosts != nil {
            schedulePoll(id)
            return
        }
        let action = Self.recoveryAction(status: status, errorKind: errorKind, retries: attempt.retryCount,
                                         navigationAge: Date().timeIntervalSince(attempt.navigationStartedAt),
                                         remaining: 50 - Date().timeIntervalSince(attempt.startedAt), canPoll: canPoll)
        switch action {
        case .wait:
            schedulePoll(id)
        case .reload:
            guard var retry = active, retry.id == id else { return }
            retry.retryCount += 1
            retry.navigation = nil
            retry.navigationGeneration = UUID()
            retry.isLoading = true
            retry.isEvaluating = false
            active = retry
            pollWork?.cancel()
            webViews[retry.key]?.stopLoading()
            updateState(retry.key) { state in
                state.status = "loading"
                state.message = "The site had a temporary error. Retrying once…"
            }
            logger.info("Transient recovery source=\(retry.key, privacy: .public) retry=\(retry.retryCount)")
            let generation = retry.navigationGeneration
            let work = DispatchWorkItem { [weak self] in
                guard let self, !self.stopped, let current = self.active, current.id == id,
                      current.navigationGeneration == generation, !self.sourceIsInUse(current.key) else { return }
                self.beginNavigation(id)
            }
            pollWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
        case .stop:
            finish(id, status: status, message: message)
        }
    }

    private func schedulePoll(_ id: UUID) {
        guard let attempt = active, attempt.id == id else { return }
        let generation = attempt.navigationGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.active?.navigationGeneration == generation else { return }
            self.poll(id)
        }
        pollWork?.cancel()
        pollWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    private func finish(_ id: UUID, status: String, message: String, posts: [FeedPost]? = nil) {
        guard let attempt = active, attempt.id == id else { return }
        active = nil // Invalidate first: stopLoading may cause a navigation callback.
        timeoutWork?.cancel()
        pollWork?.cancel()
        timeoutWork = nil
        pollWork = nil
        // Successful DOM extraction is not the end of the page's media requests.
        if status != "ready" { webViews[attempt.key]?.stopLoading() }
        let mediaCount = posts?.reduce(0) { $0 + $1.allMedia.count } ?? 0
        let previewCount = posts?.flatMap(\.allMedia).filter { $0.previewRemoteURL != nil }.count ?? 0
        let quoteCount = posts?.filter { $0.quotedPost != nil }.count ?? 0
        logger.info("Refresh finished source=\(attempt.key, privacy: .public) status=\(status, privacy: .public) count=\(posts?.count ?? -1) quotes=\(quoteCount) attachments=\(mediaCount) previews=\(previewCount)")
        updateState(attempt.key) { state in
            state = Self.applyingResult(to: state, status: status, message: message, posts: posts)
        }
        if status == "ready", let posts { cacheMedia(in: posts, source: attempt.key, generation: id) }
        runNextSource()
    }

    private func cacheMedia(in posts: [FeedPost], source: String, generation: UUID) {
        // Feed metadata is already saved. Image failures cannot stall that refresh.
        var requested = Set<String>()
        let downloads = Array(posts.flatMap(\.allMedia).filter {
            FeedMediaCache.imageURL(for: $0) == nil && requested.insert($0.cacheKey).inserted
        }.prefix(48))
        var remaining = downloads.count
        var completed = 0
        var changedSinceCheckpoint = false
        for media in downloads {
            mediaDownloader.enqueue(media, source: source) { [weak self] filename in
                guard let self, !self.stopped, self.sourceGenerations[source] == generation else { return }
                remaining -= 1
                completed += 1
                if let filename, var state = self.snapshot.sources[source] {
                    let changed = Self.applyCachedPreview(filename, for: media.cacheKey, to: &state.posts)
                    changedSinceCheckpoint = changedSinceCheckpoint || changed
                    self.snapshot.sources[source] = state
                    self.onUpdate?() // Native UI may display each image as it arrives.
                }
                // At most four media checkpoints per 48-image source batch, with
                // nearby checkpoints coalesced into a single atomic save/reload.
                guard changedSinceCheckpoint, completed == 1 || completed % 16 == 0 || remaining == 0 else { return }
                changedSinceCheckpoint = false
                self.mediaPublishWork?.cancel()
                let work = DispatchWorkItem { [weak self] in self?.persistSnapshot() }
                self.mediaPublishWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
            }
        }
    }

    private func updateState(_ key: String, change: (inout FeedSourceState) -> Void) {
        var state = snapshot.sources[key] ?? FeedSourceState()
        change(&state)
        snapshot.sources[key] = state
        persistSnapshot()
    }

    private func persistSnapshot() {
        snapshot.updatedAt = Date()
        do {
            try FeedStore.save(snapshot)
            storageError = nil
            WidgetCenter.shared.reloadTimelines(ofKind: FeedBarConstants.widgetKind)
        } catch {
            let failure = error as NSError
            logger.error("Feed save failed domain=\(failure.domain, privacy: .public) code=\(failure.code)")
            storageError = "Refreshed feed could not be saved for the widget. Refresh to retry."
        }
        onUpdate?()
    }

    // MARK: Navigation lifecycle

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !stopped, let attempt = active, webViews[attempt.key] === webView,
              let expectedNavigation = attempt.navigation, let navigation,
              expectedNavigation === navigation else { return }
        active?.isLoading = false
        poll(attempt.id)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        navigationFailed(webView, navigation: navigation, error: error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        navigationFailed(webView, navigation: navigation, error: error)
    }

    private func navigationFailed(_ webView: WKWebView, navigation: WKNavigation?, error: Error) {
        guard !stopped, let attempt = active, webViews[attempt.key] === webView,
              let expectedNavigation = attempt.navigation, let navigation,
              expectedNavigation === navigation else { return }
        let nsError = error as NSError
        logger.error("Navigation failed source=\(attempt.key, privacy: .public) domain=\(nsError.domain, privacy: .public) code=\(nsError.code)")
        let message = nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorNotConnectedToInternet
            ? "No internet connection. Your saved posts are still available."
            : "The feed page could not load. Your saved posts are still available."
        handleFailure(attempt.id, message: message,
                      errorKind: Self.isTransientNavigationError(nsError) ? "transient" : nil, canPoll: false)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard !stopped else { return }
        if let attempt = active, webViews[attempt.key] === webView {
            handleFailure(attempt.id, message: "The feed's browser process stopped. Refresh to retry.",
                          errorKind: "transient", canPoll: false)
        } else if let key = sourceKeys.first(where: { webViews[$0] === webView }) {
            updateState(key) { state in
                state.status = "error"
                state.message = "The feed's browser process stopped. Refresh to retry."
            }
        }
    }

    // MARK: Login uses the same persistent WebView / session

    func showLogin(key: String, title: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let webView = webViews[key] else { return }
        if loginKey == key { loginWindow?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        loginWindow?.close()
        loginKey = key // Set before cancellation so the next source won't start this one.
        if let attempt = active, attempt.key == key {
            finish(attempt.id, status: "loginRequired", message: "Finish signing in, then close the login window.")
        }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 900, height: 800),
                            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.title = title
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        webView.removeFromSuperview()
        panel.contentView = webView
        loginWindow = panel
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // Reload the existing page without replacing the persistent website store.
        if webView.url == nil { webView.load(URLRequest(url: feedURLs[key]!)) }
        else { webView.reload() }
        updateState(key) { state in
            state.status = "loginRequired"
            state.message = "Finish signing in, then close the login window."
        }
    }

    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow,
           let index = authenticationWindows.firstIndex(where: { $0 === window }) {
            let source = authenticationSources.removeValue(forKey: ObjectIdentifier(window))
            authenticationWindows.remove(at: index)
            if let source, !sourceIsInUse(source) {
                DispatchQueue.main.async { [weak self] in self?.scrapeAll() }
            }
            return
        }
        guard let window = notification.object as? NSWindow, window === loginWindow,
              let key = loginKey, let webView = webViews[key] else { return }
        webView.removeFromSuperview()
        hostWindows[key]?.contentView = webView
        webView.frame = NSRect(x: 0, y: 0, width: 900, height: 900)
        loginWindow = nil
        loginKey = nil
        if !sourceIsInUse(key) {
            DispatchQueue.main.async { [weak self] in self?.scrapeAll() }
        }
    }

    // Google/Apple sign-in can open a separate window. Keeping WebKit's supplied
    // configuration preserves the opener/session handshake instead of dropping it.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard navigationAction.targetFrame == nil, let openerWindow = webView.window else { return nil }
        let source = openerWindow === loginWindow ? loginKey : authenticationSources[ObjectIdentifier(openerWindow)]
        guard let source else { return nil }
        let popup = WKWebView(frame: NSRect(x: 0, y: 0, width: 620, height: 760), configuration: configuration)
        popup.uiDelegate = self
        popup.autoresizingMask = [.width, .height]
        let window = NSPanel(contentRect: popup.frame, styleMask: [.titled, .closable, .resizable],
                             backing: .buffered, defer: false)
        window.title = "Sign in — FeedBar"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = popup
        authenticationWindows.append(window)
        authenticationSources[ObjectIdentifier(window)] = source
        window.center()
        window.makeKeyAndOrderFront(nil)
        return popup
    }

    func webViewDidClose(_ webView: WKWebView) {
        if let window = authenticationWindows.first(where: { $0.contentView === webView }) { window.close() }
    }

    enum RecoveryAction: Equatable { case wait, reload, stop }

    /// A single source attempt keeps its original 50-second budget across retries.
    static func recoveryAction(status: String, errorKind: String?, retries: Int,
                               navigationAge: TimeInterval, remaining: TimeInterval, canPoll: Bool) -> RecoveryAction {
        guard status == "error", errorKind == "transient", remaining > 2 else { return .stop }
        if canPoll && navigationAge < 5 { return .wait }
        return retries == 0 && remaining >= 8 ? .reload : .stop
    }

    static func isTransientNavigationError(_ error: NSError) -> Bool {
        error.domain == NSURLErrorDomain && [NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost,
            NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost, NSURLErrorDNSLookupFailed].contains(error.code)
    }

    static func availableSources(_ sources: [String], loginKey: String?, popupSources: [String]) -> [String] {
        sources.filter { $0 != loginKey && !popupSources.contains($0) }
    }

    /// Text appears before deferred captions/media on both sites. Require repeated
    /// stable content, and allow more time when no usable media has hydrated yet.
    /// A real text-only feed still commits within fifteen seconds of first data.
    static func shouldFinishReady(firstReadyAt: Date, now: Date, stablePasses: Int, posts: [FeedPost]) -> Bool {
        let elapsed = now.timeIntervalSince(firstReadyAt)
        if elapsed >= 15 { return true }
        let hasUsableMedia = posts.flatMap(\.allMedia).contains { $0.previewRemoteURL != nil || $0.playbackURL != nil }
        return hasUsableMedia && elapsed >= 8 && stablePasses >= 2
    }

    static func readySignature(for posts: [FeedPost]) -> Int {
        var signature = Hasher()
        for post in posts {
            signature.combine(post.id)
            signature.combine(post.text) // Compare privately; never log post contents.
            signature.combine(post.quotedPost)
            for media in post.media {
                signature.combine(media.cacheKey)
                signature.combine(media.url)
                signature.combine(media.previewURL)
            }
        }
        return signature.finalize()
    }

    /// Patch only matching current attachments after the caller checks the source
    /// generation. A removed/unavailable quote cannot be recreated by a callback.
    @discardableResult
    static func applyCachedPreview(_ filename: String, for cacheKey: String, to posts: inout [FeedPost]) -> Bool {
        var changed = false
        for index in posts.indices {
            for attachment in posts[index].media.indices where posts[index].media[attachment].cacheKey == cacheKey {
                guard posts[index].media[attachment].localPreviewFile != filename else { continue }
                posts[index].media[attachment].localPreviewFile = filename
                changed = true
            }
            if var quote = posts[index].quotedPost, !quote.isUnavailable {
                for attachment in quote.media.indices where quote.media[attachment].cacheKey == cacheKey {
                    guard quote.media[attachment].localPreviewFile != filename else { continue }
                    quote.media[attachment].localPreviewFile = filename
                    changed = true
                }
                posts[index].quotedPost = quote
            }
        }
        return changed
    }

    /// A failed source only changes its status; its last successful content survives.
    static func applyingResult(to previous: FeedSourceState, status: String, message: String,
                               posts: [FeedPost]?, now: Date = Date()) -> FeedSourceState {
        var state = previous
        state.status = status
        state.message = message
        if status == "ready", let posts {
            state.posts = posts
            state.lastSuccess = now
        }
        return state
    }

    static func parsePost(_ dict: [String: Any], platform: String, previous: FeedPost? = nil) -> FeedPost? {
        guard let id = dict["id"] as? String,
              id.range(of: platform == "x" ? "^[0-9]+$" : "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else { return nil }
        let previous = previous?.id == id && previous?.platform == platform ? previous : nil
        let text = dict["text"] as? String ?? ""
        var quote = platform == "x" ? parseQuotedPost(dict["quotedPost"], previous: previous?.quotedPost) : nil
        if var identified = quote, !identified.isUnavailable {
            let legacyMedia = Dictionary((previous?.media ?? []).map { ($0.cacheKey, $0) }, uniquingKeysWith: { a, _ in a })
            for index in identified.media.indices where identified.media[index].localPreviewFile == nil {
                identified.media[index].localPreviewFile = legacyMedia[identified.media[index].cacheKey]?.localPreviewFile
            }
            quote = identified
        }
        let quoteKeys = Set((quote?.media ?? []).map(\.cacheKey) + (previous?.quotedPost?.media ?? []).map(\.cacheKey))
        // Older collectors flattened quoted attachments into the outer post.
        // Quote media can hydrate after its metadata, so remove inherited overlap
        // on every pass. Explicit current parent attachments still win below.
        let priorMedia = (previous?.media ?? []).filter { !quoteKeys.contains($0.cacheKey) }
        let media = parseMedia(dict["media"], previous: priorMedia)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !media.isEmpty || quote != nil else { return nil }
        // No fabricated freshness: unknown dates stay unknown and sort to the end.
        let newlyIdentifiedQuoteDate = quote?.timestamp != nil && previous?.quotedPost?.timestamp == nil
        let priorDate = newlyIdentifiedQuoteDate && previous?.timestamp == quote?.timestamp ? nil : previous?.timestamp
        let date = parseTimestamp(dict["timestamp"]) ?? priorDate ?? .distantPast
        return FeedPost(id: id, platform: platform,
                        author: dict["author"] as? String ?? "",
                        handle: dict["handle"] as? String ?? "",
                        text: text, timestamp: date,
                        likes: max(0, dict["likes"] as? Int ?? 0),
                        reposts: max(0, dict["reposts"] as? Int ?? 0),
                        comments: max(0, dict["comments"] as? Int ?? 0), media: media, quotedPost: quote)
    }

    private static func parseMedia(_ raw: Any?, previous: [FeedMedia]) -> [FeedMedia] {
        let previousMedia = Dictionary(previous.map { ($0.cacheKey, $0) }, uniquingKeysWith: { a, _ in a })
        var mediaKeys = Set<String>()
        var media = (raw as? [[String: Any]] ?? []).prefix(12).compactMap { item -> FeedMedia? in
            guard let kind = item["kind"] as? String, kind == "image" || kind == "video" else { return nil }
            let url = FeedMedia.remoteURL(item["url"] as? String)?.absoluteString
            let preview = FeedMedia.remoteURL(item["previewURL"] as? String)?.absoluteString
            guard kind == "video" || url != nil || preview != nil else { return nil }
            var attachment = FeedMedia(kind: kind, url: url, previewURL: preview,
                                       altText: item["altText"] as? String ?? "",
                                       width: (item["width"] as? Int).flatMap { $0 > 0 && $0 < 100_000 ? $0 : nil },
                                       height: (item["height"] as? Int).flatMap { $0 > 0 && $0 < 100_000 ? $0 : nil })
            guard mediaKeys.insert(attachment.cacheKey).inserted else { return nil }
            attachment.localPreviewFile = previousMedia[attachment.cacheKey]?.localPreviewFile
            return attachment
        }
        if !previous.isEmpty {
            let hasUsableMedia = media.contains { $0.previewRemoteURL != nil || $0.playbackURL != nil }
            if !hasUsableMedia {
                // A hydration miss must not erase this post's last observed media.
                media = previous
            } else if media.count < previous.count,
                      Set(media.map(\.cacheKey)).isSubset(of: Set(previous.map(\.cacheKey))) {
                let fresh = Dictionary(media.map { ($0.cacheKey, $0) }, uniquingKeysWith: { a, _ in a })
                media = previous.map { fresh[$0.cacheKey] ?? $0 }
            }
        }
        return media
    }

    private static func parseQuotedPost(_ raw: Any?, previous: FeedQuotedPost?) -> FeedQuotedPost? {
        guard let dict = raw as? [String: Any] else { return previous }
        let id = (dict["id"] as? String).flatMap {
            $0.range(of: "^[0-9]+$", options: .regularExpression) != nil ? $0 : nil
        }
        // Never borrow text, attribution or cached media from a different quote.
        let sameQuote = (id != nil && previous?.id != nil && id != previous?.id) ? nil : previous
        if dict["isUnavailable"] as? Bool == true {
            return FeedQuotedPost(id: id ?? sameQuote?.id, isUnavailable: true)
        }
        let prior = sameQuote?.isUnavailable == false ? sameQuote : nil
        func text(_ key: String, fallback: String = "") -> String {
            let value = dict[key] as? String ?? ""
            return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallback : value
        }
        let quote = FeedQuotedPost(id: id ?? sameQuote?.id,
                                   author: text("author", fallback: prior?.author ?? ""),
                                   handle: text("handle", fallback: prior?.handle ?? ""),
                                   text: text("text", fallback: prior?.text ?? ""),
                                   timestamp: parseTimestamp(dict["timestamp"]) ?? prior?.timestamp,
                                   media: parseMedia(dict["media"], previous: prior?.media ?? []))
        let hasContent = !quote.text.isEmpty || !quote.media.isEmpty || !quote.author.isEmpty || !quote.handle.isEmpty
        // An empty hydration pass after an explicit tombstone must stay unavailable.
        if !hasContent, sameQuote?.isUnavailable == true { return sameQuote }
        return hasContent || quote.id != nil ? quote : nil
    }

    private static func parseTimestamp(_ raw: Any?) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let raw = raw as? String
        var timestamp = raw.flatMap { iso.date(from: $0) }
        if timestamp == nil {
            iso.formatOptions = [.withInternetDateTime]
            timestamp = raw.flatMap { iso.date(from: $0) }
        }
        return timestamp
    }
}
