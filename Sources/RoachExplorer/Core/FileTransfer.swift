import Foundation

/// What a paste will do with the files on the clipboard.
enum TransferKind {
    case copy
    case move
}

enum CollisionChoice {
    case replace
    case keepBoth
    case skip
}

/// Copy or move a batch of files. Collisions are reported as they happen,
/// not scanned up front. A move onto another volume copies, then deletes
/// the original only if the copy finished.
final class FileTransfer {
    private let lock = NSLock()
    private var cancelled = false
    private var applyToAll = false
    private var policy: CollisionChoice?

    var onProgress: ((String, Int, Int) -> Void)?
    /// Called off the main thread. Must not return until the user has chosen.
    /// Nil means the question was cancelled.
    var onCollision: ((String) -> CollisionChoice?)?
    /// Sources that were actually moved. Still valid if a later item fails.
    private(set) var movedSources: [URL] = []

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func decide(_ choice: CollisionChoice) {
        lock.lock()
        policy = choice
        applyToAll = true
        lock.unlock()
    }

    func run(sources: [URL], kind: TransferKind, into destination: URL) throws -> [URL] {
        var moved: [URL] = []
        for (index, source) in sources.enumerated() {
            if isCancelled { throw TransferError.cancelled }
            let name = source.lastPathComponent
            onProgress?(name, index, sources.count)
            if try transfer(source, named: name, kind: kind, into: destination) != nil, kind == .move {
                movedSources.append(source)
            }
        }
        onProgress?("", sources.count, sources.count)
        return movedSources
    }

    /// The URL that received the item, or nil if it was skipped.
    private func transfer(_ source: URL, named name: String, kind: TransferKind, into destination: URL) throws -> URL? {
        if isInside(destination, of: source) {
            throw TransferError.message("You can't move a folder into itself.")
        }
        let existing = destination.appendingPathComponent(name)
        let sourcePath = source.standardizedFileURL.path
        let existingPath = existing.standardizedFileURL.path
        if kind == .move, sourcePath == existingPath {
            return nil
        }
        var target = existing
        if FileManager.default.fileExists(atPath: existing.path) {
            let choice = try choiceForCollision(named: name)
            switch choice {
            case .skip:
                return nil
            case .replace:
                try FileManager.default.removeItem(at: existing)
            case .keepBoth:
                target = uniqueKeepBoth(named: name, in: destination)
            }
        }
        if isCancelled { throw TransferError.cancelled }
        if kind == .move, sameVolume(source, target) {
            try FileManager.default.moveItem(at: source, to: target)
        } else {
            try copyReplacing(from: source, to: target)
            if kind == .move {
                if isCancelled {
                    try? FileManager.default.removeItem(at: target)
                    throw TransferError.cancelled
                }
                try FileManager.default.removeItem(at: source)
            }
        }
        return target
    }

    private func choiceForCollision(named name: String) throws -> CollisionChoice {
        lock.lock()
        let decided = applyToAll ? policy : nil
        lock.unlock()
        if let decided { return decided }
        guard let onCollision else { return .skip }
        guard let choice = onCollision(name) else { throw TransferError.cancelled }
        return choice
    }

    private func copyReplacing(from source: URL, to target: URL) throws {
        do {
            try copyItem(from: source, to: target)
        } catch {
            try? FileManager.default.removeItem(at: target)
            throw error
        }
    }

    /// Copies the item itself. A symlink stays a symlink. It is not followed.
    private func copyItem(from source: URL, to target: URL) throws {
        if isCancelled { throw TransferError.cancelled }
        if let values = try? source.resourceValues(forKeys: [.isSymbolicLinkKey]),
           values.isSymbolicLink == true {
            let link = try FileManager.default.destinationOfSymbolicLink(atPath: source.path)
            try FileManager.default.createSymbolicLink(atPath: target.path, withDestinationPath: link)
            return
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDir) else {
            throw CocoaError(.fileNoSuchFile)
        }
        if isDir.boolValue {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
            let children = try FileManager.default.contentsOfDirectory(
                at: source,
                includingPropertiesForKeys: nil
            )
            for child in children {
                if isCancelled { throw TransferError.cancelled }
                try copyItem(from: child, to: target.appendingPathComponent(child.lastPathComponent))
            }
            return
        }
        guard let input = InputStream(url: source),
              let output = OutputStream(url: target, append: false) else {
            throw CocoaError(.fileWriteUnknown)
        }
        input.open()
        output.open()
        defer {
            input.close()
            output.close()
        }
        let size = 256 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        defer { buffer.deallocate() }
        while input.hasBytesAvailable {
            if isCancelled { throw TransferError.cancelled }
            let count = input.read(buffer, maxLength: size)
            if count < 0 { throw input.streamError ?? CocoaError(.fileReadUnknown) }
            if count == 0 { break }
            var written = 0
            while written < count {
                let chunk = output.write(buffer.advanced(by: written), maxLength: count - written)
                if chunk < 0 { throw output.streamError ?? CocoaError(.fileWriteUnknown) }
                if chunk == 0 { break }
                written += chunk
            }
        }
    }

    private var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    private func isInside(_ url: URL, of folder: URL) -> Bool {
        let child = url.standardizedFileURL.path
        let parent = folder.standardizedFileURL.path
        return child == parent || child.hasPrefix(parent + "/")
    }

    private func sameVolume(_ a: URL, _ b: URL) -> Bool {
        let key = URLResourceKey.volumeUUIDStringKey
        let left = try? a.resourceValues(forKeys: [key]).volumeUUIDString
        let right = try? b.resourceValues(forKeys: [key]).volumeUUIDString
        if let left, let right { return left == right }
        return false
    }

    /// `notes.md` → `notes copy.md`, then `notes copy 2.md`.
    private func uniqueKeepBoth(named name: String, in folder: URL) -> URL {
        let ns = name as NSString
        let ext = ns.pathExtension
        let stem = ns.deletingPathExtension
        func candidate(_ number: Int) -> String {
            let suffix = number == 1 ? " copy" : " copy \(number)"
            if ext.isEmpty { return stem + suffix }
            return stem + suffix + "." + ext
        }
        var number = 1
        while true {
            let url = folder.appendingPathComponent(candidate(number))
            if !FileManager.default.fileExists(atPath: url.path) { return url }
            number += 1
        }
    }
}

enum TransferError: LocalizedError {
    case cancelled
    case message(String)

    var errorDescription: String? {
        switch self {
        case .cancelled:
            return nil
        case .message(let text):
            return text
        }
    }
}
