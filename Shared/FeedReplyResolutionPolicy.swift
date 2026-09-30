import Foundation

/// Detail lookups are bounded enrichment, never a replacement for the saved feed.
enum FeedReplyResolutionPolicy {
    static let maximumPerRefresh = 6
    static let retryDelay: TimeInterval = 15 * 60

    static func needsResolution(_ post: FeedPost) -> Bool {
        guard post.platform == "x", post.url != nil, let reply = post.replyContext else { return false }
        guard let parent = reply.parent else { return true }
        guard !parent.isUnavailable else { return false }
        let missingMedia = parent.media.contains { $0.previewRemoteURL == nil && $0.playbackURL == nil && $0.localPreviewFile == nil }
        return missingMedia || (parent.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && parent.media.isEmpty)
    }

    static func shouldFinishReady(firstReadyAt: Date, now: Date, stablePasses: Int,
                                  hasUsableMedia: Bool, isUnavailable: Bool) -> Bool {
        let elapsed = now.timeIntervalSince(firstReadyAt)
        if elapsed >= 15 { return true }
        if isUnavailable { return elapsed >= 3 && stablePasses >= 2 }
        return hasUsableMedia && elapsed >= 8 && stablePasses >= 2
    }

    /// A known target's explicit tombstone may have no recoverable parent ID.
    /// A visible parent requires a distinct numeric identity supplied by the DOM.
    static func acceptsParent(_ parent: [String: Any], targetID: String) -> Bool {
        if let id = parent["id"] as? String {
            return id != targetID && id.range(of: "^[0-9]+$", options: .regularExpression) != nil
        }
        let hasNoID = parent["id"] == nil || parent["id"] is NSNull
        return hasNoID && parent["isUnavailable"] as? Bool == true
    }

    static func candidates(in posts: [FeedPost], attemptedAt: [String: Date], now: Date = Date()) -> [String] {
        var seen = Set<String>()
        return Array(posts.filter { post in
            guard needsResolution(post), seen.insert(post.id).inserted else { return false }
            guard let last = attemptedAt[post.id] else { return true }
            return now.timeIntervalSince(last) >= retryDelay
        }.prefix(maximumPerRefresh).map(\.id))
    }
}
