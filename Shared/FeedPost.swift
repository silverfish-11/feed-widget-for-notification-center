import Foundation

/// One referenced X post, used for a quote or a reply's parent. References are
/// deliberately nonrecursive so each post keeps its own attribution and media.
struct FeedQuotedPost: Codable, Hashable {
    var id: String?
    var author: String
    var handle: String
    var text: String
    var timestamp: Date?
    var media: [FeedMedia]
    var isUnavailable: Bool

    init(id: String? = nil, author: String = "", handle: String = "", text: String = "",
         timestamp: Date? = nil, media: [FeedMedia] = [], isUnavailable: Bool = false) {
        self.id = id
        self.author = author
        self.handle = handle
        self.text = text
        self.timestamp = timestamp
        self.media = media
        self.isUnavailable = isUnavailable
    }

    var url: URL? {
        guard let id, id.range(of: "^[0-9]+$", options: .regularExpression) != nil else { return nil }
        return URL(string: "https://x.com/i/status/\(id)")
    }

    private enum CodingKeys: String, CodingKey { case id, author, handle, text, timestamp, media, isUnavailable }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(String.self, forKey: .id)
        author = try values.decodeIfPresent(String.self, forKey: .author) ?? ""
        handle = try values.decodeIfPresent(String.self, forKey: .handle) ?? ""
        text = try values.decodeIfPresent(String.self, forKey: .text) ?? ""
        timestamp = try values.decodeIfPresent(Date.self, forKey: .timestamp)
        media = try values.decodeIfPresent([FeedMedia].self, forKey: .media) ?? []
        isUnavailable = try values.decodeIfPresent(Bool.self, forKey: .isUnavailable) ?? false
    }
}

/// Reply recipients can be known before the parent post has loaded. Keep this
/// relationship separate from a quote, which can appear in the same reply.
struct FeedReplyContext: Codable, Hashable {
    var handles: [String] = []
    var parent: FeedQuotedPost? = nil

    init(handles: [String] = [], parent: FeedQuotedPost? = nil) {
        self.handles = handles
        self.parent = parent
    }

    private enum CodingKeys: String, CodingKey { case handles, parent }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        handles = try values.decodeIfPresent([String].self, forKey: .handles) ?? []
        parent = try values.decodeIfPresent(FeedQuotedPost.self, forKey: .parent)
    }
}

struct FeedPost: Codable, Identifiable, Hashable {
    let id: String
    let platform: String
    let author: String
    let handle: String
    let text: String
    let timestamp: Date
    let likes: Int
    let reposts: Int
    let comments: Int
    var score: Double
    var media: [FeedMedia]
    var quotedPost: FeedQuotedPost?
    var replyContext: FeedReplyContext?

    var allMedia: [FeedMedia] {
        media + (quotedPost?.isUnavailable == false ? quotedPost?.media ?? [] : []) +
            (replyContext?.parent?.isUnavailable == false ? replyContext?.parent?.media ?? [] : [])
    }

    // Value equality includes content/media so existing UI rows update after hydration.
    // Identity and deduplication use this explicit key instead.
    var stableIdentifier: String { "\(platform):\(id)" }

    var url: URL? {
        switch platform {
        case "x":
            guard id.range(of: "^[0-9]+$", options: .regularExpression) != nil else { return nil }
            return URL(string: "https://x.com/i/status/\(id)")
        case "ig":
            guard !id.hasPrefix("ig_"), !id.hasPrefix("local_"),
                  id.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else { return nil }
            return URL(string: "https://www.instagram.com/p/\(id)/")
        default:
            return nil
        }
    }

    var platformLabel: String { platform == "x" ? "X" : (platform == "ig" ? "IG" : platform.uppercased()) }

    var engagementSummary: String {
        var parts: [String] = []
        if likes > 0 { parts.append("\(formatCount(likes))♥") }
        if reposts > 0 { parts.append("\(formatCount(reposts))↻") }
        if comments > 0 { parts.append("\(formatCount(comments))💬") }
        return parts.joined(separator: " ")
    }

    var hasKnownTimestamp: Bool { timestamp.timeIntervalSince1970 > 0 }

    var timeAgo: String {
        guard hasKnownTimestamp else { return "Date unavailable" }
        let seconds = -timestamp.timeIntervalSinceNow
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        if seconds < 86400 { return "\(Int(seconds / 3600))h" }
        return "\(Int(seconds / 86400))d"
    }

    init(id: String, platform: String, author: String, handle: String, text: String,
         timestamp: Date, likes: Int, reposts: Int, comments: Int, score: Double = 0, media: [FeedMedia] = [],
         quotedPost: FeedQuotedPost? = nil, replyContext: FeedReplyContext? = nil) {
        self.id = id
        self.platform = platform
        self.author = author
        self.handle = handle
        self.text = text
        self.timestamp = timestamp
        self.likes = likes
        self.reposts = reposts
        self.comments = comments
        self.score = score
        self.media = media
        self.quotedPost = quotedPost
        self.replyContext = replyContext
    }

    private enum CodingKeys: String, CodingKey {
        case id, platform, author, handle, text, timestamp, likes, reposts, comments, score, media, quotedPost, replyContext
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        platform = try values.decode(String.self, forKey: .platform)
        author = try values.decode(String.self, forKey: .author)
        handle = try values.decode(String.self, forKey: .handle)
        text = try values.decode(String.self, forKey: .text)
        timestamp = try values.decode(Date.self, forKey: .timestamp)
        likes = try values.decode(Int.self, forKey: .likes)
        reposts = try values.decode(Int.self, forKey: .reposts)
        comments = try values.decode(Int.self, forKey: .comments)
        score = try values.decodeIfPresent(Double.self, forKey: .score) ?? 0
        media = try values.decodeIfPresent([FeedMedia].self, forKey: .media) ?? []
        quotedPost = try values.decodeIfPresent(FeedQuotedPost.self, forKey: .quotedPost)
        replyContext = try values.decodeIfPresent(FeedReplyContext.self, forKey: .replyContext)
    }
}

private func formatCount(_ n: Int) -> String {
    if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
    if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1_000) }
    return "\(n)"
}
