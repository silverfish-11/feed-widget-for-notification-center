import Foundation

struct WidgetPreferences: Codable, Equatable {
    enum Appearance: String, Codable, CaseIterable { case system, light, dark }
    enum TextSize: String, Codable, CaseIterable { case small, standard, large }
    enum Density: String, Codable, CaseIterable { case comfortable, compact }
    enum ImageFit: String, Codable, CaseIterable { case fit, fill }

    var appearance: Appearance = .dark
    var textSize: TextSize = .standard
    var density: Density = .comfortable
    var showsMedia = true
    var imageFit: ImageFit = .fill

    init(appearance: Appearance = .dark, textSize: TextSize = .standard,
         density: Density = .comfortable, showsMedia: Bool = true, imageFit: ImageFit = .fill) {
        self.appearance = appearance
        self.textSize = textSize
        self.density = density
        self.showsMedia = showsMedia
        self.imageFit = imageFit
    }

    private enum CodingKeys: String, CodingKey { case appearance, textSize, density, showsMedia, imageFit }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        appearance = (try? values.decode(Appearance.self, forKey: .appearance)) ?? .dark
        textSize = (try? values.decode(TextSize.self, forKey: .textSize)) ?? .standard
        density = (try? values.decode(Density.self, forKey: .density)) ?? .comfortable
        showsMedia = (try? values.decode(Bool.self, forKey: .showsMedia)) ?? true
        imageFit = (try? values.decode(ImageFit.self, forKey: .imageFit)) ?? .fill
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
