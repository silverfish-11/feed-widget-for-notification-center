import Foundation
import Darwin

struct WidgetPreferences: Codable, Equatable {
    enum Appearance: String, Codable, CaseIterable { case system, light, dark }
    enum TextSize: String, Codable, CaseIterable { case small, standard, large }
    enum Density: String, Codable, CaseIterable { case comfortable, compact }
    enum ImageFit: String, Codable, CaseIterable { case fit, fill }
    enum MediaSize: String, Codable, CaseIterable { case standard, large }

    var appearance: Appearance = .dark
    var textSize: TextSize = .standard
    var density: Density = .comfortable
    var showsMedia = true
    var imageFit: ImageFit = .fill
    var mediaSize: MediaSize = .standard

    private struct ExpandedLayout: Codable, Equatable {
        let density: Density
        let mediaSize: MediaSize
    }
    private var expandedLayout: ExpandedLayout?
    private static let processLock = NSLock()

    var isFeedCompact: Bool {
        density == .compact && !(showsMedia && mediaSize == .large)
    }

    mutating func toggleFeedCompact() {
        if isFeedCompact {
            if let expandedLayout {
                density = expandedLayout.density
                mediaSize = expandedLayout.mediaSize
            } else {
                density = .comfortable
            }
            clearExpandedLayout()
        } else {
            expandedLayout = ExpandedLayout(density: density, mediaSize: mediaSize)
            density = .compact
            if showsMedia { mediaSize = .standard }
        }
    }

    /// Explicit layout edits replace the remembered choice; unrelated edits do not.
    mutating func clearExpandedLayout() { expandedLayout = nil }

    init(appearance: Appearance = .dark, textSize: TextSize = .standard,
         density: Density = .comfortable, showsMedia: Bool = true, imageFit: ImageFit = .fill,
         mediaSize: MediaSize = .standard) {
        self.appearance = appearance
        self.textSize = textSize
        self.density = density
        self.showsMedia = showsMedia
        self.imageFit = imageFit
        self.mediaSize = mediaSize
    }

    private enum CodingKeys: String, CodingKey {
        case appearance, textSize, density, showsMedia, imageFit, mediaSize, expandedLayout
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        appearance = (try? values.decode(Appearance.self, forKey: .appearance)) ?? .dark
        textSize = (try? values.decode(TextSize.self, forKey: .textSize)) ?? .standard
        density = (try? values.decode(Density.self, forKey: .density)) ?? .comfortable
        showsMedia = (try? values.decode(Bool.self, forKey: .showsMedia)) ?? true
        imageFit = (try? values.decode(ImageFit.self, forKey: .imageFit)) ?? .fill
        mediaSize = (try? values.decode(MediaSize.self, forKey: .mediaSize)) ?? .standard
        expandedLayout = try? values.decode(ExpandedLayout.self, forKey: .expandedLayout)
    }

    static func load(directory: URL? = nil) throws -> Self {
        let folder = try FeedStore.storageDirectory(override: directory)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), !isDirectory.boolValue {
            throw FeedStoreError.notDirectory(folder)
        }
        let file = folder.appendingPathComponent("widget-preferences.json")
        let data: Data
        do {
            data = try Data(contentsOf: file)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return Self()
        }
        // Invalid JSON is reported without resetting or replacing its bytes.
        return try JSONDecoder().decode(Self.self, from: data)
    }

    func save(directory: URL? = nil) throws {
        try Self.withStorageLock(directory: directory) {
            try saveUnlocked(directory: directory)
        }
    }

    /// Apply a field edit or toggle to the latest saved values under one
    /// cross-process transaction, so host and widget changes cannot be lost.
    @discardableResult
    static func update(directory: URL? = nil, _ change: (inout Self) -> Void) throws -> Self {
        try withStorageLock(directory: directory) {
            var preferences = try load(directory: directory)
            change(&preferences)
            try preferences.saveUnlocked(directory: directory)
            return preferences
        }
    }

    private static func withStorageLock<T>(directory: URL?, _ operation: () throws -> T) throws -> T {
        processLock.lock()
        defer { processLock.unlock() }
        let folder = try FeedStore.storageDirectory(override: directory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let lockURL = folder.appendingPathComponent("widget-preferences.lock")
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        while flock(descriptor, LOCK_EX) != 0 {
            if errno != EINTR { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        defer { flock(descriptor, LOCK_UN) }
        return try operation()
    }

    private func saveUnlocked(directory: URL?) throws {
        let folder = try FeedStore.storageDirectory(override: directory)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("widget-preferences.json")
        let existing: Data?
        do {
            existing = try Data(contentsOf: file)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            existing = nil
        }
        if let existing {
            do { _ = try JSONDecoder().decode(Self.self, from: existing) }
            catch is DecodingError {
                // An explicit preference change may repair an unreadable file,
                // but only after preserving its exact bytes. Backup I/O errors
                // stop the save instead of erasing the previous document.
                let backup = folder.appendingPathComponent("widget-preferences.corrupt-\(UUID().uuidString).json")
                try existing.write(to: backup, options: .atomic)
            }
        }
        try data.write(to: file, options: .atomic)
    }
}
