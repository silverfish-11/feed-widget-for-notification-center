import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers

enum FeedMediaCacheError: LocalizedError {
    case noPreviewURL
    case dataTooLarge
    case invalidImage
    case dimensionsTooLarge
    case encodingFailed
    case unsafeCachePath

    var errorDescription: String? {
        switch self {
        case .noPreviewURL: return "This attachment has no supported image preview URL."
        case .dataTooLarge: return "The media preview exceeds the 12 MB limit."
        case .invalidImage: return "The media preview is not a readable image."
        case .dimensionsTooLarge: return "The media preview has unsupported image dimensions."
        case .encodingFailed: return "The media preview could not be saved as an image."
        case .unsafeCachePath: return "The media cache contains an unexpected file or folder."
        }
    }
}

/// Only the host downloads. These helpers store/read small, local JPEG previews for both targets.
struct FeedMediaCache {
    static let maximumInputBytes = 12 * 1024 * 1024
    static let maximumPixelSize = 1000

    /// Returns the cache location without creating anything. Override is the shared-storage root.
    static func cacheDirectory(directory: URL? = nil) throws -> URL {
        try FeedStore.storageDirectory(override: directory).appendingPathComponent("Media", isDirectory: true)
    }

    static func imageURL(for media: FeedMedia, directory: URL? = nil) -> URL? {
        let expectedName = media.cacheKey + ".jpg"
        guard let name = media.localPreviewFile, name == expectedName,
              let folder = try? cacheDirectory(directory: directory),
              isRegularDirectory(folder) else { return nil }
        let file = folder.appendingPathComponent(name, isDirectory: false)
        guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              let bytes = values.fileSize, bytes > 0, bytes <= maximumInputBytes,
              isCompleteCachedJPEG(file) else { return nil }
        return file
    }

    static func image(for media: FeedMedia, directory: URL? = nil) -> NSImage? {
        guard let file = imageURL(for: media, directory: directory),
              let source = CGImageSourceCreateWithURL(file as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = thumbnail(from: source) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    /// Downsample with ImageIO before decoding pixels. Never use NSImage to decode the original.
    @discardableResult
    static func savePreview(data: Data, for media: FeedMedia, directory: URL? = nil) throws -> String {
        guard media.previewRemoteURL != nil else { throw FeedMediaCacheError.noPreviewURL }
        guard !data.isEmpty, data.count <= maximumInputBytes else { throw FeedMediaCacheError.dataTooLarge }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              hasCompleteImageContainer(data, source: source),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else { throw FeedMediaCacheError.invalidImage }
        let pixels = width.doubleValue * height.doubleValue
        guard width.doubleValue > 0, height.doubleValue > 0,
              width.doubleValue <= 50_000, height.doubleValue <= 50_000, pixels <= 100_000_000 else {
            throw FeedMediaCacheError.dimensionsTooLarge
        }
        guard let thumbnail = thumbnail(from: source) else { throw FeedMediaCacheError.invalidImage }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw FeedMediaCacheError.encodingFailed
        }
        CGImageDestinationAddImage(destination, thumbnail, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        guard CGImageDestinationFinalize(destination), output.length > 0, output.length <= maximumInputBytes else {
            throw FeedMediaCacheError.encodingFailed
        }
        let folder = try cacheDirectory(directory: directory)
        if FileManager.default.fileExists(atPath: folder.path) {
            guard isRegularDirectory(folder) else { throw FeedMediaCacheError.unsafeCachePath }
        } else {
            // A dangling symlink is also unsafe (fileExists alone follows its missing destination).
            if (try? folder.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                throw FeedMediaCacheError.unsafeCachePath
            }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        guard isRegularDirectory(folder) else { throw FeedMediaCacheError.unsafeCachePath }
        let filename = media.cacheKey + ".jpg"
        let file = folder.appendingPathComponent(filename, isDirectory: false)
        if let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
           values.isSymbolicLink == true || values.isRegularFile != true {
            throw FeedMediaCacheError.unsafeCachePath
        }
        try (output as Data).write(to: file, options: .atomic)
        return filename
    }

    /// ImageIO treats final input as complete even when a JPEG/PNG ends midway
    /// through its pixels. Its thumbnail decoder fills the missing area, which
    /// would otherwise become a valid, permanently cached but partial JPEG.
    private static func hasCompleteImageContainer(_ data: Data, source: CGImageSource) -> Bool {
        switch CGImageSourceGetType(source) as String? {
        case UTType.jpeg.identifier:
            return data.withUnsafeBytes { hasJPEGEndMarker($0.bindMemory(to: UInt8.self)) }
        case UTType.png.identifier:
            return data.withUnsafeBytes { hasPNGEndChunk($0.bindMemory(to: UInt8.self)) }
        default:
            return true
        }
    }

    /// Walk segments rather than searching for marker bytes: an EXIF thumbnail
    /// may contain its own EOI before the main photo has finished downloading.
    /// A complete image may also carry an unrelated payload after its real EOI.
    private static func hasJPEGEndMarker(_ bytes: UnsafeBufferPointer<UInt8>) -> Bool {
        guard bytes.count >= 4, bytes[0] == 0xff, bytes[1] == 0xd8 else { return false }
        var offset = 2
        var inScan = false
        var sawScan = false
        while offset < bytes.count {
            if inScan {
                while offset < bytes.count, bytes[offset] != 0xff { offset += 1 }
            } else if bytes[offset] != 0xff { return false }
            while offset < bytes.count, bytes[offset] == 0xff { offset += 1 }
            guard offset < bytes.count else { return false }
            let marker = bytes[offset]
            offset += 1
            if marker == 0x00 { if !inScan { return false }; continue } // escaped entropy byte
            if marker == 0xd9 { return sawScan }
            if marker == 0xd8 { return false }
            if marker == 0x01 || (0xd0...0xd7).contains(marker) { continue } // no payload
            guard bytes.count - offset >= 2 else { return false }
            let length = Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
            guard length >= 2, length <= bytes.count - offset else { return false }
            offset += length
            if marker == 0xda { inScan = true; sawScan = true }
            else if marker != 0xdc { inScan = false } // DNL can occur inside a scan
        }
        return false
    }

    /// Respect chunk lengths so marker-looking bytes in a partial IDAT payload
    /// cannot pass validation. Ignore any outer-container bytes after IEND.
    private static func hasPNGEndChunk(_ bytes: UnsafeBufferPointer<UInt8>) -> Bool {
        guard bytes.count >= 8, bytes.prefix(8).elementsEqual([137, 80, 78, 71, 13, 10, 26, 10]) else { return false }
        var offset = 8
        var sawImageData = false
        while bytes.count - offset >= 12 {
            let length = Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16 |
                Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            guard length <= bytes.count - offset - 12 else { return false }
            let type = bytes[(offset + 4)..<(offset + 8)]
            if type.elementsEqual([0x49, 0x45, 0x4e, 0x44]) {
                return sawImageData && length == 0 && bytes[(offset + 8)..<(offset + 12)].elementsEqual([0xae, 0x42, 0x60, 0x82])
            }
            if type.elementsEqual([0x49, 0x44, 0x41, 0x54]) { sawImageData = true }
            offset += length + 12
        }
        return false
    }

    /// The collector uses imageURL as its cache-hit check, so a broken file must
    /// return nil and permit a download retry. Header/status checks avoid pixel decoding.
    private static func isCompleteCachedJPEG(_ url: URL) -> Bool {
        guard hasJPEGEndMarker(url),
              let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetType(source) as String? == UTType.jpeg.identifier,
              CGImageSourceGetCount(source) == 1,
              CGImageSourceGetStatus(source) == .statusComplete,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else { return false }
        return width.intValue > 0 && height.intValue > 0 &&
            width.intValue <= maximumPixelSize && height.intValue <= maximumPixelSize
    }

    private static func hasJPEGEndMarker(_ url: URL) -> Bool {
        do {
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            let length = try file.seekToEnd()
            guard length >= 4, length <= UInt64(maximumInputBytes) else { return false }
            try file.seek(toOffset: length - 2)
            return try file.read(upToCount: 2) == Data([0xff, 0xd9])
        } catch {
            return false
        }
    }

    private static func isRegularDirectory(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    private static func thumbnail(from source: CGImageSource) -> CGImage? {
        CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary)
    }
}
