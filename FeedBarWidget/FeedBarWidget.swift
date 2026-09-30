import WidgetKit
import SwiftUI

@main
struct FeedBarWidgetBundle: WidgetBundle {
    var body: some Widget {
        FeedBarMainWidget()
    }
}

struct FeedBarMainWidget: Widget {
    let kind = FeedBarConstants.widgetKind

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: FeedTimelineProvider()) { entry in
            FeedWidgetEntryView(entry: entry)
                .containerBackground(for: .widget) {
                    Color(white: 0.12)
                }
        }
        .contentMarginsDisabled()
        .configurationDisplayName("Feed")
        .description("Photos and updates from your sources in Notification Center.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge])
    }
}
