import Foundation

/// Search below a folder, off the main thread. The name test is a
/// case-insensitive substring, the same idea as `find -iname '*term*'`.
/// Packages are not descended into, and symlinks are not followed, so a walk
/// cannot loop and bundles stay one row, exactly as in the list.
enum Search {
    static let limit = 2000

    /// True when `name` contains `query`, ignoring case and accents.
    /// A query of nothing matches nothing: an empty search is not a search.
    static func matches(name: String, query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return false }
        return name.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    struct Outcome {
        let count: Int
        let seconds: TimeInterval
        let cancelled: Bool
        let hitLimit: Bool
    }

    /// Walks `root` and everything below it. `onBatch` and `onFinish` are called
    /// on the main queue, in that order, unless the task was cancelled — then a
    /// final `onFinish` still arrives so the caller can tidy up.
    static func start(
        below root: URL,
        query: String,
        limit: Int = limit,
        onBatch: @escaping (_ items: [FileItem]) -> Void,
        onFinish: @escaping (_ outcome: Outcome) -> Void
    ) -> SearchTask {
        let task = SearchTask()
        let started = Date()
        DispatchQueue.global(qos: .userInitiated).async {
            var found = 0
            var pending: [FileItem] = []
            var lastFlush = Date()
            var hitLimit = false

            let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: Array(FileSystem.itemKeys),
                options: [.skipsPackageDescendants],
                errorHandler: { _, _ in true }
            )
            while let url = enumerator?.nextObject() as? URL {
                if task.isCancelled { break }
                guard matches(name: url.lastPathComponent, query: query) else { continue }
                guard let item = FileSystem.item(at: url) else { continue }
                pending.append(item)
                found += 1
                if found >= limit {
                    hitLimit = true
                    break
                }
                // Batches keep the list alive while a big tree is being walked.
                if pending.count >= 100 || Date().timeIntervalSince(lastFlush) > 0.12 {
                    let batch = pending
                    pending = []
                    lastFlush = Date()
                    DispatchQueue.main.async { onBatch(batch) }
                }
            }
            if !pending.isEmpty {
                let batch = pending
                DispatchQueue.main.async { onBatch(batch) }
            }
            let outcome = Outcome(
                count: found,
                seconds: Date().timeIntervalSince(started),
                cancelled: task.isCancelled,
                hitLimit: hitLimit
            )
            DispatchQueue.main.async { onFinish(outcome) }
        }
        return task
    }
}

/// A running walk. `cancel()` is safe from any thread; the walk stops at the
/// next entry it looks at.
final class SearchTask {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}
