import Foundation

struct FeedSourceState: Codable {
    var posts: [FeedPost] = []
    var status: String = "idle"
    var message: String = ""
    var lastAttempt: Date? = nil
    var lastSuccess: Date? = nil
}

struct FeedSnapshot: Codable {
    var sources: [String: FeedSourceState] = [:]
    var updatedAt: Date = Date()

    /// Keep source caches independent; equal post IDs on different services are distinct.
    var posts: [FeedPost] {
        var unique: [String: FeedPost] = [:]
        for source in sources.keys.sorted() {
            for post in sources[source]?.posts ?? [] {
                if let existing = unique[post.stableIdentifier], existing.timestamp >= post.timestamp {
                    continue
                }
                unique[post.stableIdentifier] = post
            }
        }
        return unique.values.sorted {
            if $0.timestamp != $1.timestamp { return $0.timestamp > $1.timestamp }
            return $0.stableIdentifier < $1.stableIdentifier
        }
    }

    var lastSuccess: Date? {
        sources.values.compactMap(\.lastSuccess).max()
    }
}

enum FeedTimestamp {
    /// A timestamp without fractional seconds is valid ISO 8601 too. Invalid input stays unknown.
    static func parse(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}
