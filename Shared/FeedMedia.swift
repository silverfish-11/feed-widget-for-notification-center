import Foundation
import CryptoKit

struct FeedMedia: Codable, Hashable, Identifiable {
    var kind: String
    var url: String?
    var previewURL: String?
    var altText: String
    var width: Int?
    var height: Int?
    var localPreviewFile: String?

    init(kind: String, url: String? = nil, previewURL: String? = nil, altText: String = "",
         width: Int? = nil, height: Int? = nil, localPreviewFile: String? = nil) {
        self.kind = kind
        self.url = url
        self.previewURL = previewURL
        self.altText = altText
        self.width = width
        self.height = height
        self.localPreviewFile = localPreviewFile
    }

    var isVideo: Bool { kind == "video" }

    /// Stable across launches and changes to the local cache path.
    var cacheKey: String {
        let remote: String?
        if Self.imageRemoteURL(previewURL) != nil {
            remote = previewURL
        } else if (kind == "image" && Self.imageRemoteURL(url) != nil) || (isVideo && playbackURL != nil) {
            // Identify the fallback resource that the UI and downloader use.
            remote = url
        } else {
            remote = previewURL ?? url
        }
        let identity = kind + ":" + (remote.map(Self.cacheIdentity) ?? altText)
        return SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// These CDNs put asset identity in the path and rotate signatures/renditions
    /// in the query. A renewed URL must keep the last good local preview usable.
    private static func cacheIdentity(_ raw: String) -> String {
        guard var components = URLComponents(string: raw), let host = components.host?.lowercased(),
              ["twimg.com", "cdninstagram.com", "fbcdn.net"].contains(where: { host == $0 || host.hasSuffix("." + $0) }) else {
            return raw
        }
        components.scheme = components.scheme?.lowercased()
        components.host = host
        components.query = nil
        components.fragment = nil
        components.user = nil
        components.password = nil
        return components.string ?? raw
    }

    var id: String { cacheKey }

    /// A video URL is never used as an image. Blob URLs belong to the originating web page.
    var previewRemoteURL: URL? {
        if let preview = Self.imageRemoteURL(previewURL) { return preview }
        return kind == "image" ? Self.imageRemoteURL(url) : nil
    }

    var playbackURL: URL? {
        isVideo ? Self.remoteURL(url) : nil
    }

    private static func imageRemoteURL(_ raw: String?) -> URL? {
        guard let url = remoteURL(raw),
              !["mp4", "m4v", "mov", "webm", "m3u8", "m3u", "mpd"].contains(url.pathExtension.lowercased()) else { return nil }
        return url
    }

    /// Accept public HTTP(S) URLs only; never turn media metadata into local file requests.
    static func remoteURL(_ raw: String?) -> URL? {
        guard let raw, let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme),
              url.user == nil, url.password == nil,
              let rawHost = url.host, !rawHost.isEmpty else { return nil }
        let host = rawHost.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]."))
        guard host.contains("."), !host.contains(":"),
              host != "localhost", !host.hasSuffix(".localhost"), !host.hasSuffix(".local"),
              !host.hasSuffix(".internal"), !host.hasSuffix(".lan") else { return nil }
        let pieces = host.split(separator: ".")
        if pieces.allSatisfy({ Int($0) != nil }) {
            guard pieces.count == 4 else { return nil }
            let bytes = pieces.compactMap { Int($0) }
            guard bytes.allSatisfy({ (0...255).contains($0) }),
                  bytes[0] != 0, bytes[0] != 10, bytes[0] != 127,
                  bytes[0] < 224,
                  !(bytes[0] == 169 && bytes[1] == 254),
                  !(bytes[0] == 172 && (16...31).contains(bytes[1])),
                  !(bytes[0] == 192 && bytes[1] == 168),
                  !(bytes[0] == 100 && (64...127).contains(bytes[1])) else { return nil }
        }
        return url
    }

    private enum CodingKeys: String, CodingKey {
        case kind, url, previewURL, altText, width, height, localPreviewFile
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        kind = try values.decode(String.self, forKey: .kind)
        url = try values.decodeIfPresent(String.self, forKey: .url)
        previewURL = try values.decodeIfPresent(String.self, forKey: .previewURL)
        altText = try values.decodeIfPresent(String.self, forKey: .altText) ?? ""
        width = try values.decodeIfPresent(Int.self, forKey: .width)
        height = try values.decodeIfPresent(Int.self, forKey: .height)
        localPreviewFile = try values.decodeIfPresent(String.self, forKey: .localPreviewFile)
    }
}
