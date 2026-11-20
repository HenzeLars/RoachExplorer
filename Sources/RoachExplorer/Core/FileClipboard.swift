import AppKit

extension Notification.Name {
    static let fileClipboardChanged = Notification.Name("FileClipboardChanged")
}

/// Files copied or cut in this app. An outside copy replaces a cut:
/// the pasteboard change count no longer matches, so the dimming goes away.
final class FileClipboard {
    static let shared = FileClipboard()

    private(set) var kind: TransferKind = .copy
    private var urls: [URL] = []
    private var writtenChangeCount = -1

    func write(_ urls: [URL], kind: TransferKind) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(urls as [NSURL])
        writtenChangeCount = pasteboard.changeCount
        self.urls = urls
        self.kind = kind
        NotificationCenter.default.post(name: .fileClipboardChanged, object: nil)
    }

    func clearCut() {
        guard kind == .move else { return }
        NSPasteboard.general.clearContents()
        kind = .copy
        urls = []
        writtenChangeCount = NSPasteboard.general.changeCount
        NotificationCenter.default.post(name: .fileClipboardChanged, object: nil)
    }

    /// Cut URLs that should be dimmed, if the pasteboard still holds our cut.
    var cutPaths: Set<String> {
        guard let current = current(), current.kind == .move else { return [] }
        return Set(current.urls.map { $0.standardizedFileURL.path })
    }

    var canPaste: Bool {
        current() != nil
    }

    func current() -> (kind: TransferKind, urls: [URL])? {
        let pasteboard = NSPasteboard.general
        if pasteboard.changeCount == writtenChangeCount {
            return urls.isEmpty ? nil : (kind, urls)
        }
        guard let external = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !external.isEmpty else { return nil }
        return (.copy, external)
    }
}
