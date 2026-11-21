import AppKit
import Darwin

/// A path Terminal, iTerm, and Warp can insert. Single quotes, so spaces,
/// quotes, unicode, and newlines stay one argument.
enum ShellPath {
    static func escape(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func join(_ urls: [URL]) -> String {
        urls.map { escape($0.path) }.joined(separator: " ")
    }
}

enum DragFiles {
    static func urls(from pasteboard: NSPasteboard) -> [URL] {
        pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
    }

    /// Option copies. Otherwise a move, unless the source only offered a copy.
    static func operation(for info: NSDraggingInfo) -> NSDragOperation {
        let mask = info.draggingSourceOperationMask
        let option = NSEvent.modifierFlags.contains(.option)
        if option, mask.contains(.copy) { return .copy }
        if mask.contains(.move), !option { return .move }
        if mask.contains(.copy) { return .copy }
        if mask.contains(.move) { return .move }
        return []
    }

    static func wantsCopy(_ info: NSDraggingInfo) -> Bool {
        operation(for: info) == .copy
    }
}

enum DropTarget {
    /// A real directory. A symlink is followed once, the same way Open does.
    static func folder(resolving url: URL) -> URL? {
        let resolved = url.resolvingSymlinksInPath()
        var info = stat()
        guard stat(resolved.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { return nil }
        return resolved
    }

    /// False when a dragged folder would land inside itself.
    static func canDrop(_ urls: [URL], into destination: URL) -> Bool {
        guard !urls.isEmpty else { return false }
        let dest = destination.standardizedFileURL.path
        for url in urls {
            let path = url.standardizedFileURL.path
            if path == dest || dest.hasPrefix(path + "/") { return false }
        }
        return true
    }
}
