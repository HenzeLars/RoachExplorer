import Foundation

/// `notes.md` → `notes copy.md`, then `notes copy 2.md`.
/// Shared by Duplicate and the "Keep Both" collision answer.
enum CopyName {
    static func candidate(for name: String, number: Int) -> String {
        let ns = name as NSString
        let ext = ns.pathExtension
        let stem = ns.deletingPathExtension
        let suffix = number == 1 ? " copy" : " copy \(number)"
        if ext.isEmpty { return stem + suffix }
        return stem + suffix + "." + ext
    }
}

/// Picks the next free "name copy" for each item in a duplicate batch.
/// No questions: a name already on disk, or already chosen earlier in the
/// batch, just moves on to the next number. Called from the copy thread,
/// hence the lock.
final class DuplicateNamer {
    private let folder: URL
    private let lock = NSLock()
    private var taken: Set<String>

    init(existing: [URL], folder: URL) {
        self.folder = folder
        taken = Set(existing.map { $0.standardizedFileURL.path })
    }

    func name(for source: URL) -> String {
        lock.lock()
        defer { lock.unlock() }
        var number = 1
        while true {
            let candidate = CopyName.candidate(for: source.lastPathComponent, number: number)
            let path = folder.appendingPathComponent(candidate).standardizedFileURL.path
            if !taken.contains(path), !FileManager.default.fileExists(atPath: path) {
                taken.insert(path)
                return candidate
            }
            number += 1
        }
    }
}
