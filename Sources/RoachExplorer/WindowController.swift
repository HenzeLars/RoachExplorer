import AppKit
import Darwin
import QuickLookUI
import UniformTypeIdentifiers

/// Counts working time only. A collision question pauses it, so a slow
/// decision does not bring up the progress window.
private final class WorkClock {
    var onFire: (() -> Void)?
    private var accumulated: TimeInterval = 0
    private var started: Date?
    private var pending: DispatchWorkItem?
    private let limit: TimeInterval = 5

    func resume() {
        guard started == nil else { return }
        started = Date()
        let remaining = max(0.01, limit - accumulated)
        let work = DispatchWorkItem { [weak self] in
            self?.pending = nil
            self?.onFire?()
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + remaining, execute: work)
    }

    func pause() {
        if let started {
            accumulated += Date().timeIntervalSince(started)
        }
        started = nil
        pending?.cancel()
        pending = nil
    }

    func cancel() {
        pause()
        accumulated = 0
    }
}

final class WindowController: NSWindowController, NSWindowDelegate {
    private let fileTable = FileTable(frame: .zero)
    private let pathBar = PathBar(frame: .zero)
    private let statusBar = StatusBarView(frame: .zero)
    private let sidebar = Sidebar(frame: .zero)
    private let scrollView = NSScrollView(frame: .zero)
    private let filterBar = FilterBar(frame: .zero)
    private var filterVisible = false
    private let statusBarHeight: CGFloat = 24
    private let fileUndoManager = UndoManager()
    private var previewKeyMonitor: Any?
    private var currentURL: URL?
    private var backStack: [URL] = []
    private var forwardStack: [URL] = []
    private var watchSource: DispatchSourceFileSystemObject?
    private var reloadScheduled = false
    private var ignoreWatchUntil = Date.distantPast
    private var swipeMonitor: Any?
    private var lastSwipe = Date.distantPast
    private var trackingSwipe = false
    /// A folder we just created. Escape deletes it. Return keeps it.
    private var creatingURL: URL?
    private var infoWindow: InfoWindow?
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
        window.minSize = NSSize(width: 720, height: 320)
        window.isReleasedWhenClosed = false

        super.init(window: window)

        window.delegate = self

        let contentView = window.contentView ?? NSView()
        window.contentView = contentView

        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets()
        scrollView.clipsToBounds = true
        scrollView.documentView = fileTable
        contentView.addSubview(scrollView)

        contentView.addSubview(sidebar)
        sidebar.setFavorites(settings.favorites)
        sidebar.onNavigate = { [weak self] url in
            guard let self else { return }
            self.show(folder: url)
            self.window?.makeFirstResponder(self.fileTable)
        }
        sidebar.onDrop = { [weak self] urls, destination, copying in
            self?.startTransfer(sources: urls, kind: copying ? .copy : .move, into: destination)
        }
        sidebar.onFavoritesChanged = { paths in
            var stored = SettingsStore.load()
            stored.favorites = paths
            SettingsStore.save(stored)
        }

        contentView.addSubview(statusBar)
        contentView.addSubview(pathBar)
        contentView.addSubview(filterBar)

        filterBar.onChange = { [weak self] text in
            guard let self else { return }
            self.fileTable.filterText = text
            self.updateStatusBar()
        }
        filterBar.onCancel = { [weak self] in
            self?.setFilterVisible(false)
        }

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
        fileTable.onRename = { [weak self] in
            self?.renameSelection(nil)
        }
        fileTable.onQuickLook = { [weak self] in
            self?.toggleQuickLook(nil)
        }
        fileTable.onCanCommitEdit = { [weak self] url, name in
            self?.canCommit(url: url, name: name) ?? true
        }
        fileTable.onEditEnded = { [weak self] url, name, cancelled in
            self?.finishEdit(url: url, name: name, cancelled: cancelled)
        }
        fileTable.onCancelCut = { [weak self] in
            self?.cancelCut()
        }
        fileTable.onTrash = { [weak self] in
            self?.moveToTrash(nil)
        }
        fileTable.onDrop = { [weak self] urls, destination, copying in
            self?.startTransfer(sources: urls, kind: copying ? .copy : .move, into: destination)
        }
        pathBar.onDrop = { [weak self] urls, destination, copying in
            self?.startTransfer(sources: urls, kind: copying ? .copy : .move, into: destination)
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(clipboardChanged(_:)),
            name: .fileClipboardChanged,
            object: nil
        )
        window.initialFirstResponder = fileTable
        installSwipeMonitor()
        installPreviewKeyMonitor()

        if let frame = settings.windowFrame {
            window.setFrame(
                NSRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height),
                display: false
            )
        } else {
            window.center()
        }

        layoutContent()
        show(folder: resolveStartURL(override: startingURL, settings: settings), remember: false)
    }

    /// One place for the frames. The filter row lives between the path bar
    /// and the list, so showing it shortens the list.
    private func layoutContent() {
        guard let contentView = window?.contentView else { return }
        let size = contentView.bounds.size
        let pathHeight = PathBar.preferredHeight
        let sidebarWidth = Sidebar.preferredWidth
        let filterHeight = filterVisible ? FilterBar.preferredHeight : 0
        let listTop = size.height - pathHeight - filterHeight

        pathBar.frame = NSRect(
            x: 0,
            y: size.height - pathHeight,
            width: size.width,
            height: pathHeight
        )
        filterBar.frame = NSRect(
            x: sidebarWidth,
            y: size.height - pathHeight - filterHeight,
            width: max(0, size.width - sidebarWidth),
            height: filterHeight
        )
        filterBar.isHidden = !filterVisible
        sidebar.frame = NSRect(
            x: 0,
            y: 0,
            width: sidebarWidth,
            height: max(0, size.height - pathHeight)
        )
        scrollView.frame = NSRect(
            x: sidebarWidth,
            y: statusBarHeight,
            width: max(0, size.width - sidebarWidth),
            height: max(0, listTop - statusBarHeight)
        )
        statusBar.frame = NSRect(
            x: sidebarWidth,
            y: 0,
            width: max(0, size.width - sidebarWidth),
            height: statusBarHeight
        )
    }

    func windowDidResize(_ notification: Notification) {
        layoutContent()
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
        if filterVisible { setFilterVisible(false) }
        if remember, let current = currentURL, current != destination {
            backStack.append(current)
            forwardStack.removeAll()
        }
        while backStack.last == destination {
            backStack.removeLast()
        }
        fileTable.folderURL = destination
        fileTable.items = FileSystem.listItems(in: destination)
        currentURL = destination
        sidebar.highlight(url: destination)
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

    /// Cmd+F. Shows the filter row that is already part of the window.
    @objc func focusFilter(_ sender: Any?) {
        guard !pathBar.isEditingField, !fileTable.isEditingName else { return }
        setFilterVisible(true)
    }

    private func setFilterVisible(_ visible: Bool) {
        guard filterVisible != visible else {
            if visible { filterBar.focus() }
            return
        }
        filterVisible = visible
        filterBar.field.stringValue = ""
        fileTable.filterText = ""
        layoutContent()
        if visible {
            filterBar.focus()
        } else {
            window?.makeFirstResponder(fileTable)
        }
        updateStatusBar()
    }

    /// Space. Opens the Quick Look panel for the selection, or closes it.
    @objc func toggleQuickLook(_ sender: Any?) {
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible {
            closeQuickLook()
            return
        }
        guard !fileTable.selectedItems.isEmpty else { return }
        panel.makeKeyAndOrderFront(nil)
        panel.reloadData()
    }

    private func closeQuickLook() {
        QLPreviewPanel.shared()?.orderOut(nil)
        window?.makeFirstResponder(fileTable)
    }

    /// The panel previews whatever is selected, so a selection change while
    /// it is open reloads it. An empty selection closes it.
    private func syncQuickLook() {
        guard let panel = QLPreviewPanel.shared(), panel.isVisible,
              (panel.dataSource as AnyObject?) === self else { return }
        if fileTable.selectedItems.isEmpty {
            closeQuickLook()
        } else {
            panel.reloadData()
        }
    }

    /// The panel is its own window, so a local monitor is what sees Space
    /// and Escape while it is key.
    private func installPreviewKeyMonitor() {
        previewKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let panel = QLPreviewPanel.shared(),
                  panel.isVisible, event.window === panel else { return event }
            if event.keyCode == 49 || event.keyCode == 53 {
                self.closeQuickLook()
                return nil
            }
            return event
        }
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
            return !isEditingText
        case #selector(newFolder(_:)), #selector(newFile(_:)):
            // Allowed while filtering: the action clears the filter so the
            // new row is visible and editable.
            return !pathBar.isEditingField && !fileTable.isEditingName
        case #selector(renameSelection(_:)):
            return !isEditingText && fileTable.rowForRename >= 0
        case #selector(NSText.cut(_:)), #selector(NSText.copy(_:)):
            return !isEditingText && !fileTable.selectedItems.isEmpty
        case #selector(NSText.paste(_:)):
            return !isEditingText && FileClipboard.shared.canPaste
        case #selector(duplicateSelection(_:)):
            return !isEditingText && !fileTable.selectedItems.isEmpty
        case #selector(showInfo(_:)):
            menuItem.title = fileTable.infoActionTitle
            return !isEditingText && !fileTable.selectedItems.isEmpty
        case #selector(moveToTrash(_:)), #selector(deleteImmediately(_:)):
            return !isEditingText && !fileTable.selectedItems.isEmpty
        case #selector(focusFilter(_:)):
            return !pathBar.isEditingField && !fileTable.isEditingName
        case #selector(undoLastAction(_:)):
            menuItem.title = fileUndoManager.undoMenuItemTitle
            return !isEditingText && fileUndoManager.canUndo
        case #selector(redoLastAction(_:)):
            menuItem.title = fileUndoManager.redoMenuItemTitle
            return !isEditingText && fileUndoManager.canRedo
        default:
            return true
        }
    }

    /// Typing goes to one of three editors. File commands stay out of their way.
    private var isEditingText: Bool {
        pathBar.isEditingField || fileTable.isEditingName || filterBar.isEditing
    }

    /// Cmd+Shift+N. The cockroach name is selected, so typing replaces it.
    /// Return keeps the folder. Escape deletes it. A second Return enters it.
    @objc func newFolder(_ sender: Any?) {
        guard let currentURL else { return }
        if filterVisible { setFilterVisible(false) }
        let name = CockroachName.next(avoiding: fileTable.unfilteredItems.map(\.name))
        let url = currentURL.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        } catch {
            present(error)
            return
        }
        revealForEditing(url, name: name)
    }

    /// Empty file, same edit as a new folder. Return keeps it. Escape deletes it.
    @objc func newFile(_ sender: Any?) {
        guard let currentURL else { return }
        if filterVisible { setFilterVisible(false) }
        let name = untitledName(avoiding: fileTable.unfilteredItems.map(\.name))
        let url = currentURL.appendingPathComponent(name)
        do {
            try Data().write(to: url, options: .withoutOverwriting)
        } catch {
            present(error)
            return
        }
        revealForEditing(url, name: name)
    }

    private func revealForEditing(_ url: URL, name: String) {
        guard let currentURL else { return }
        ignoreWatchUntil = Date().addingTimeInterval(0.6)
        creatingURL = url
        fileTable.items = FileSystem.listItems(in: currentURL)
        updateStatusBar()
        guard let row = fileTable.items.firstIndex(where: { $0.name == name }) else { return }
        fileTable.beginEditing(row: row, selectingAll: true)
    }

    /// `untitled`, then `untitled2`, and so on.
    private func untitledName(avoiding existing: [String]) -> String {
        let taken = Set(existing.map { $0.lowercased() })
        if !taken.contains("untitled") { return "untitled" }
        var number = 2
        while taken.contains("untitled\(number)") { number += 1 }
        return "untitled\(number)"
    }

    /// One window. One item is the details. Several items are a summary.
    /// The size walk, including subfolders, happens here, not in the status bar.
    @objc func showInfo(_ sender: Any?) {
        let items = fileTable.selectedItems
        guard !items.isEmpty, let currentURL else { return }
        if infoWindow == nil {
            infoWindow = InfoWindow()
        }
        infoWindow?.show(items: items, folder: currentURL)
    }

    /// Delete and Backspace. No confirm. The Trash can be emptied from Finder.
    @objc func moveToTrash(_ sender: Any?) {
        let items = fileTable.selectedItems
        guard !items.isEmpty else { return }
        var failures: [String] = []
        for item in items {
            do {
                try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
            } catch {
                failures.append("\(item.name): \(error.localizedDescription)")
            }
        }
        dropMissingCuts()
        if !failures.isEmpty {
            present(message: failures.joined(separator: "\n"))
        }
    }

    /// Context menu only. Cancel is the focused button. Return does not delete.
    @objc func deleteImmediately(_ sender: Any?) {
        let items = fileTable.selectedItems
        guard !items.isEmpty else { return }
        let alert = NSAlert()
        if items.count == 1 {
            alert.messageText = "Delete \"\(items[0].name)\" immediately?"
        } else {
            alert.messageText = "Delete \(items.count) items immediately?"
        }
        alert.informativeText = "This can't be undone."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Delete")
        alert.buttons[1].keyEquivalent = ""
        let response = alert.runModal()
        guard response == .alertSecondButtonReturn else { return }
        var failures: [String] = []
        for item in items {
            do {
                try FileManager.default.removeItem(at: item.url)
            } catch {
                failures.append("\(item.name): \(error.localizedDescription)")
            }
        }
        dropMissingCuts()
        if !failures.isEmpty {
            present(message: failures.joined(separator: "\n"))
        }
    }

    private func dropMissingCuts() {
        guard let clip = FileClipboard.shared.current(), clip.kind == .move else { return }
        let left = clip.urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        if left.isEmpty {
            FileClipboard.shared.clearCut()
        } else if left.count != clip.urls.count {
            FileClipboard.shared.write(left, kind: .move)
        }
    }

    private func present(message: String, title: String = "Could not delete") {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window, completionHandler: nil)
    }

    @objc func cut(_ sender: Any?) {
        let urls = fileTable.selectedItems.map(\.url)
        guard !urls.isEmpty else { return }
        FileClipboard.shared.write(urls, kind: .move)
        refreshCutAppearance()
    }

    @objc func copy(_ sender: Any?) {
        let urls = fileTable.selectedItems.map(\.url)
        guard !urls.isEmpty else { return }
        FileClipboard.shared.write(urls, kind: .copy)
        refreshCutAppearance()
    }

    @objc func paste(_ sender: Any?) {
        guard let currentURL, let clip = FileClipboard.shared.current() else { return }
        startTransfer(sources: clip.urls, kind: clip.kind, into: currentURL)
    }

    /// Cmd+D. "name copy", then "name copy 2". No collision question: the
    /// name is picked before the copy starts. The copies end up selected.
    @objc func duplicateSelection(_ sender: Any?) {
        guard let currentURL else { return }
        let items = fileTable.selectedItems
        guard !items.isEmpty else { return }
        let namer = DuplicateNamer(existing: fileTable.unfilteredItems.map(\.url), folder: currentURL)
        startTransfer(
            sources: items.map(\.url),
            kind: .copy,
            into: currentURL,
            namer: namer.name(for:),
            selectCreated: true,
            undoable: false
        )
    }

    /// Open With, from the context menu. The app URL rides on the menu item.
    @objc func openSelectionWithApp(_ sender: Any?) {
        guard let app = (sender as? NSMenuItem)?.representedObject as? URL else { return }
        let urls = fileTable.selectedItems.map(\.url)
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.open(
            urls,
            withApplicationAt: app,
            configuration: NSWorkspace.OpenConfiguration()
        )
    }

    /// Open With → Other…. A sheet, so the window stays where it is.
    @objc func openSelectionWithOtherApp(_ sender: Any?) {
        guard let window else { return }
        let urls = fileTable.selectedItems.map(\.url)
        guard !urls.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose an application"
        panel.prompt = "Open"
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let app = panel.url else { return }
            NSWorkspace.shared.open(
                urls,
                withApplicationAt: app,
                configuration: NSWorkspace.OpenConfiguration()
            )
        }
    }

    @objc func undoLastAction(_ sender: Any?) {
        guard !isEditingText else { return }
        fileUndoManager.undo()
    }

    @objc func redoLastAction(_ sender: Any?) {
        guard !isEditingText else { return }
        fileUndoManager.redo()
    }

    /// Paste and move can be reversed. One overwrite disables the whole batch,
    /// because the file it replaced is gone.
    private func registerUndo(records: [TransferRecord]) {
        guard !records.isEmpty, !records.contains(where: { $0.replacedExisting }) else { return }
        fileUndoManager.registerUndo(withTarget: self) { controller in
            controller.undoTransfer(records)
        }
        fileUndoManager.setActionName(records.contains { $0.kind == .move } ? "Move" : "Paste")
    }

    private func undoTransfer(_ records: [TransferRecord]) {
        var failures: [String] = []
        for record in records {
            do {
                switch record.kind {
                case .copy:
                    try FileManager.default.removeItem(at: record.target)
                case .move:
                    try FileManager.default.moveItem(at: record.target, to: record.source)
                }
            } catch {
                failures.append("\(record.target.lastPathComponent): \(error.localizedDescription)")
            }
        }
        reload(nil)
        fileUndoManager.registerUndo(withTarget: self) { controller in
            controller.redoTransfer(records)
        }
        fileUndoManager.setActionName(records.contains { $0.kind == .move } ? "Move" : "Paste")
        if !failures.isEmpty {
            present(message: failures.joined(separator: "\n"), title: "Could not undo")
        }
    }

    private func redoTransfer(_ records: [TransferRecord]) {
        var failures: [String] = []
        for record in records {
            do {
                switch record.kind {
                case .copy:
                    try FileManager.default.copyItem(at: record.source, to: record.target)
                case .move:
                    try FileManager.default.moveItem(at: record.source, to: record.target)
                }
            } catch {
                failures.append("\(record.target.lastPathComponent): \(error.localizedDescription)")
            }
        }
        reload(nil)
        fileUndoManager.registerUndo(withTarget: self) { controller in
            controller.undoTransfer(records)
        }
        fileUndoManager.setActionName(records.contains { $0.kind == .move } ? "Move" : "Paste")
        if !failures.isEmpty {
            present(message: failures.joined(separator: "\n"), title: "Could not redo")
        }
    }

    /// Paste, a drop, or a duplicate. Same collision question, same
    /// cross-volume rule. `namer` picks the destination name itself;
    /// `selectCreated` selects the new rows when the run is done.
    private func startTransfer(
        sources: [URL],
        kind: TransferKind,
        into destination: URL,
        namer: ((URL) -> String)? = nil,
        selectCreated: Bool = false,
        undoable: Bool = true
    ) {
        guard !sources.isEmpty else { return }
        let transfer = FileTransfer(namer: namer)
        let progress = TransferProgress()
        let title = kind == .move ? "Moving" : "Copying"
        let clock = WorkClock()
        clock.onFire = {
            progress.show(title: title)
        }
        progress.onCancel = {
            transfer.cancel()
            // A collision question blocks the copy. Abort it, or Cancel does nothing.
            if NSApp.modalWindow != nil {
                NSApp.abortModal()
            }
        }
        progress.onDecide = { [weak self] in
            guard let self else { return }
            clock.pause()
            progress.orderOut()
            if let choice = self.askCollision(named: nil) {
                transfer.decide(choice)
            }
            progress.orderFront()
            clock.resume()
        }
        transfer.onProgress = { name, index, total in
            DispatchQueue.main.async {
                progress.update(name: name, index: index, total: total)
            }
        }
        transfer.onCollision = { [weak self] name in
            var choice: CollisionChoice?
            DispatchQueue.main.sync {
                clock.pause()
                progress.orderOut()
                choice = self?.askCollision(named: name)
                if let choice, self?.applyToAll == true {
                    transfer.decide(choice)
                }
                clock.resume()
            }
            return choice
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            clock.resume()
            defer {
                clock.cancel()
                let records = transfer.records
                let created = records.map(\.target)
                DispatchQueue.main.async {
                    progress.close()
                    self?.refreshCutAppearance()
                    self?.reload(nil)
                    guard let self else { return }
                    if selectCreated {
                        self.select(urls: created)
                    }
                    if undoable {
                        self.registerUndo(records: records)
                    }
                }
            }
            do {
                _ = try transfer.run(sources: sources, kind: kind, into: destination)
            } catch TransferError.cancelled {
                // Stopped. What already moved stays moved.
            } catch {
                DispatchQueue.main.async { self?.present(error) }
            }
            if kind == .move {
                let moved = transfer.movedSources
                DispatchQueue.main.async {
                    self?.finishMove(moved: moved, from: sources)
                }
            }
        }
    }

    private var applyToAll = false

    /// The same question, whether a name just collided or the user asked
    /// to decide the rest now. It is its own window, in front.
    private func askCollision(named name: String?) -> CollisionChoice? {
        let alert = NSAlert()
        alert.messageText = name.map { "\($0) already exists." } ?? "For the remaining items"
        alert.informativeText = "Replace, keep both, or skip."
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Keep Both")
        alert.addButton(withTitle: "Skip")
        alert.buttons[0].keyEquivalent = ""
        alert.buttons[1].keyEquivalent = "\r"
        let checkbox = NSButton(checkboxWithTitle: "Apply to All", target: nil, action: nil)
        checkbox.state = .on
        alert.accessoryView = checkbox
        let response = alert.runModal()
        if response == .abort { return nil }
        applyToAll = checkbox.state == .on
        switch response {
        case .alertFirstButtonReturn: return .replace
        case .alertSecondButtonReturn: return .keepBoth
        default: return .skip
        }
    }

    private func finishMove(moved: [URL], from sources: [URL]) {
        let left = sources.filter { source in
            !moved.contains { sameFile($0, source) }
        }
        if left.isEmpty {
            FileClipboard.shared.clearCut()
        } else {
            FileClipboard.shared.write(left, kind: .move)
        }
        refreshCutAppearance()
    }

    private func cancelCut() {
        FileClipboard.shared.clearCut()
        refreshCutAppearance()
    }

    @objc private func clipboardChanged(_ notification: Notification) {
        refreshCutAppearance()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        refreshCutAppearance()
    }

    private func refreshCutAppearance() {
        fileTable.cutPaths = FileClipboard.shared.cutPaths
    }

    /// F2, Cmd+Return, or the context menu. The stem is selected. The extension is not.
    @objc func renameSelection(_ sender: Any?) {
        let row = fileTable.rowForRename
        guard row >= 0 else { return }
        fileTable.beginEditing(row: row, selectingAll: false)
    }

    /// False keeps the editor open. A taken name flashes that row instead of an alert.
    private func canCommit(url: URL, name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "." || trimmed == ".." { return true }
        if trimmed.compare(url.lastPathComponent, options: .caseInsensitive) == .orderedSame,
           trimmed == url.lastPathComponent {
            return true
        }
        guard let conflict = conflictingURL(named: trimmed, except: url) else { return true }
        if let row = fileTable.items.firstIndex(where: { sameFile($0.url, conflict) }) {
            fileTable.flash(row: row)
        }
        NSSound.beep()
        return false
    }

    private func finishEdit(url: URL, name: String, cancelled: Bool) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if cancelled || trimmed.isEmpty || trimmed == "." || trimmed == ".." {
            abandonCreate(url)
            return
        }
        if trimmed == url.lastPathComponent {
            creatingURL = nil
            return
        }
        if let conflict = conflictingURL(named: trimmed, except: url) {
            // Click-away. The editor is already gone, so open it again on the typed name.
            if let row = fileTable.items.firstIndex(where: { sameFile($0.url, conflict) }) {
                fileTable.flash(row: row)
            }
            NSSound.beep()
            if let row = fileTable.items.firstIndex(where: { $0.url == url }) {
                DispatchQueue.main.async { [weak self] in
                    self?.fileTable.beginEditing(row: row, selectingAll: true, text: trimmed)
                }
            }
            return
        }
        let destination = url.deletingLastPathComponent().appendingPathComponent(trimmed)
        ignoreWatchUntil = Date().addingTimeInterval(0.6)
        do {
            try FileManager.default.moveItem(at: url, to: destination)
        } catch {
            abandonCreate(url)
            present(error)
            return
        }
        creatingURL = nil
        guard let currentURL else { return }
        fileTable.items = FileSystem.listItems(in: currentURL)
        updateStatusBar()
        if let row = fileTable.items.firstIndex(where: { $0.name == trimmed }) {
            fileTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            fileTable.scrollRowToVisible(row)
        }
    }

    /// A name already in the folder, whether the filter currently shows it or not.
    private func conflictingURL(named name: String, except url: URL) -> URL? {
        fileTable.unfilteredItems.first {
            !sameFile($0.url, url) && $0.name.compare(name, options: .caseInsensitive) == .orderedSame
        }?.url
    }

    private func sameFile(_ a: URL, _ b: URL) -> Bool {
        a.standardizedFileURL.path == b.standardizedFileURL.path
    }

    private func abandonCreate(_ url: URL) {
        guard let creating = creatingURL, sameFile(creating, url) else { return }
        creatingURL = nil
        ignoreWatchUntil = Date().addingTimeInterval(0.6)
        try? FileManager.default.removeItem(at: url)
        guard let currentURL else { return }
        fileTable.items = FileSystem.listItems(in: currentURL)
        updateStatusBar()
    }

    private func present(_ error: Error) {
        guard let window else { return }
        let alert = NSAlert(error: error)
        alert.beginSheetModal(for: window, completionHandler: nil)
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

    /// The scroll view asks up the responder chain. Yes means: when the list
    /// is already at that edge, keep tracking the gesture as back/forward
    /// instead of scrolling. In the middle, two fingers still scroll.
    override func wantsScrollEventsForSwipeTracking(on axis: NSEvent.GestureAxis) -> Bool {
        axis == .horizontal && NSEvent.isSwipeTrackingFromScrollEventsEnabled
    }

    /// Only events the scroll view forwarded, because it was at the edge.
    /// A two-finger slide over a narrow list never gets here: the list scrolls.
    override func scrollWheel(with event: NSEvent) {
        guard event.phase == .began || event.phase == .changed,
              !trackingSwipe,
              !pathBar.isEditingField,
              !fileTable.isEditingName,
              NSEvent.isSwipeTrackingFromScrollEventsEnabled else {
            super.scrollWheel(with: event)
            return
        }
        let canBack = !backStack.isEmpty
        let canForward = !forwardStack.isEmpty
        guard canBack || canForward else {
            super.scrollWheel(with: event)
            return
        }
        trackingSwipe = true
        event.trackSwipeEvent(
            options: .lockDirection,
            dampenAmountThresholdMin: canForward ? -1 : 0,
            max: canBack ? 1 : 0
        ) { [weak self] amount, phase, isComplete, stop in
            guard let self else {
                stop.pointee = true
                return
            }
            if phase == .ended {
                self.lastSwipe = Date()
                if amount > 0 {
                    self.goBack(nil)
                } else if amount < 0 {
                    self.goForward(nil)
                }
            }
            if isComplete || phase == .ended || phase == .cancelled {
                self.trackingSwipe = false
            }
        }
    }

    /// Three-finger swipe, for the setting that still sends a swipe event.
    /// Fingers moving right goes back.
    private func installSwipeMonitor() {
        swipeMonitor = NSEvent.addLocalMonitorForEvents(matching: .swipe) { [weak self] event in
            self?.handleDiscreteSwipe(event)
            return event
        }
    }

    private func handleDiscreteSwipe(_ event: NSEvent) {
        guard event.window == window else { return }
        guard !pathBar.isEditingField, !fileTable.isEditingName else { return }
        guard Date().timeIntervalSince(lastSwipe) > 0.4 else { return }
        if event.deltaX > 0 {
            lastSwipe = Date()
            goBack(nil)
        } else if event.deltaX < 0 {
            lastSwipe = Date()
            goForward(nil)
        }
    }

    private func scheduleReload() {
        if Date() < ignoreWatchUntil || fileTable.isEditingName { return }
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
        syncQuickLook()
    }

    /// Selects the rows whose files are in `urls`, if the filter still shows them.
    private func select(urls: [URL]) {
        let paths = Set(urls.map { $0.standardizedFileURL.path })
        let rows = IndexSet(fileTable.items.indices.filter {
            paths.contains(fileTable.items[$0].url.standardizedFileURL.path)
        })
        guard let first = rows.first else { return }
        fileTable.selectRowIndexes(rows, byExtendingSelection: false)
        fileTable.scrollRowToVisible(first)
    }

    func windowWillClose(_ notification: Notification) {
        watchSource?.cancel()
        watchSource = nil
        if let swipeMonitor {
            NSEvent.removeMonitor(swipeMonitor)
            self.swipeMonitor = nil
        }
        if let previewKeyMonitor {
            NSEvent.removeMonitor(previewKeyMonitor)
            self.previewKeyMonitor = nil
        }
        if let panel = QLPreviewPanel.shared(), (panel.dataSource as AnyObject?) === self {
            panel.orderOut(nil)
        }
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

/// Quick Look asks the responder chain for a controller. This window
/// answers while it is the key window, and previews the selection.
extension WindowController: QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        true
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        fileTable.selectedItems.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        let items = fileTable.selectedItems
        guard index >= 0, index < items.count else { return nil }
        return items[index].url as NSURL
    }
}
