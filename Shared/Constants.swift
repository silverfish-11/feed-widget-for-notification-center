import Foundation

enum FeedBarConstants {
    // Both signed bundles receive the same resolved build setting in Info.plist.
    // Command-line tests use explicit storage directories and need no App Group.
    static let appGroupID: String? = {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "FeedBarAppGroup") as? String else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains("$("), !value.contains("${") else { return nil }
        return value
    }()
    static let widgetKind = "FeedBarWidget"
    static let pageSize = 3
    static let feedFileName = "feed-v2.json"
    static let pageIndexKey = "feedbar_page_index"
    static let openAppURL = URL(string: "feedbar://open")!
    static let refreshURL = URL(string: "feedbar://refresh")!
}
