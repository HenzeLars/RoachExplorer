import AppKit
import Darwin

final class WindowController: NSWindowController, NSWindowDelegate {
    private let fileTable = FileTable(frame: .zero)
    private let pathBar = PathBar(frame: .zero)
    private let statusBar = StatusBarView(frame: .zero)
    private let statusBarHeight: CGFloat = 24
    private var currentURL: URL?
    private var backStack: [URL] = []
    private var forwardStack: [URL] = []
    private var watchSource: DispatchSourceFileSystemObject?
    private var reloadScheduled = false
    /// A second window, for "open all" of several folders. The app delegate sets this.
    var onOpenWindow: ((URL) -> Void)?

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
        let pathHeight = PathBar.preferredHeight
        let scrollView = NSScrollView(
            frame: NSRect(
                x: 0,
                y: statusBarHeight,
                width: contentRect.width,
                height: contentRect.height - statusBarHeight - pathHeight
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

        pathBar.frame = NSRect(
            x: 0,
            y: contentRect.height - pathHeight,
            width: contentRect.width,
            height: pathHeight
        )
        pathBar.autoresizingMask = [.width, .minYMargin]
        contentView.addSubview(pathBar)
        pathBar.onNavigate = { [weak self] url in
            self?.show(folder: url)
        }
        pathBar.onBack = { [weak self] in self?.goBack(nil) }
        pathBar.onForward = { [weak self] in self?.goForward(nil) }
        pathBar.onReload = { [weak self] in self?.reload(nil) }
        pathBar.onFinishEditing = { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self.fileTable)
        }

        fileTable.onSelectionChange = { [weak self] in
            self?.updateStatusBar()
        }
        fileTable.onOpenRow = { [weak self] row, option in
            self?.open(row: row, option: option)
        }
        fileTable.onOpenSelection = { [weak self] option in
            self?.openSelection(option: option)
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

        show(folder: resolveStartURL(override: startingURL, settings: settings), remember: false)
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

    /// The folder this window is showing. A new window starts here.
    var currentFolder: URL? { currentURL }

    /// `remember` is false for back, forward, reload-into-a-missing-folder, and the
    /// first show. A vanished folder is replaced by the nearest parent that exists.
    func show(folder url: URL, remember: Bool = true) {
        let destination = nearestExistingAncestor(of: url)
        if remember, let current = currentURL, current != destination {
            backStack.append(current)
            forwardStack.removeAll()
        }
        while backStack.last == destination {
            backStack.removeLast()
        }
        fileTable.items = FileSystem.listItems(in: destination)
        currentURL = destination
        window?.title = destination.path == "/" ? "/" : destination.lastPathComponent
        pathBar.show(url: destination)
        updateStatusBar()
        pathBar.setNavigation(canGoBack: !backStack.isEmpty, canGoForward: !forwardStack.isEmpty)
        watch(destination)
    }

    @objc func goBack(_ sender: Any?) {
        guard let current = currentURL, let previous = backStack.popLast() else { return }
        forwardStack.append(current)
        show(folder: previous, remember: false)
    }

    @objc func goForward(_ sender: Any?) {
        guard let current = currentURL, let next = forwardStack.popLast() else { return }
        backStack.append(current)
        show(folder: next, remember: false)
    }

    /// Cmd+Up. The root has no parent.
    @objc func goUp(_ sender: Any?) {
        guard let current = currentURL?.standardizedFileURL else { return }
        let parent = current.deletingLastPathComponent().standardizedFileURL
        if parent == current { return }
        show(folder: parent)
    }

    /// Cmd+R, and the folder watcher. Selection survives: the table reselects by URL.
    @objc func reload(_ sender: Any?) {
        guard let currentURL else { return }
        if !isExistingDirectory(currentURL) {
            show(folder: currentURL, remember: false)
            return
        }
        fileTable.items = FileSystem.listItems(in: currentURL)
        updateStatusBar()
    }

    @objc func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(goBack(_:)):
            return !backStack.isEmpty
        case #selector(goForward(_:)):
            return !forwardStack.isEmpty
        case #selector(goUp(_:)):
            return currentURL?.standardizedFileURL.path != "/"
        case #selector(openSelection(_:)), #selector(openFocusedFolder(_:)):
            return !pathBar.isEditingField
        default:
            return true
        }
    }

    /// Double-click. Only the clicked row, even if others are selected.
    private func open(row: Int, option: Bool) {
        guard row >= 0, row < fileTable.items.count else { return }
        open(fileTable.items[row], option: option, foldersInNewWindow: false)
    }

    /// Return, Enter, or Cmd+O. One item opens. Several ask first.
    @objc func openSelection(_ sender: Any?) {
        let option = NSApp.currentEvent?.modifierFlags.contains(.option) ?? false
        openSelection(option: option)
    }

    /// Cmd+Down. The focused row, and only if it is a folder. No dialog.
    @objc func openFocusedFolder(_ sender: Any?) {
        let row = fileTable.selectedRow
        guard row >= 0, row < fileTable.items.count else { return }
        let item = fileTable.items[row]
        guard resolvedFolder(item) != nil else { return }
        open(item, option: false, foldersInNewWindow: false)
    }

    private func openSelection(option: Bool) {
        let items = fileTable.selectedItems
        guard !items.isEmpty else { return }
        if items.count == 1 {
            open(items[0], option: option, foldersInNewWindow: false)
            return
        }
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Open all at once?"
        alert.addButton(withTitle: "Yes")
        alert.addButton(withTitle: "No")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.openAll(items, option: option)
        }
    }

    private func openAll(_ items: [FileItem], option: Bool) {
        for item in items {
            open(item, option: option, foldersInNewWindow: true)
        }
    }

    /// A folder is entered. A package is launched. A file opens in its default app,
    /// or in Terminal when Option is held and nothing claims it.
    private func open(_ item: FileItem, option: Bool, foldersInNewWindow: Bool) {
        if let folder = resolvedFolder(item) {
            if foldersInNewWindow {
                onOpenWindow?(folder)
            } else {
                show(folder: folder)
            }
            return
        }
        let url = item.url.resolvingSymlinksInPath()
        if option, !isPackage(url), NSWorkspace.shared.urlForApplication(toOpen: url) == nil {
            runInTerminal(url)
            return
        }
        NSWorkspace.shared.open(url)
    }

    /// The folder to enter, following a symlink. Nil for a file or a package.
    private func resolvedFolder(_ item: FileItem) -> URL? {
        if item.isPackage { return nil }
        let url = item.url.resolvingSymlinksInPath()
        if isPackage(url) { return nil }
        return isExistingDirectory(url) ? url : nil
    }

    private func isPackage(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isPackageKey]))?.isPackage ?? false
    }

    private func runInTerminal(_ url: URL) {
        let shell = "'" + url.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        var apple = ""
        for character in shell {
            if character == "\\" || character == "\"" {
                apple.append("\\")
            }
            apple.append(character)
        }
        let source = "tell application \"Terminal\" to do script \"\(apple)\""
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
    }

    /// Cmd+L. The field is already on screen; this only focuses it.
    @objc func focusPath(_ sender: Any?) {
        pathBar.focusField()
    }

    private func nearestExistingAncestor(of url: URL) -> URL {
        var candidate = url.standardizedFileURL
        if isExistingDirectory(candidate) { return candidate }
        while candidate.path != "/" {
            candidate = candidate.deletingLastPathComponent().standardizedFileURL
            if isExistingDirectory(candidate) { return candidate }
        }
        let root = URL(fileURLWithPath: "/")
        if isExistingDirectory(root) { return root }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    private func isExistingDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    private func watch(_ url: URL) {
        watchSource?.cancel()
        watchSource = nil
        let fd = Darwin.open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .revoke],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.scheduleReload()
        }
        source.setCancelHandler {
            Darwin.close(fd)
        }
        source.resume()
        watchSource = source
    }

    private func scheduleReload() {
        if reloadScheduled { return }
        reloadScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.reloadScheduled = false
            self?.reload(nil)
        }
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
        watchSource?.cancel()
        watchSource = nil
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
