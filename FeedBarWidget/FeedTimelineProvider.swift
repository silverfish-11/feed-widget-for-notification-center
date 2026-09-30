import WidgetKit
import SwiftUI
import os

struct FeedEntry: TimelineEntry {
    let date: Date
    let posts: [FeedPost]
    let page: Int
    let totalPages: Int
    let pageSize: Int
    let snapshot: FeedSnapshot
    let errorMessage: String?
    let preferences: WidgetPreferences

    init(date: Date, posts: [FeedPost], page: Int, totalPages: Int, pageSize: Int,
         snapshot: FeedSnapshot, errorMessage: String?, preferences: WidgetPreferences = .init()) {
        self.date = date
        self.posts = posts
        self.page = page
        self.totalPages = totalPages
        self.pageSize = pageSize
        self.snapshot = snapshot
        self.errorMessage = errorMessage
        self.preferences = preferences
    }
}

enum FeedWidgetLayout {
    static func pageSize(for family: WidgetFamily, preferences: WidgetPreferences = .init()) -> Int {
        if preferences.showsMedia && preferences.mediaSize == .large {
            return family == .systemExtraLarge ? 2 : 1
        }
        switch family {
        case .systemSmall: return 1
        case .systemMedium: return 1
        case .systemExtraLarge: return preferences.density == .compact ? 6 : 4
        default: return preferences.density == .compact && preferences.textSize != .large ? 3 : 2
        }
    }

    static func bodyFontSize(for family: WidgetFamily, preferences: WidgetPreferences) -> CGFloat {
        let base: CGFloat = family == .systemSmall || family == .systemMedium ? 11 : 12
        return base + (preferences.textSize == .large ? 2 : preferences.textSize == .small ? -1 : 0)
    }

    static func authorFontSize(preferences: WidgetPreferences) -> CGFloat {
        preferences.textSize == .large ? 13 : preferences.textSize == .small ? 10 : 11
    }

    static func textLines(for family: WidgetFamily, preferences: WidgetPreferences,
                          hasMedia: Bool, hasError: Bool) -> Int {
        if preferences.showsMedia && preferences.mediaSize == .large && hasMedia {
            if family == .systemSmall { return 0 }
            if family != .systemMedium { return 2 }
        }
        switch family {
        case .systemSmall:
            return hasMedia ? 1 : (hasError ? 3 : 4)
        case .systemMedium:
            return hasError ? 2 : (hasMedia || preferences.textSize == .large ? 3 : 4)
        default:
            if preferences.density == .compact && pageSize(for: family, preferences: preferences) > 2 {
                return preferences.textSize == .large ? 2 : 3
            }
            return preferences.textSize == .large ? 4 : 5
        }
    }
}

struct FeedTimelineProvider: TimelineProvider {
    private static let logger = Logger(subsystem: "com.feedbar.app.widget", category: "timeline")

    private static func safeErrorCode(_ error: Error) -> String {
        var underlying = error
        if let storeError = error as? FeedStoreError {
            switch storeError {
            case .readFailed(_, let cause), .writeFailed(_, let cause):
                underlying = cause
            default:
                break
            }
        }
        let nsError = underlying as NSError
        return "\(nsError.domain):\(nsError.code)"
    }

    func placeholder(in context: Context) -> FeedEntry {
        FeedEntry(date: .now, posts: [], page: 0, totalPages: 1,
                  pageSize: FeedWidgetLayout.pageSize(for: context.family),
                  snapshot: FeedSnapshot(), errorMessage: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (FeedEntry) -> Void) {
        completion(makeEntry(family: context.family))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<FeedEntry>) -> Void) {
        let entry = makeEntry(family: context.family)
        // Collection belongs to the host app. The timeline only rereads the saved snapshot.
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(15 * 60))))
    }

    private func makeEntry(family: WidgetFamily) -> FeedEntry {
        var preferences = WidgetPreferences()
        var preferencesError: String?
        do { preferences = try WidgetPreferences.load() }
        catch {
            preferencesError = "Preferences could not be read. Open Settings."
            Self.logger.error("Widget preferences read failed: \(Self.safeErrorCode(error), privacy: .public)")
        }
        let pageSize = FeedWidgetLayout.pageSize(for: family, preferences: preferences)
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        do {
            let snapshot = try FeedStore.load()
            let allPosts = snapshot.posts
            let knownStatuses = ["idle", "loading", "ready", "loginRequired", "error"]
            let states = ["x", "ig"].map { key in
                let state = snapshot.sources[key]?.status ?? "idle"
                return "\(key)=\(knownStatuses.contains(state) ? state : "unknown")"
            }.joined(separator: ",")
            let attachments = allPosts.flatMap(\.media)
            let cachedPreviews = attachments.filter { FeedMediaCache.imageURL(for: $0) != nil }.count
            Self.logger.notice("makeEntry build=\(build, privacy: .public) posts=\(allPosts.count) attachments=\(attachments.count) cachedPreviews=\(cachedPreviews) sources=\(states, privacy: .public)")
            var paginationError: String?
            let savedPage: Int
            do {
                savedPage = try PageState.page(pageSize: pageSize)
            } catch {
                savedPage = 0
                paginationError = "Page selection could not be read. Open FeedBar."
                Self.logger.error("Page state read failed: \(Self.safeErrorCode(error), privacy: .public)")
            }
            let page = FeedPagination.clampedPage(savedPage, totalPosts: allPosts.count, pageSize: pageSize)
            return FeedEntry(date: .now,
                             posts: FeedPagination.posts(allPosts, page: page, pageSize: pageSize),
                             page: page,
                             totalPages: FeedPagination.pageCount(totalPosts: allPosts.count, pageSize: pageSize),
                             pageSize: pageSize, snapshot: snapshot, errorMessage: paginationError ?? preferencesError,
                             preferences: preferences)
        } catch {
            Self.logger.error("makeEntry build=\(build, privacy: .public) store read failed: \(Self.safeErrorCode(error), privacy: .public)")
            return FeedEntry(date: .now, posts: [], page: 0, totalPages: 1, pageSize: pageSize,
                             snapshot: FeedSnapshot(), errorMessage: error.localizedDescription, preferences: preferences)
        }
    }
}
