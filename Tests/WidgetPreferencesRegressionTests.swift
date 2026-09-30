import Foundation
import WidgetKit

@main
struct WidgetPreferencesRegressionTests {
    struct Failure: Error { let message: String }
    static var assertions = 0
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        assertions += 1
        if !condition() { throw Failure(message: message) }
    }

    static func main() throws {
        if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--toggle-worker",
           let count = Int(CommandLine.arguments[3]), count > 0 {
            let directory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
            for _ in 0..<count {
                try WidgetPreferences.update(directory: directory) { $0.toggleFeedCompact() }
            }
            return
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FeedBarWidgetPreferences-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("widget-preferences.json")
        let defaults = WidgetPreferences()
        let initial = try WidgetPreferences.load(directory: root)
        try expect(initial == defaults, "A missing preferences file must use the established widget defaults")
        try expect(!FileManager.default.fileExists(atPath: file.path), "Reading defaults must not create runtime files")
        let chosen = WidgetPreferences(appearance: .light, textSize: .large, density: .compact, showsMedia: false, imageFit: .fit, mediaSize: .large)
        try chosen.save(directory: root)
        let restored = try WidgetPreferences.load(directory: root)
        try expect(restored == chosen, "Every appearance preference must survive an atomic save/load")
        let oldBytes = try Data(contentsOf: file)
        var legacyObject = try JSONSerialization.jsonObject(with: oldBytes) as! [String: Any]
        legacyObject.removeValue(forKey: "mediaSize")
        try JSONSerialization.data(withJSONObject: legacyObject).write(to: file)
        let legacy = try WidgetPreferences.load(directory: root)
        var legacyExpected = chosen
        legacyExpected.mediaSize = .standard
        try expect(legacy == legacyExpected, "Older preferences without mediaSize must retain every existing choice and use standard images")
        for invalidSize in ["\"future-size\"", "null", "42"] {
            try Data("{\"mediaSize\":\(invalidSize),\"showsMedia\":false}".utf8).write(to: file)
            let invalid = try WidgetPreferences.load(directory: root)
            try expect(invalid.mediaSize == .standard && !invalid.showsMedia,
                       "Unsupported image-size values must fall back without losing another valid preference")
        }
        let malformed = Data("{\"appearance\": broken JSON".utf8)
        try malformed.write(to: file)
        do {
            _ = try WidgetPreferences.load(directory: root)
            throw Failure(message: "Malformed preferences were silently replaced with defaults")
        } catch is DecodingError { assertions += 1 }
        try expect(tryData(file) == malformed, "A failed read must preserve corrupt bytes for review")
        try chosen.save(directory: root)
        let backups = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("widget-preferences.corrupt-") }
        try expect(backups.count == 1 && tryData(backups[0]) == malformed,
                   "An explicit repair must back up the original corrupt bytes before saving")
        let repaired = try WidgetPreferences.load(directory: root)
        try expect(repaired == chosen, "A preference change must recover after successfully preserving corruption")
        try defaults.save(directory: root)
        let afterValidSave = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("widget-preferences.corrupt-") }
        try expect(afterValidSave == backups, "Ordinary valid saves must not create corruption backups")
        try Data("[]".utf8).write(to: file)
        do {
            _ = try WidgetPreferences.load(directory: root)
            throw Failure(message: "A non-object preferences document was accepted")
        } catch is DecodingError { assertions += 1 }
        try Data("{}".utf8).write(to: file)
        let missingFields = try WidgetPreferences.load(directory: root)
        try expect(missingFields == defaults, "Missing fields must retain compatibility with older preferences")
        try Data("{\"appearance\":\"future-theme\",\"textSize\":null,\"density\":42,\"showsMedia\":\"unexpected\",\"imageFit\":\"future-mode\",\"futureOption\":true}".utf8).write(to: file)
        let unknownFields = try WidgetPreferences.load(directory: root)
        try expect(unknownFields == defaults, "Unknown or unsupported field values must fall back independently")
        try Data("{\"appearance\":\"system\",\"showsMedia\":false}".utf8).write(to: file)
        let partial = try WidgetPreferences.load(directory: root)
        try expect(partial.appearance == .system && !partial.showsMedia && partial.textSize == .standard,
                   "Valid fields must survive alongside absent fields")
        try oldBytes.write(to: file)
        let blocked = root.appendingPathComponent("not-a-directory")
        try Data("retained".utf8).write(to: blocked)
        do {
            _ = try WidgetPreferences.load(directory: blocked)
            throw Failure(message: "A storage failure was mistaken for missing settings")
        } catch FeedStoreError.notDirectory { assertions += 1 }
        do {
            try defaults.save(directory: blocked)
            throw Failure(message: "An impossible preferences write unexpectedly succeeded")
        } catch is Failure { throw Failure(message: "Expected a filesystem error") }
        catch { assertions += 1 }
        try expect(tryData(blocked) == Data("retained".utf8), "Write failures must preserve the obstructing file")
        try expect(tryData(file) == oldBytes, "Unrelated write failure must not touch saved preferences")

        let unreadableRoot = root.appendingPathComponent("unreadable-file")
        let directoryInsteadOfFile = unreadableRoot.appendingPathComponent("widget-preferences.json")
        try FileManager.default.createDirectory(at: directoryInsteadOfFile, withIntermediateDirectories: true)
        do {
            try defaults.save(directory: unreadableRoot)
            throw Failure(message: "An unreadable existing preferences path was overwritten")
        } catch is Failure { throw Failure(message: "Expected an existing-document read error") }
        catch { assertions += 1 }
        var remainsDirectory: ObjCBool = false
        try expect(FileManager.default.fileExists(atPath: directoryInsteadOfFile.path, isDirectory: &remainsDirectory) && remainsDirectory.boolValue,
                   "An existing-document read failure must preserve its path")

        let readOnlyRoot = root.appendingPathComponent("backup-write-failure")
        try FileManager.default.createDirectory(at: readOnlyRoot, withIntermediateDirectories: true)
        let readOnlyFile = readOnlyRoot.appendingPathComponent("widget-preferences.json")
        try malformed.write(to: readOnlyFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: readOnlyRoot.path)
        if !FileManager.default.isWritableFile(atPath: readOnlyRoot.path) {
            do {
                try defaults.save(directory: readOnlyRoot)
                throw Failure(message: "Saving continued after a corruption backup could not be written")
            } catch is Failure {
                try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: readOnlyRoot.path)
                throw Failure(message: "Expected a backup write failure")
            } catch { assertions += 1 }
            try expect(tryData(readOnlyFile) == malformed, "A backup write failure must leave corrupt original bytes untouched")
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: readOnlyRoot.path)

        try compactToggleChecks(root: root)

        let families: [WidgetFamily] = [.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge]
        for density in WidgetPreferences.Density.allCases {
            for textSize in WidgetPreferences.TextSize.allCases {
                for showsMedia in [true, false] {
                    for mediaSize in WidgetPreferences.MediaSize.allCases {
                      let preferences = WidgetPreferences(textSize: textSize, density: density, showsMedia: showsMedia, mediaSize: mediaSize)
                      for family in families {
                        let capacity = FeedWidgetLayout.pageSize(for: family, preferences: preferences)
                        let expected: Int
                        if showsMedia && mediaSize == .large {
                            expected = family == .systemExtraLarge ? 2 : 1
                        } else {
                            switch family {
                            case .systemSmall, .systemMedium: expected = 1
                            case .systemExtraLarge: expected = density == .compact ? 6 : 4
                            default: expected = density == .compact && textSize != .large ? 3 : 2
                            }
                        }
                        try expect(capacity == expected, "Density/text-size capacity must keep every widget row within its family")
                        try expect((1...6).contains(capacity), "Page capacity must stay within the intent's supported range")
                        let lines = FeedWidgetLayout.textLines(for: family, preferences: preferences, hasMedia: showsMedia, hasError: false)
                        let omitsCaption = family == .systemSmall && showsMedia && mediaSize == .large
                        try expect(omitsCaption ? lines == 0 : (1...5).contains(lines),
                                   "Only the small larger-image layout may omit its caption to preserve navigation/status")
                        if !showsMedia {
                            let standardMedia = WidgetPreferences(textSize: textSize, density: density, showsMedia: false)
                            try expect(capacity == FeedWidgetLayout.pageSize(for: family, preferences: standardMedia),
                                       "Hiding large images must restore the chosen post density")
                        }
                      }
                    }
                }
            }
        }
        for family in families {
            let small = WidgetPreferences(textSize: .small)
            let standard = WidgetPreferences()
            let large = WidgetPreferences(textSize: .large)
            try expect(FeedWidgetLayout.bodyFontSize(for: family, preferences: small) < FeedWidgetLayout.bodyFontSize(for: family, preferences: standard),
                       "Small text must visibly reduce the body font")
            try expect(FeedWidgetLayout.bodyFontSize(for: family, preferences: standard) < FeedWidgetLayout.bodyFontSize(for: family, preferences: large),
                       "Large text must visibly enlarge the body font")
            try expect(FeedWidgetLayout.authorFontSize(preferences: small) < FeedWidgetLayout.authorFontSize(preferences: large),
                       "Text size must affect author names too")
        }
        let noMediaLines = FeedWidgetLayout.textLines(for: .systemSmall, preferences: defaults, hasMedia: false, hasError: false)
        let mediaLines = FeedWidgetLayout.textLines(for: .systemSmall, preferences: defaults, hasMedia: true, hasError: false)
        try expect(noMediaLines > mediaLines, "Hiding previews must return their space to post text")
        let entry = FeedEntry(date: .now, posts: [], page: 0, totalPages: 1, pageSize: 1, snapshot: .init(), errorMessage: nil)
        try expect(entry.preferences == defaults, "Existing entry fixtures must keep working without a preferences argument")
        let customized = FeedEntry(date: .now, posts: [], page: 0, totalPages: 1, pageSize: 3, snapshot: .init(), errorMessage: nil, preferences: chosen)
        try expect(customized.preferences == chosen, "Each entry must keep its own immutable preference snapshot")
        print("Passed \(assertions) isolated widget preference persistence and layout checks.")
    }

    static func compactToggleChecks(root: URL) throws {
        for density in WidgetPreferences.Density.allCases {
            for mediaSize in WidgetPreferences.MediaSize.allCases {
                for showsMedia in [true, false] {
                    let original = WidgetPreferences(appearance: .light, textSize: .large,
                                                     density: density, showsMedia: showsMedia,
                                                     imageFit: .fit, mediaSize: mediaSize)
                    var toggled = original
                    let beganCompact = original.isFeedCompact
                    toggled.toggleFeedCompact()
                    try expect(toggled.isFeedCompact != beganCompact, "Each click must change the active compact state, including existing Compact preferences")
                    try expect(toggled.appearance == original.appearance && toggled.textSize == original.textSize &&
                               toggled.showsMedia == original.showsMedia && toggled.imageFit == original.imageFit,
                               "Compacting must preserve unrelated appearance choices and media visibility")
                    if beganCompact {
                        try expect(toggled.density == .comfortable && toggled.mediaSize == original.mediaSize,
                                   "Existing Compact preferences without a remembered layout must expand without replacing media size")
                    } else {
                        try expect(toggled.density == .compact && (!showsMedia || toggled.mediaSize == .standard),
                                   "Compacting must override visible Large media so the feed actually becomes denser")
                        let data = try JSONEncoder().encode(toggled)
                        var restored = try JSONDecoder().decode(WidgetPreferences.self, from: data)
                        try expect(restored == toggled, "The remembered expanded layout must survive persistence")
                        restored.toggleFeedCompact()
                        try expect(restored == original, "Expanding must exactly restore the previous density and media size")
                    }
                }
            }
        }

        var retained = WidgetPreferences(density: .comfortable, mediaSize: .large)
        retained.toggleFeedCompact()
        retained.appearance = .light
        retained.textSize = .large
        retained.imageFit = .fit
        retained.toggleFeedCompact()
        try expect(retained == WidgetPreferences(appearance: .light, textSize: .large, imageFit: .fit, mediaSize: .large),
                   "Unrelated changes made while compacted must survive restoring the expanded layout")

        for field in ["density", "mediaSize", "showsMedia"] {
            var manuallyEdited = WidgetPreferences(density: .comfortable, mediaSize: .large)
            manuallyEdited.toggleFeedCompact()
            switch field {
            case "density": manuallyEdited.density = .compact
            case "mediaSize": manuallyEdited.mediaSize = .standard
            default: manuallyEdited.showsMedia = false
            }
            manuallyEdited.clearExpandedLayout()
            manuallyEdited.toggleFeedCompact()
            try expect(manuallyEdited.density == .comfortable && manuallyEdited.mediaSize == .standard,
                       "An explicit \(field) edit must discard the old Large media restoration state")
        }
        let malformedMemory = Data("{\"density\":\"compact\",\"expandedLayout\":{\"density\":\"future\",\"mediaSize\":\"large\"}}".utf8)
        var fallback = try JSONDecoder().decode(WidgetPreferences.self, from: malformedMemory)
        fallback.toggleFeedCompact()
        try expect(fallback.density == .comfortable && fallback.mediaSize == .standard,
                   "An unknown remembered layout must safely fall back to the existing Compact expansion behavior")

        let directory = root.appendingPathComponent("compact-transactions")
        let initial = WidgetPreferences(mediaSize: .large)
        try initial.save(directory: directory)
        let staleWindow = try WidgetPreferences.load(directory: directory)
        let compacted = try WidgetPreferences.update(directory: directory) { $0.toggleFeedCompact() }
        try expect(compacted.isFeedCompact, "The transactional toggle must return the values actually written")
        let appearance = staleWindow.appearance == .light ? WidgetPreferences.Appearance.dark : .light
        let patched = try WidgetPreferences.update(directory: directory) { $0.appearance = appearance }
        try expect(patched.isFeedCompact && patched.appearance == appearance,
                   "A field edit from a stale Preferences window must preserve the latest widget compact state")
        let expanded = try WidgetPreferences.update(directory: directory) { $0.toggleFeedCompact() }
        try expect(expanded.mediaSize == .large && expanded.density == .comfortable && expanded.appearance == appearance,
                   "A later toggle must use current storage and preserve an intervening host edit")
        let corrupt = Data("{broken preferences".utf8)
        let file = directory.appendingPathComponent("widget-preferences.json")
        try corrupt.write(to: file)
        var invoked = false
        do {
            _ = try WidgetPreferences.update(directory: directory) { invoked = true; $0.toggleFeedCompact() }
            throw Failure(message: "A compact transaction silently reset corrupt preferences")
        } catch is DecodingError { assertions += 1 }
        try expect(!invoked && tryData(file) == corrupt,
                   "A failed transaction must preserve corrupt bytes and never apply the change")
        try WidgetPreferences().save(directory: directory)

        // Separate processes exercise the file lock, rather than merely serializing
        // Swift closures in this test process. Odd parity proves no toggle was lost.
        var workers: [Process] = []
        for _ in 0..<3 {
            let worker = Process()
            worker.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            worker.arguments = ["--toggle-worker", directory.path, "17"]
            try worker.run()
            workers.append(worker)
        }
        _ = try WidgetPreferences.update(directory: directory) { $0.appearance = .light }
        for worker in workers {
            worker.waitUntilExit()
            try expect(worker.terminationStatus == 0, "Every cross-process compact transaction must succeed")
        }
        let concurrent = try WidgetPreferences.load(directory: directory)
        var expected = WidgetPreferences(appearance: .light)
        expected.toggleFeedCompact()
        try expect(concurrent == expected,
                   "Concurrent host edits and 51 widget toggles must preserve both final parity and unrelated choices")
    }

    static func tryData(_ file: URL) -> Data? { try? Data(contentsOf: file) }
}
