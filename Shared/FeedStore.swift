import Foundation

enum FeedStoreError: LocalizedError {
    case groupUnavailable
    case notDirectory(URL)
    case readFailed(URL, Error)
    case writeFailed(URL, Error)

    var errorDescription: String? {
        switch self {
        case .groupUnavailable:
            return "FeedBar's shared storage is unavailable. Open FeedBar to check the installation."
        case .notDirectory(let url):
            return "The feed storage location is not a folder: \(url.path)"
        case .readFailed(_, let error):
            return "Could not read the saved feed: \(error.localizedDescription)"
        case .writeFailed(_, let error):
            return "Could not save the feed: \(error.localizedDescription)"
        }
    }
}

struct FeedStore {
    /// An explicit directory is for tests/export tools. Production uses only the entitled App Group.
    static func storageDirectory(override directory: URL? = nil) throws -> URL {
        if let directory { return directory }
        guard let group = FeedBarConstants.appGroupID,
              let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: group
        ) else { throw FeedStoreError.groupUnavailable }
        return container
    }

    static func load(directory: URL? = nil) throws -> FeedSnapshot {
        let folder = try storageDirectory(override: directory)
        let url = folder.appendingPathComponent(FeedBarConstants.feedFileName)
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .custom { decoder in
                let value = try decoder.singleValueContainer().decode(String.self)
                guard let date = FeedTimestamp.parse(value) else {
                    throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                        debugDescription: "Invalid ISO 8601 timestamp: \(value)"))
                }
                return date
            }
            return try decoder.decode(FeedSnapshot.self, from: data)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            // A missing file is the only condition treated as a new installation.
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), !isDirectory.boolValue {
                throw FeedStoreError.notDirectory(folder)
            }
            return FeedSnapshot()
        } catch {
            throw FeedStoreError.readFailed(url, error)
        }
    }

    static func save(_ snapshot: FeedSnapshot, directory: URL? = nil) throws {
        let folder = try storageDirectory(override: directory)
        let url = folder.appendingPathComponent(FeedBarConstants.feedFileName)
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(snapshot)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            // Readers see either the complete previous version or the complete replacement.
            try data.write(to: url, options: .atomic)
        } catch {
            throw FeedStoreError.writeFailed(url, error)
        }
    }
}
