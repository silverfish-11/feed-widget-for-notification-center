import Foundation
import Darwin

enum FeedPagination {
    static func pageCount(totalPosts: Int, pageSize: Int) -> Int {
        let size = max(pageSize, 1)
        let total = max(totalPosts, 0)
        return max(total / size + (total % size == 0 ? 0 : 1), 1)
    }

    static func clampedPage(_ page: Int, totalPosts: Int, pageSize: Int) -> Int {
        min(max(page, 0), pageCount(totalPosts: totalPosts, pageSize: pageSize) - 1)
    }

    static func posts(_ posts: [FeedPost], page: Int, pageSize: Int) -> [FeedPost] {
        let size = max(pageSize, 1)
        let page = clampedPage(page, totalPosts: posts.count, pageSize: size)
        let start = page * size
        return Array(posts.dropFirst(start).prefix(size))
    }
}

struct PageState {
    private static let processLock = NSLock()

    /// Every reader/writer uses the same lock file: atomic replacement alone
    /// cannot protect a read/modify/write transaction across widget processes.
    private static func withPages<T>(directory: URL?, write: Bool,
                                     _ operation: (inout [String: Int]) throws -> T) throws -> T {
        processLock.lock()
        defer { processLock.unlock() }

        let folder = try FeedStore.storageDirectory(override: directory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let lockURL = folder.appendingPathComponent("widget-pages.lock")
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        while flock(descriptor, LOCK_EX) != 0 {
            if errno != EINTR { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        defer { flock(descriptor, LOCK_UN) }

        let file = folder.appendingPathComponent("widget-pages.json")
        let data: Data?
        do {
            data = try Data(contentsOf: file)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            data = nil
        }

        var pages: [String: Int] = [:]
        var recovered = false
        if let data {
            do {
                pages = try JSONDecoder().decode([String: Int].self, from: data)
            } catch is DecodingError {
                // Pagination is recoverable presentation state, not feed data.
                // Preserve the exact malformed bytes before replacing it. I/O
                // failures above or while backing up continue to throw.
                let backup = folder.appendingPathComponent("widget-pages.corrupt-\(UUID().uuidString).json")
                try data.write(to: backup, options: .atomic)
                recovered = true
            }
        }
        let result = try operation(&pages)
        if write || recovered {
            try JSONEncoder().encode(pages).write(to: file, options: .atomic)
        }
        return result
    }

    static func page(pageSize: Int, directory: URL? = nil) throws -> Int {
        try withPages(directory: directory, write: false) { pages in
            max(pages[String(max(pageSize, 1))] ?? 0, 0)
        }
    }

    static func setPage(_ page: Int, pageSize: Int, directory: URL? = nil) throws {
        try withPages(directory: directory, write: true) { pages in
            pages[String(max(pageSize, 1))] = max(page, 0)
        }
    }

    /// Read, clamp, move and save under one cross-process transaction, so rapid
    /// page actions accumulate instead of overwriting the same starting page.
    @discardableResult
    static func advance(by delta: Int, totalPosts: Int, pageSize: Int,
                        directory: URL? = nil) throws -> Int {
        try withPages(directory: directory, write: true) { pages in
            let size = max(pageSize, 1)
            let key = String(size)
            let current = FeedPagination.clampedPage(pages[key] ?? 0, totalPosts: totalPosts, pageSize: size)
            let (sum, overflow) = current.addingReportingOverflow(delta)
            let requested = overflow ? (delta > 0 ? Int.max : Int.min) : sum
            let next = FeedPagination.clampedPage(requested, totalPosts: totalPosts, pageSize: size)
            pages[key] = next
            return next
        }
    }
}
