import AppIntents
import WidgetKit

struct NextPageIntent: AppIntent {
    static var title: LocalizedStringResource = "Next feed page"
    static var description = IntentDescription("Show the next page of saved posts.")

    @Parameter(title: "Posts per page") var pageSize: Int

    init() { pageSize = FeedBarConstants.pageSize }
    init(pageSize: Int) { self.pageSize = pageSize }

    func perform() async throws -> some IntentResult {
        let posts = try FeedStore.load().posts
        let size = min(max(pageSize, 1), 6)
        try PageState.advance(by: 1, totalPosts: posts.count, pageSize: size)
        WidgetCenter.shared.reloadTimelines(ofKind: FeedBarConstants.widgetKind)
        return .result()
    }
}

struct PreviousPageIntent: AppIntent {
    static var title: LocalizedStringResource = "Previous feed page"
    static var description = IntentDescription("Show the previous page of saved posts.")

    @Parameter(title: "Posts per page") var pageSize: Int

    init() { pageSize = FeedBarConstants.pageSize }
    init(pageSize: Int) { self.pageSize = pageSize }

    func perform() async throws -> some IntentResult {
        let posts = try FeedStore.load().posts
        let size = min(max(pageSize, 1), 6)
        try PageState.advance(by: -1, totalPosts: posts.count, pageSize: size)
        WidgetCenter.shared.reloadTimelines(ofKind: FeedBarConstants.widgetKind)
        return .result()
    }
}
