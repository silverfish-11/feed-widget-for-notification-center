import Foundation
import Darwin

@main
struct SharedRegressionTests {
    static var assertions = 0

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        assertions += 1
        guard condition() else { throw Failure(message: message) }
    }

    struct Failure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    static func post(_ id: String, platform: String = "x", time: Date) -> FeedPost {
        FeedPost(id: id, platform: platform, author: "Test", handle: "test", text: "Fixture post",
                 timestamp: time, likes: 1, reposts: 0, comments: 0)
    }


    // Run the real storage code in independent processes, like simultaneous
    // AppIntent executions. A shared start gate keeps the writes overlapping.
    static func runPageWorkerIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard args.count == 6, args[1] == "--page-worker" else { return false }
        let directory = URL(fileURLWithPath: args[3], isDirectory: true)
        guard let size = Int(args[4]), let iterations = Int(args[5]) else { exit(2) }
        _ = FileHandle.standardInput.readData(ofLength: 1)
        do {
            for step in 1...iterations {
                if args[2] == "set" {
                    try PageState.setPage(step, pageSize: size, directory: directory)
                } else {
                    try PageState.advance(by: 1, totalPosts: 10_000, pageSize: size, directory: directory)
                }
            }
        } catch {
            FileHandle.standardError.write(Data("Page worker failed: \(error)\n".utf8))
            exit(1)
        }
        return true
    }

    static func runPageWorkers(mode: String, sizes: [Int], iterations: Int, directory: URL) throws {
        var workers: [(Process, Pipe)] = []
        for size in sizes {
            let process = Process()
            let gate = Pipe()
            process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            process.arguments = ["--page-worker", mode, directory.path, String(size), String(iterations)]
            process.standardInput = gate
            try process.run()
            workers.append((process, gate))
        }
        for (_, gate) in workers {
            gate.fileHandleForWriting.write(Data([1]))
            try gate.fileHandleForWriting.close()
        }
        for (process, _) in workers {
            process.waitUntilExit()
            try expect(process.terminationStatus == 0, "Each concurrent page worker must finish successfully")
        }
    }

    static func testPageRecoveryAndConcurrency(directory: URL) throws {
        let setDirectory = directory.appendingPathComponent("concurrent-set")
        try runPageWorkers(mode: "set", sizes: [1, 2, 4], iterations: 500, directory: setDirectory)
        for size in [1, 2, 4] {
            let saved = try PageState.page(pageSize: size, directory: setDirectory)
            try expect(saved == 500, "Concurrent saves must retain the last position for page size \(size)")
        }

        let advanceDirectory = directory.appendingPathComponent("concurrent-advance")
        try runPageWorkers(mode: "advance", sizes: [1, 1, 2, 4], iterations: 200, directory: advanceDirectory)
        for (size, expected) in [(1, 400), (2, 200), (4, 200)] {
            let saved = try PageState.page(pageSize: size, directory: advanceDirectory)
            try expect(saved == expected, "Concurrent page actions must accumulate for page size \(size)")
        }

        let boundsDirectory = directory.appendingPathComponent("page-bounds")
        var moved = try PageState.advance(by: -1, totalPosts: 7, pageSize: 3, directory: boundsDirectory)
        try expect(moved == 0, "Previous on the first page must remain on the first page")
        moved = try PageState.advance(by: Int.max, totalPosts: 7, pageSize: 3, directory: boundsDirectory)
        try expect(moved == 2, "Advancing beyond the last page must clamp")
        moved = try PageState.advance(by: Int.max, totalPosts: 7, pageSize: 3, directory: boundsDirectory)
        try expect(moved == 2, "An overflowing page movement must safely clamp")
        moved = try PageState.advance(by: -1, totalPosts: 4, pageSize: 3, directory: boundsDirectory)
        try expect(moved == 0, "After the feed shrinks, previous must move from the visible clamped page")
        moved = try PageState.advance(by: Int.min, totalPosts: 7, pageSize: 3, directory: boundsDirectory)
        try expect(moved == 0, "Large negative movement must safely clamp")

        let recoveryDirectory = directory.appendingPathComponent("page-recovery")
        try FileManager.default.createDirectory(at: recoveryDirectory, withIntermediateDirectories: true)
        let file = recoveryDirectory.appendingPathComponent("widget-pages.json")
        let malformed = Data("{\"1\": 8, interrupted write".utf8)
        try malformed.write(to: file)
        let recovered = try PageState.page(pageSize: 1, directory: recoveryDirectory)
        try expect(recovered == 0, "Malformed pagination metadata must recover to the first page")
        let backups = try FileManager.default.contentsOfDirectory(at: recoveryDirectory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("widget-pages.corrupt-") }
        try expect(backups.count == 1, "Recovery must save one uniquely named backup of malformed metadata")
        let original = try Data(contentsOf: backups[0])
        try expect(original == malformed, "The recovery backup must retain the exact original bytes")
        let repaired = try JSONDecoder().decode([String: Int].self, from: Data(contentsOf: file))
        try expect(repaired.isEmpty, "Recovery must replace malformed metadata with valid initial state")
        moved = try PageState.advance(by: 1, totalPosts: 7, pageSize: 1, directory: recoveryDirectory)
        try expect(moved == 1, "Page actions must work immediately after metadata recovery")
        _ = try PageState.page(pageSize: 1, directory: recoveryDirectory)
        let backupsAfterRead = try FileManager.default.contentsOfDirectory(atPath: recoveryDirectory.path)
            .filter { $0.hasPrefix("widget-pages.corrupt-") }
        try expect(backupsAfterRead.count == 1, "Subsequent valid reads must not produce more corruption backups")

        // A storage error is not a decoding error and must never reset state.
        let storageErrorDirectory = directory.appendingPathComponent("page-storage-error")
        let inaccessibleFile = storageErrorDirectory.appendingPathComponent("widget-pages.json")
        try FileManager.default.createDirectory(at: inaccessibleFile, withIntermediateDirectories: true)
        var readFailed = false
        do {
            _ = try PageState.page(pageSize: 1, directory: storageErrorDirectory)
        } catch { readFailed = true }
        try expect(readFailed, "A page storage I/O error must propagate rather than recover as corruption")
        let errorFiles = try FileManager.default.contentsOfDirectory(atPath: storageErrorDirectory.path)
        try expect(!errorFiles.contains { $0.hasPrefix("widget-pages.corrupt-") }, "Storage failures must not be mislabeled as malformed metadata")
    }

    static func main() throws {
        if runPageWorkerIfRequested() { return }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FeedBarTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // The standalone test executable has no bundled App Group setting.
        // Missing build configuration must fail before any container lookup,
        // while explicit isolated storage remains available.
        try expect(FeedBarConstants.appGroupID == nil, "Tests must not inherit a production App Group")
        do {
            _ = try FeedStore.storageDirectory()
            throw Failure(message: "Missing App Group configuration was accepted")
        } catch FeedStoreError.groupUnavailable {
            assertions += 1
        }
        let isolated = try FeedStore.storageDirectory(override: directory)
        try expect(isolated == directory, "An explicit test directory must work without App Group configuration")

        let old = Date(timeIntervalSince1970: 1_700_000_000)
        let newer = old.addingTimeInterval(60)
        let newest = old.addingTimeInterval(120)

        let first = try FeedStore.load(directory: directory)
        try expect(first.posts.isEmpty, "A missing snapshot should be a clean, empty installation")

        var snapshot = FeedSnapshot(sources: [
            "x": FeedSourceState(posts: [post("123", time: old)], status: "ready", lastSuccess: old),
            "ig": FeedSourceState(posts: [post("abc", platform: "ig", time: newer)], status: "ready", lastSuccess: newer)
        ], updatedAt: newer)
        try FeedStore.save(snapshot, directory: directory)
        let restored = try FeedStore.load(directory: directory)
        try expect(restored.posts.count == 2, "Both source caches must survive serialization")
        try expect(restored.posts.first?.id == "abc", "Merged snapshots must be newest first")
        try expect(restored.sources["x"]?.lastSuccess == old, "The saved success time must round-trip")

        // A source failure must be representable without destroying its previously saved posts.
        snapshot.sources["x"]?.status = "loginRequired"
        snapshot.sources["x"]?.message = "Session expired"
        snapshot.sources["x"]?.lastAttempt = newest
        try FeedStore.save(snapshot, directory: directory)
        let failedSource = try FeedStore.load(directory: directory)
        try expect(failedSource.posts.count == 2, "A failed source must retain its cache")
        try expect(failedSource.sources["x"]?.status == "loginRequired", "Failure status must survive serialization")
        try expect(failedSource.sources["x"]?.lastSuccess == old, "A failed attempt must not change the success timestamp")

        // Corruption must not silently turn into an empty feed or overwrite the evidence.
        let file = directory.appendingPathComponent(FeedBarConstants.feedFileName)
        let corrupt = Data("not JSON".utf8)
        try corrupt.write(to: file, options: .atomic)
        do {
            _ = try FeedStore.load(directory: directory)
            throw Failure(message: "Corrupt storage was silently accepted")
        } catch is FeedStoreError {
            assertions += 1
        }
        let retained = try Data(contentsOf: file)
        try expect(retained == corrupt, "Failed reads must leave the existing file untouched")
        try FeedStore.save(snapshot, directory: directory)

        // An impossible destination must throw instead of falling back to another store.
        let blockingFile = directory.appendingPathComponent("not-a-directory")
        try Data("blocker".utf8).write(to: blockingFile)
        do {
            try FeedStore.save(snapshot, directory: blockingFile)
            throw Failure(message: "Saving to a file instead of a directory did not throw")
        } catch is FeedStoreError {
            assertions += 1
        }
        let afterFailure = try FeedStore.load(directory: directory)
        try expect(afterFailure.posts.count == 2, "A failed save elsewhere must not damage the saved feed")

        snapshot.sources["duplicate"] = FeedSourceState(posts: [post("123", time: newest), post("123", platform: "ig", time: old)])
        try expect(snapshot.posts.count == 3, "Deduplication must use platform plus post ID")
        try expect(snapshot.posts.first?.timestamp == newest, "The newer version of a duplicate should win")

        let posts = (0..<7).map { post(String($0), time: old) }
        try expect(FeedPagination.pageCount(totalPosts: 7, pageSize: 3) == 3, "Partial pages must remain reachable")
        try expect(FeedPagination.posts(posts, page: 2, pageSize: 3).map(\.id) == ["6"], "Final partial page must contain its remaining post")
        try expect(FeedPagination.posts(posts, page: -3, pageSize: 3).map(\.id) == ["0", "1", "2"], "Negative persisted page indices must be safe")
        try expect(FeedPagination.posts(posts, page: 99, pageSize: 3).map(\.id) == ["6"], "An old page index must clamp after the feed shrinks")
        try expect(FeedPagination.posts([], page: 99, pageSize: 0).isEmpty, "Empty feeds and invalid page sizes must be safe")
        try PageState.setPage(2, pageSize: 1, directory: directory)
        try PageState.setPage(1, pageSize: 4, directory: directory)
        let smallPage = try PageState.page(pageSize: 1, directory: directory)
        let largePage = try PageState.page(pageSize: 4, directory: directory)
        try expect(smallPage == 2 && largePage == 1, "Different widget sizes must retain separate page positions")
        try testPageRecoveryAndConcurrency(directory: directory)

        let wholeSeconds = FeedTimestamp.parse("2026-03-04T12:00:00Z")
        let fractions = FeedTimestamp.parse("2026-03-04T12:00:00.000Z")
        try expect(wholeSeconds != nil && wholeSeconds == fractions, "ISO timestamps with and without fractions must agree")
        try expect(FeedTimestamp.parse("not a date") == nil, "Invalid dates must not become the current time")
        try expect(post("123", time: old).url?.absoluteString == "https://x.com/i/status/123", "X links must not depend on a scraped handle")
        try expect(post("x_0", time: old).url == nil, "Legacy synthetic IDs must not become broken post links")
        try expect(post("ig_0", platform: "ig", time: old).url == nil, "Legacy synthetic Instagram IDs must not become broken post links")
        try expect(post("Ab-c_12", platform: "ig", time: old).url != nil, "Valid Instagram shortcodes should remain linkable")

        let undated = post("124", time: .distantPast)
        try expect(!undated.hasKnownTimestamp && undated.timeAgo == "Date unavailable", "Missing timestamps must not display a fabricated age")

        print("Passed \(assertions) isolated shared-storage, pagination, and timestamp regression checks.")
    }
}
