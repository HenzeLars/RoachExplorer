import AppKit

final class WindowController: NSWindowController, NSWindowDelegate {
    private let fileTable = FileTable(frame: .zero)
    private let statusBar = StatusBarView(frame: .zero)
    private let statusBarHeight: CGFloat = 24
    private var currentURL: URL?

    init(startingURL: URL?) {
        let settings = SettingsStore.load()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Roach Explorer"
        window.minSize = NSSize(width: 480, height: 300)
        window.isReleasedWhenClosed = false

        super.init(window: window)

        window.delegate = self

        let contentRect = window.contentLayoutRect
        let scrollView = NSScrollView(
            frame: NSRect(
                x: 0,
                y: statusBarHeight,
                width: contentRect.width,
                height: contentRect.height - statusBarHeight
            )
        )
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.documentView = fileTable
        let contentView = window.contentView ?? NSView()
        contentView.addSubview(scrollView)
        window.contentView = contentView

        statusBar.frame = NSRect(x: 0, y: 0, width: contentRect.width, height: statusBarHeight)
        statusBar.autoresizingMask = [.width, .maxYMargin]
        contentView.addSubview(statusBar)

        fileTable.onSelectionChange = { [weak self] in
            self?.updateStatusBar()
        }
        window.initialFirstResponder = fileTable

        if let frame = settings.windowFrame {
            window.setFrame(
                NSRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height),
                display: false
            )
        } else {
            window.center()
        }

        show(folder: resolveStartURL(override: startingURL, settings: settings))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// `ROACH_START_PATH` override, then the saved last path if it still exists,
    /// then the home directory.
    private func resolveStartURL(override: URL?, settings: Settings) -> URL {
        let fileManager = FileManager.default
        if let override, fileManager.fileExists(atPath: override.path) {
            return override
        }
        if let lastPath = settings.lastPath,
           fileManager.fileExists(atPath: lastPath) {
            return URL(fileURLWithPath: lastPath)
        }
        return fileManager.homeDirectoryForCurrentUser
    }

    func show(folder url: URL) {
        fileTable.items = FileSystem.listItems(in: url)
        currentURL = url
        window?.title = url.lastPathComponent
        updateStatusBar()
    }

    /// "12 items", or "12 items, 3 selected, 4 KB" with a selection.
    /// Folders count as 0 bytes: the size column shows "—" for them,
    /// and a recursive folder size is not a first-round thing.
    private func updateStatusBar() {
        let count = fileTable.items.count
        var text = count == 1 ? "1 item" : "\(count) items"
        let selected = fileTable.selectedItems
        if !selected.isEmpty {
            text += ", \(selected.count) selected"
            let bytes = selected.reduce(Int64(0)) { $0 + ($1.isFolder ? 0 : $1.size) }
            text += ", \(Format.size(bytes))"
        }
        statusBar.text = text
    }

    func windowWillClose(_ notification: Notification) {
        guard let window, let currentURL else { return }
        var settings = SettingsStore.load()
        settings.lastPath = currentURL.path
        let frame = window.frame
        settings.windowFrame = WindowFrame(
            x: frame.origin.x,
            y: frame.origin.y,
            width: frame.width,
            height: frame.height
        )
        SettingsStore.save(settings)
    }
}
