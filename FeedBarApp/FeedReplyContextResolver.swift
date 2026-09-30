import Foundation
import WebKit

/// A dedicated browser protects the timeline and sign-in navigation. Owners must
/// attach this browser to their app's view hierarchy and cancel it on suspension.
final class FeedReplyContextResolver: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    private var pending: [String] = []
    private var attemptedAt: [String: Date] = [:]
    private var active: Attempt?
    private var timeoutWork: DispatchWorkItem?
    private var pollWork: DispatchWorkItem?
    private var script: ((String) -> String)?
    private var onResolved: ((String, [String: Any]) -> Void)?

    private struct Attempt {
        let id = UUID()
        let postID: String
        var navigation: WKNavigation?
        var isEvaluating = false
        var candidate: [String: Any]?
        var signature: Data?
        var stablePasses = 0
        var firstReadyAt: Date?
    }

    init(dataStore: WKWebsiteDataStore = .default()) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        #if os(iOS)
        configuration.defaultWebpagePreferences.preferredContentMode = .desktop
        #endif
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        // No UI delegate: detail enrichment never opens authentication popups.
    }

    func start(posts: [FeedPost], script: @escaping (String) -> String,
               onResolved: @escaping (String, [String: Any]) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        cancel()
        let currentIDs = Set(posts.map(\.id))
        attemptedAt = attemptedAt.filter { currentIDs.contains($0.key) }
        pending = FeedReplyResolutionPolicy.candidates(in: posts, attemptedAt: attemptedAt)
        self.script = script
        self.onResolved = onResolved
        runNext()
    }

    func cancel() {
        dispatchPrecondition(condition: .onQueue(.main))
        active = nil // Stop callbacks before stopLoading delivers cancellation.
        timeoutWork?.cancel()
        pollWork?.cancel()
        timeoutWork = nil
        pollWork = nil
        pending.removeAll()
        script = nil
        onResolved = nil
        webView.stopLoading()
        if webView.url != nil { webView.loadHTMLString("", baseURL: nil) }
    }

    private func runNext() {
        guard let postID = pending.first, script != nil else {
            script = nil
            onResolved = nil
            webView.loadHTMLString("", baseURL: nil) // Release the detail page's scripts/media after the bounded batch.
            return
        }
        pending.removeFirst()
        attemptedAt[postID] = Date()
        let attempt = Attempt(postID: postID)
        active = attempt
        let url = URL(string: "https://x.com/i/status/\(postID)")!
        active?.navigation = webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15))
        let work = DispatchWorkItem { [weak self] in self?.finish(attempt.id) }
        timeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: work)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let attempt = active, let expected = attempt.navigation, let navigation, expected === navigation else { return }
        poll(attempt.id)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        navigationFailed(navigation)
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        navigationFailed(navigation)
    }
    private func navigationFailed(_ navigation: WKNavigation?) {
        guard let attempt = active, let expected = attempt.navigation, let navigation, expected === navigation else { return }
        finish(attempt.id)
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if let attempt = active { finish(attempt.id) }
    }

    private func poll(_ id: UUID) {
        guard let attempt = active, attempt.id == id, !attempt.isEvaluating, let script else { return }
        active?.isEvaluating = true
        webView.evaluateJavaScript(script(attempt.postID)) { [weak self] result, error in
            guard let self, var current = self.active, current.id == id else { return }
            current.isEvaluating = false
            self.active = current
            guard error == nil, let string = result as? String, let data = string.data(using: .utf8),
                  let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                self.schedulePoll(id)
                return
            }
            let status = payload["status"] as? String
            if status == "loginRequired" || status == "error" {
                self.cancel() // Keep all saved context; never navigate the user's login view.
                return
            }
            if status == "ready", let posts = payload["posts"] as? [[String: Any]],
               let target = posts.first(where: { $0["id"] as? String == current.postID }),
               let context = target["replyContext"] as? [String: Any],
               let parent = context["parent"] as? [String: Any],
               FeedReplyResolutionPolicy.acceptsParent(parent, targetID: current.postID) {
                let signature = try? JSONSerialization.data(withJSONObject: context, options: [.sortedKeys])
                current.candidate = target
                current.firstReadyAt = current.firstReadyAt ?? Date()
                current.stablePasses = signature == current.signature ? current.stablePasses + 1 : 1
                current.signature = signature
                self.active = current
                let hasMedia = (parent["media"] as? [[String: Any]] ?? []).contains { item in
                    let media = FeedMedia(kind: item["kind"] as? String ?? "image", url: item["url"] as? String,
                                          previewURL: item["previewURL"] as? String)
                    return media.previewRemoteURL != nil || media.playbackURL != nil
                }
                if FeedReplyResolutionPolicy.shouldFinishReady(firstReadyAt: current.firstReadyAt!, now: Date(),
                    stablePasses: current.stablePasses, hasUsableMedia: hasMedia, isUnavailable: parent["isUnavailable"] as? Bool == true) {
                    self.finish(id)
                    return
                }
            }
            self.schedulePoll(id)
        }
    }

    private func schedulePoll(_ id: UUID) {
        let work = DispatchWorkItem { [weak self] in self?.poll(id) }
        pollWork?.cancel()
        pollWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    private func finish(_ id: UUID) {
        guard let attempt = active, attempt.id == id else { return }
        active = nil
        timeoutWork?.cancel()
        pollWork?.cancel()
        timeoutWork = nil
        pollWork = nil
        webView.stopLoading()
        if let candidate = attempt.candidate { onResolved?(attempt.postID, candidate) }
        runNext()
    }
}
