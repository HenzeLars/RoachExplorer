import Darwin
import Foundation

/// Total size of a selection, including everything inside real folders.
/// Symlinks are counted as the link itself and are not followed.
struct SummaryTally {
    var bytes: Int64 = 0
    var files: Int = 0
    var unreadable: Int = 0
}

final class SummaryWalk {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    private var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    /// `progress` may be called off the main thread.
    func measure(
        items: [(url: URL, isFolder: Bool, isLink: Bool, size: Int64)],
        progress: (Int64) -> Void
    ) -> SummaryTally {
        var tally = SummaryTally()
        for item in items {
            if isCancelled { break }
            if item.isFolder && !item.isLink {
                walk(item.url, into: &tally, progress: progress)
            } else if let info = Self.linkStatus(item.url) {
                tally.bytes += info.bytes
                tally.files += 1
                progress(tally.bytes)
            } else {
                tally.bytes += item.size
                tally.files += 1
                progress(tally.bytes)
            }
        }
        return tally
    }

    private func walk(_ folder: URL, into tally: inout SummaryTally, progress: (Int64) -> Void) {
        let missed = UnreadableCount()
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: nil,
            options: [],
            errorHandler: { _, _ in
                missed.value += 1
                return true
            }
        ) else {
            tally.unreadable += 1
            return
        }
        for case let url as URL in enumerator {
            if isCancelled { return }
            guard let info = Self.linkStatus(url) else {
                tally.unreadable += 1
                continue
            }
            if info.isLink {
                tally.bytes += info.bytes
                tally.files += 1
                enumerator.skipDescendants()
            } else if !info.isDirectory {
                tally.bytes += info.bytes
                tally.files += 1
            }
            progress(tally.bytes)
        }
        tally.unreadable += missed.value
        progress(tally.bytes)
    }

    private static func linkStatus(_ url: URL) -> (bytes: Int64, isDirectory: Bool, isLink: Bool)? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        let type = info.st_mode & S_IFMT
        return (Int64(info.st_size), type == S_IFDIR, type == S_IFLNK)
    }
}

private final class UnreadableCount {
    var value = 0
}
