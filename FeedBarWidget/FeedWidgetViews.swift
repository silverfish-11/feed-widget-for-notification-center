import SwiftUI
import WidgetKit

struct FeedWidgetPalette {
    let isDark: Bool

    init(preferences: WidgetPreferences, systemScheme: ColorScheme) {
        isDark = preferences.appearance == .dark || (preferences.appearance == .system && systemScheme == .dark)
    }

    var foreground: Color { isDark ? .white : Color(white: 0.08) }
    var background: Color { Color(white: isDark ? 0.12 : 0.95) }
    var mediaBackground: Color { Color(white: isDark ? 0.19 : 0.86) }
}

struct FeedWidgetBackground: View {
    @Environment(\.colorScheme) private var colorScheme
    let preferences: WidgetPreferences
    var body: some View { FeedWidgetPalette(preferences: preferences, systemScheme: colorScheme).background }
}

struct FeedWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var colorScheme
    var entry: FeedEntry
    // Explicit local directory is only used by isolated previews and tests.
    var mediaDirectory: URL? = nil

    private var isSmall: Bool { family == .systemSmall }
    private var isCompact: Bool { family == .systemSmall || family == .systemMedium }
    private var preferences: WidgetPreferences { entry.preferences }
    private var palette: FeedWidgetPalette { .init(preferences: preferences, systemScheme: colorScheme) }
    private var foreground: Color { palette.foreground }
    private var usesLargeMedia: Bool { preferences.showsMedia && preferences.mediaSize == .large }
    private var denseRows: Bool { preferences.density == .compact && entry.pageSize > 2 }
    private var rowSpacing: CGFloat { denseRows ? 6 : 8 }
    private var bodyFontSize: CGFloat { FeedWidgetLayout.bodyFontSize(for: family, preferences: preferences) }
    private var previewHeight: CGFloat {
        if usesLargeMedia {
            if isSmall { return 72 - (preferences.textSize == .large ? 4 : 0) - (entry.errorMessage == nil ? 0 : 12) }
            if !isCompact { return (preferences.textSize == .large ? 170 : 178) - (entry.errorMessage == nil ? 0 : 12) }
        }
        if isSmall { return 55 - (preferences.textSize == .large ? 10 : 0) - (entry.errorMessage == nil ? 0 : 12) }
        if isCompact { return entry.errorMessage == nil ? 80 : 68 }
        return denseRows ? 68 : 108
    }

    var body: some View {
        VStack(alignment: .leading, spacing: isCompact ? 5 : 8) {
            header
            if entry.posts.isEmpty {
                emptyState
            } else if family == .systemExtraLarge {
                // Two columns; large media uses one row and compact standard
                // media uses three. Capacity comes from the same preference snapshot.
                VStack(spacing: rowSpacing) {
                    ForEach(0..<((entry.pageSize + 1) / 2), id: \.self) { row in
                        HStack(alignment: .top, spacing: 16) {
                            ForEach(Array(entry.posts.dropFirst(row * 2).prefix(2)), id: \.stableIdentifier) { post in
                                postLink(post)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            }
                            if entry.posts.count == row * 2 + 1 {
                                Color.clear.frame(maxWidth: .infinity)
                            }
                        }
                        .frame(maxHeight: .infinity, alignment: .top)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
            } else {
                VStack(alignment: .leading, spacing: isCompact ? 0 : rowSpacing) {
                    ForEach(entry.posts, id: \.stableIdentifier) { post in
                        postLink(post)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
            footer
        }
        .foregroundStyle(foreground)
        .tint(foreground)
        .multilineTextAlignment(.leading)
        .padding(isSmall ? 12 : 14)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("Feed")
                .font(.system(size: isCompact ? 13 : 16, weight: .semibold))
                .fixedSize()
            Spacer(minLength: 0)
            if entry.totalPages > 1 {
                Button(intent: PreviousPageIntent(pageSize: entry.pageSize)) {
                    Image(systemName: "chevron.left")
                }
                .disabled(entry.page == 0)
                .accessibilityLabel("Previous feed page")
                Text("\(entry.page + 1)/\(entry.totalPages)")
                    .font(.system(size: 9).monospacedDigit())
                    .foregroundStyle(foreground.opacity(0.65))
                Button(intent: NextPageIntent(pageSize: entry.pageSize)) {
                    Image(systemName: "chevron.right")
                }
                .disabled(entry.page + 1 >= entry.totalPages)
                .accessibilityLabel("Next feed page")
            }
            if !isSmall {
                Button(intent: ToggleCompactFeedIntent()) {
                    Image(systemName: preferences.isFeedCompact ? "rectangle.expand.vertical" : "rectangle.compress.vertical")
                        .frame(width: 18, height: isCompact ? 16 : 20)
                        .background(preferences.isFeedCompact ? foreground.opacity(0.12) : .clear,
                                    in: RoundedRectangle(cornerRadius: 3))
                }
                .fixedSize()
                .help(preferences.isFeedCompact ? "Expand feed" : "Compact feed")
                .accessibilityLabel(preferences.isFeedCompact ? "Expand feed" : "Compact feed")
                .accessibilityValue(preferences.isFeedCompact ? "Compact" : "Expanded")
            }
            Link(destination: FeedBarConstants.refreshURL) {
                Image(systemName: "arrow.clockwise")
            }
            .fixedSize()
            .accessibilityLabel("Refresh feed")
            if !isSmall {
                Link(destination: URL(string: "feedbar://settings")!) { Image(systemName: "gearshape") }
                    .fixedSize()
                    .accessibilityLabel("Widget preferences")
            }
        }
        .font(.system(size: 10, weight: .medium))
        .buttonStyle(.plain)
        .frame(height: isCompact ? 16 : 20)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 5) {
            if entry.errorMessage != nil {
                Text("Saved feed unavailable")
                    .font(.system(size: 12, weight: .semibold))
                Text("Refresh to try reading your saved posts again.")
                    .font(.system(size: 10))
                    .lineLimit(isSmall ? 3 : 4)
                Link("Retry refresh", destination: FeedBarConstants.refreshURL)
                    .font(.system(size: 11, weight: .medium))
            } else if entry.snapshot.sources.values.contains(where: { $0.status == "loading" }) {
                Text("Refreshing your feed…")
                    .font(.system(size: 12, weight: .medium))
                Text("Checking your connected sources.")
                    .font(.system(size: 10))
                    .foregroundStyle(foreground.opacity(0.65))
                Link("Retry refresh", destination: FeedBarConstants.refreshURL)
                    .font(.system(size: 11, weight: .medium))
            } else {
                Text("No saved posts yet")
                    .font(.system(size: 12, weight: .medium))
                Text(sourceNeedsLogin("x") || sourceNeedsLogin("ig")
                     ? "Sign in to load posts here."
                     : "Refresh to check your connected sources.")
                    .font(.system(size: 10))
                    .foregroundStyle(foreground.opacity(0.65))
                if sourceNeedsLogin("x") {
                    Link("Sign in to X", destination: URL(string: "feedbar://login/x")!)
                        .font(.system(size: 11, weight: .medium))
                }
                if sourceNeedsLogin("ig") {
                    Link("Sign in to Instagram", destination: URL(string: "feedbar://login/ig")!)
                        .font(.system(size: 11, weight: .medium))
                }
                if !sourceNeedsLogin("x") && !sourceNeedsLogin("ig") {
                    Link("Retry refresh", destination: FeedBarConstants.refreshURL)
                        .font(.system(size: 11, weight: .medium))
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .center)
    }

    @ViewBuilder
    private func postLink(_ post: FeedPost) -> some View {
        // A video poster opens its original post, where playback/authentication
        // belongs. The widget reads only locally cached preview images.
        if let quote = post.quotedPost {
            quotedPostRow(post, quote: quote)
        } else if let destination = post.url {
            Link(destination: destination) { postRow(post) }
        } else {
            postRow(post)
        }
    }

    private var tightQuoteLayout: Bool { isCompact || denseRows }

    private func quotedPostRow(_ post: FeedPost, quote: FeedQuotedPost) -> some View {
        VStack(alignment: .leading, spacing: tightQuoteLayout ? 3 : 4) {
            // These are sibling links: the author's comment opens the outer post,
            // while the bordered quotation opens the quoted post itself.
            if let destination = post.url {
                Link(destination: destination) { quoteParent(post) }
            } else {
                quoteParent(post)
            }
            if let destination = quote.url {
                Link(destination: destination) { quoteCard(quote, parentHasMedia: featuredMedia(post) != nil) }
            } else {
                quoteCard(quote, parentHasMedia: featuredMedia(post) != nil)
            }
            if usesLargeMedia && !isCompact {
                timestamp(post)
            }
        }
    }

    private func quoteParent(_ post: FeedPost) -> some View {
        HStack(alignment: .top, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                authorLine(post)
                if !post.text.isEmpty {
                    Text(post.text)
                        .font(.system(size: bodyFontSize))
                        .foregroundStyle(foreground.opacity(0.88))
                        .lineLimit(tightQuoteLayout ? 1 : 2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let media = featuredMedia(post) {
                mediaPreview(media, count: post.media.count)
                    .frame(width: tightQuoteLayout ? 34 : usesLargeMedia ? 80 : 56,
                           height: tightQuoteLayout ? 28 : usesLargeMedia ? 58 : 42)
            }
        }
    }

    private func quoteCard(_ quote: FeedQuotedPost, parentHasMedia: Bool) -> some View {
        let media = quote.isUnavailable ? nil : featuredMedia(quote.media)
        let prominent = usesLargeMedia && !isCompact
        let height: CGFloat = tightQuoteLayout ? (entry.errorMessage == nil ? 42 : 36)
            : prominent ? (parentHasMedia ? 154 : 178) - (entry.errorMessage == nil ? 0 : 12)
            : (entry.errorMessage == nil ? 70 : 62)
        let name = quote.author.isEmpty ? (quote.handle.isEmpty ? "Quoted post" : "@\(quote.handle)") : quote.author
        let caption = quote.isUnavailable ? "Quoted post unavailable" : quote.text
        let attribution = quote.author.isEmpty && quote.handle.isEmpty ? "Quoted post"
            : "Quoted post by \(name)\(quote.handle.isEmpty || name == "@" + quote.handle ? "" : ", @" + quote.handle)"
        let mediaDescription = media.map { $0.isVideo ? "Video preview. Open quoted post to play." : ($0.altText.isEmpty ? "Photo." : $0.altText) } ?? ""
        let fontSize = max(bodyFontSize - 1, 10)
        return Group {
            if prominent, let media {
                VStack(alignment: .leading, spacing: 3) {
                    quoteAuthor(name)
                    if !caption.isEmpty {
                        Text(caption)
                            .font(.system(size: fontSize))
                            .lineLimit(2)
                    }
                    mediaPreview(media, count: quote.media.count)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                HStack(alignment: .top, spacing: 5) {
                    VStack(alignment: .leading, spacing: 2) {
                        quoteAuthor(name)
                        if !caption.isEmpty {
                            Text(caption)
                                .font(.system(size: fontSize))
                                .lineLimit(tightQuoteLayout ? 1 : prominent ? 7 : 3)
                        } else if media == nil {
                            Text("Open quoted post")
                                .font(.system(size: fontSize))
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if let media {
                        mediaPreview(media, count: quote.media.count)
                            .frame(width: tightQuoteLayout ? 36 : 64,
                                   height: height - 8)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(4)
        .frame(height: height)
        .background(foreground.opacity(0.035), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(foreground.opacity(0.2), lineWidth: 1))
        .foregroundStyle(foreground.opacity(0.85))
        .multilineTextAlignment(.leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(attribution). \(caption) \(mediaDescription)")
    }

    private func quoteAuthor(_ name: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "quote.opening")
            Text(name).lineLimit(1)
        }
        .font(.system(size: max(FeedWidgetLayout.authorFontSize(preferences: preferences) - 1, 9), weight: .semibold))
        .foregroundStyle(foreground.opacity(0.65))
    }

    @ViewBuilder
    private func postRow(_ post: FeedPost) -> some View {
        let media = featuredMedia(post)
        let lines = FeedWidgetLayout.textLines(for: family, preferences: preferences,
                                               hasMedia: media != nil, hasError: entry.errorMessage != nil)
        if isSmall {
            VStack(alignment: .leading, spacing: 4) {
                authorLine(post)
                if let media {
                    mediaPreview(media, count: post.media.count)
                        .frame(maxWidth: .infinity)
                        .frame(height: previewHeight)
                }
                if !post.text.isEmpty && lines > 0 {
                    Text(post.text)
                        .font(.system(size: bodyFontSize))
                        .foregroundStyle(foreground.opacity(0.88))
                        .lineLimit(lines)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } else if usesLargeMedia, !isCompact, let media {
            VStack(alignment: .leading, spacing: 4) {
                authorLine(post)
                mediaPreview(media, count: post.media.count)
                    .frame(maxWidth: .infinity)
                    .frame(height: previewHeight)
                if !post.text.isEmpty {
                    Text(post.text)
                        .font(.system(size: bodyFontSize))
                        .foregroundStyle(foreground.opacity(0.88))
                        .lineLimit(lines)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                timestamp(post)
            }
        } else {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: denseRows ? 3 : 4) {
                    authorLine(post)
                    if !post.text.isEmpty {
                        Text(post.text)
                            .font(.system(size: bodyFontSize))
                            .foregroundStyle(foreground.opacity(0.88))
                            .lineLimit(lines)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    timestamp(post)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let media {
                    mediaPreview(media, count: post.media.count)
                        .frame(width: isCompact ? (usesLargeMedia ? 180 : 112) : denseRows ? 82 : 110,
                               height: previewHeight)
                }
            }
        }
    }

    private func authorLine(_ post: FeedPost) -> some View {
        HStack(spacing: 4) {
            Text(post.author.isEmpty ? "@\(post.handle)" : post.author)
                .font(.system(size: FeedWidgetLayout.authorFontSize(preferences: preferences), weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: 2)
            Text(post.platformLabel)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(foreground.opacity(0.5))
        }
    }

    private func timestamp(_ post: FeedPost) -> some View {
        Group {
            if post.hasKnownTimestamp {
                Text(post.timestamp, style: .relative)
            } else {
                Text("Date unavailable")
            }
        }
        .font(.system(size: 9))
        .foregroundStyle(foreground.opacity(0.55))
        .lineLimit(1)
    }

    private func featuredMedia(_ post: FeedPost) -> FeedMedia? {
        featuredMedia(post.media)
    }

    private func featuredMedia(_ media: [FeedMedia]) -> FeedMedia? {
        guard preferences.showsMedia else { return nil }
        return media.first(where: { FeedMediaCache.imageURL(for: $0, directory: mediaDirectory) != nil }) ?? media.first
    }

    private func mediaPreview(_ media: FeedMedia, count: Int) -> some View {
        GeometryReader { geometry in
            ZStack {
                palette.mediaBackground
                if let image = FeedMediaCache.image(for: media, directory: mediaDirectory) {
                    fullColorMediaImage(image)
                        .aspectRatio(contentMode: preferences.imageFit == .fit ? .fit : .fill)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                } else {
                    VStack(spacing: 4) {
                        Image(systemName: media.isVideo ? "video" : "photo")
                            .font(.system(size: isSmall ? 14 : 18))
                        if !isSmall {
                            Text("Preview unavailable")
                                .font(.system(size: 8))
                                .lineLimit(1)
                        }
                    }
                    .foregroundStyle(foreground.opacity(0.6))
                }
                if media.isVideo {
                    Image(systemName: "play.fill")
                        .font(.system(size: isSmall ? 11 : 14, weight: .semibold))
                        .padding(isSmall ? 8 : 10)
                        .background(.black.opacity(0.55), in: Circle())
                        .foregroundStyle(.white)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if count > 1 {
                    HStack(spacing: 3) {
                        Image(systemName: "square.on.square")
                        Text("\(count)")
                    }
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.65), in: Capsule())
                    .padding(4)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .accessibilityLabel(media.isVideo ? "Video preview. Open original post to play." : (media.altText.isEmpty ? "Photo" : media.altText))
    }

    @ViewBuilder
    private func fullColorMediaImage(_ image: NSImage) -> some View {
        if #available(macOS 15.0, *) {
            // Clear/tinted widgets otherwise treat opaque photos as solid-white
            // templates. SwiftUI's .original alone does not opt out of that pass.
            Image(nsImage: image)
                .renderingMode(.original)
                .resizable()
                .widgetAccentedRenderingMode(.fullColor)
        } else {
            Image(nsImage: image)
                .renderingMode(.original)
                .resizable()
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 3) {
            if entry.errorMessage != nil, !entry.posts.isEmpty {
                Text("Open Settings or refresh to retry.")
                    .font(.system(size: 9))
                    .foregroundStyle(foreground.opacity(0.7))
                    .lineLimit(1)
            }
            HStack(spacing: 7) {
                sourceStatus("x", label: "X")
                sourceStatus("ig", label: isSmall ? "IG" : "Instagram")
            }
            if let lastSuccess = entry.snapshot.lastSuccess {
                HStack(spacing: 3) {
                    Text("Saved")
                    Text(lastSuccess, style: .relative)
                    Text("ago")
                }
                .font(.system(size: 9))
                .foregroundStyle(foreground.opacity(0.55))
                .lineLimit(1)
            }
        }
    }

    private func sourceStatus(_ key: String, label: String) -> some View {
        let source = entry.snapshot.sources[key] ?? FeedSourceState()
        let needsLogin = sourceNeedsLogin(key)
        let stale = source.lastSuccess.map { entry.date.timeIntervalSince($0) > 30 * 60 } ?? false
        let status: String = {
            switch source.status {
            case "loading": return "checking"
            case "ready": return stale ? "old" : "ready"
            case "loginRequired": return "sign in"
            case "error": return "error"
            default: return "connect"
            }
        }()
        let destination = needsLogin ? URL(string: "feedbar://login/\(key)")! : FeedBarConstants.refreshURL
        return Link(destination: destination) {
            Text("\(label): \(status)")
                .font(.system(size: 9))
                .foregroundStyle(foreground.opacity(source.status == "error" || source.status == "loginRequired" || stale ? 0.8 : 0.6))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .accessibilityLabel("\(label): \(status). \(needsLogin ? "Sign in." : "Refresh feed.")")
    }

    private func sourceNeedsLogin(_ key: String) -> Bool {
        let status = entry.snapshot.sources[key]?.status ?? "idle"
        return status == "loginRequired" || status == "idle"
    }
}
