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
    private var denseRows: Bool { preferences.density == .compact && entry.pageSize > 2 }
    private var rowSpacing: CGFloat { denseRows ? 6 : 8 }
    private var bodyFontSize: CGFloat { FeedWidgetLayout.bodyFontSize(for: family, preferences: preferences) }
    private var previewHeight: CGFloat {
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
                // Two columns; compact density adds a third row.
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
        if let destination = post.url {
            Link(destination: destination) { postRow(post) }
        } else {
            postRow(post)
        }
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
                if !post.text.isEmpty {
                    Text(post.text)
                        .font(.system(size: bodyFontSize))
                        .foregroundStyle(foreground.opacity(0.88))
                        .lineLimit(lines)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
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
                        .frame(width: isCompact ? 112 : denseRows ? 82 : 110, height: previewHeight)
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
        guard preferences.showsMedia else { return nil }
        return post.media.first(where: { FeedMediaCache.imageURL(for: $0, directory: mediaDirectory) != nil }) ?? post.media.first
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
