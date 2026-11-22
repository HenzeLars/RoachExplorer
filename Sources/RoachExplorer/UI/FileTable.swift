import AppKit

/// The dense four-column list: Name, Date modified, Size, Kind.
/// Dotfiles are shown, but dimmer.
final class FileTable: NSTableView {
    /// Called after the selection changes, so the window can update its status bar.
    var onSelectionChange: (() -> Void)?
    /// Double-click. The row, and whether Option was held. Only this row, not the selection.
    var onOpenRow: ((Int, Bool) -> Void)?
    /// Return or Enter. Option asks to run a file that has no default app.
    var onOpenSelection: ((Bool) -> Void)?
    /// F2 or Cmd+Return.
    var onRename: (() -> Void)?
    /// Return or click-away wants to keep `name`. False means stay in the editor.
    var onCanCommitEdit: ((URL, String) -> Bool)?
    /// Editing ended. `cancelled` is Escape. Click-away and Return are not cancelled.
    var onEditEnded: ((URL, String, Bool) -> Void)?
    /// Space previews the selection with Quick Look.
    var onQuickLook: (() -> Void)?
    /// A folder row held under a drag for a moment. Spring-loaded folders:
    /// the drag keeps going, the window shows the folder underneath.
    var onSpringOpen: ((URL) -> Void)?

    private var storedItems: [FileItem] = []
    private var allItems: [FileItem] = []
    /// A folder row that has been held under a drag, and the wait for it.
    private var springTimer: Timer?
    private var springTarget: URL?

    /// The rows of the table, always in the current sort order.
    /// A computed setter: sorting the backing store in place would not
    /// re-enter, but `items.sort` on an observed stored property does.
    var items: [FileItem] {
        get { storedItems }
        set {
            allItems = newValue
            rebuild()
        }
    }

    /// Everything in the open folder, including rows the filter hides.
    /// New names must not clash with these.
    var unfilteredItems: [FileItem] { allItems }

    /// Cmd+F. Case-insensitive substring of the name. Empty means no filter.
    var filterText: String = "" {
        didSet {
            if filterText != oldValue { rebuild() }
        }
    }

    /// Re-filters, re-sorts, and reloads. Selection survives if the rows are
    /// still visible.
    private func rebuild() {
        let selectedURLs = Set(
            selectedRowIndexes.compactMap { $0 < storedItems.count ? storedItems[$0].url : nil }
        )
        let needle = filterText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        storedItems = needle.isEmpty
            ? allItems
            : allItems.filter { $0.name.lowercased().contains(needle) }
        applySort()
        reloadData()
        let rows = IndexSet(storedItems.indices.filter { selectedURLs.contains(storedItems[$0].url) })
        if !rows.isEmpty {
            selectRowIndexes(rows, byExtendingSelection: false)
        } else {
            deselectAll(nil)
        }
    }

    /// The items in the current selection, in row order.
    var selectedItems: [FileItem] {
        selectedRowIndexes.compactMap { $0 < items.count ? items[$0] : nil }
    }

    /// Quick Look arrow keys. Moves the selection by `delta` rows and keeps it
    /// in view. Clamped, not wrapped: the panel stops at the ends of the list.
    func moveSelection(by delta: Int) {
        guard !items.isEmpty else { return }
        let rows = selectedRowIndexes
        let anchor = delta < 0 ? rows.min() : rows.max()
        let next = min(max((anchor ?? (delta < 0 ? 0 : -1)) + delta, 0), items.count - 1)
        selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        scrollRowToVisible(next)
    }

    /// One file is Get Info. A folder, or more than one row, is Summary.
    var infoActionTitle: String {
        if selectedRowIndexes.count > 1 { return "Summary" }
        if let item = selectedItems.first, item.isFolder, !item.isLink { return "Summary" }
        return "Get Info"
    }

    private let iconCache = NSCache<NSString, NSImage>()
    private let listFont = NSFont.systemFont(ofSize: 12)

    private var typeAheadBuffer = ""
    private var lastTypeAhead: Date?
    private var pendingRename: DispatchWorkItem?
    private var editingURL: URL?
    private var editCancelled = false
    /// Right-clicked row, so Rename hits that row and not whichever was focused.
    private var contextRow: Int?

    override init(frame: NSRect) {
        super.init(frame: frame)
        dataSource = self
        delegate = self
        rowHeight = 22
        usesAlternatingRowBackgroundColors = false
        allowsEmptySelection = true
        allowsMultipleSelection = true
        // Inset style only draws when the scroll view is the full window.
        // Beside a sidebar it leaves a blank panel. Plain draws the rows.
        style = .plain
        setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        setDraggingSourceOperationMask([.copy, .move], forLocal: false)
        registerForDraggedTypes([.fileURL])

        addColumn(title: "Name", width: 300)
        addColumn(title: "Date modified", width: 120)
        addColumn(title: "Size", width: 80)
        addColumn(title: "Kind", width: 180)
        // Name ascending is the default order. The arrow shows on that header.
        sortDescriptors = [NSSortDescriptor(key: "Name", ascending: true)]

        target = self
        doubleAction = #selector(openClickedRow(_:))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func addColumn(title: String, width: CGFloat) {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(title))
        column.title = title
        column.width = width
        column.minWidth = 56
        column.resizingMask = [.userResizingMask]
        // A header click sorts by this column; the same header again reverses.
        column.sortDescriptorPrototype = NSSortDescriptor(key: title, ascending: true)
        addTableColumn(column)
    }

    /// The column a header click sorts by, and its direction.
    /// Folders stay first in every order.
    private var sortColumn = "Name"
    private var sortAscending = true

    /// Folders first, then the active column, then name as the tie-break.
    private func applySort() {
        storedItems.sort { a, b in
            if a.isFolder != b.isFolder { return a.isFolder }
            let order = compare(a, b)
            return sortAscending ? order != .orderedDescending : order != .orderedAscending
        }
    }

    private func compare(_ a: FileItem, _ b: FileItem) -> ComparisonResult {
        switch sortColumn {
        case "Date modified":
            if a.modified != b.modified {
                return a.modified < b.modified ? .orderedAscending : .orderedDescending
            }
        case "Size":
            if a.size != b.size {
                return a.size < b.size ? .orderedAscending : .orderedDescending
            }
        case "Kind":
            let byKind = a.kind.localizedCaseInsensitiveCompare(b.kind)
            if byKind != .orderedSame { return byKind }
        default:
            break
        }
        return a.name.localizedCaseInsensitiveCompare(b.name)
    }

    /// Combining marks, i.e. the first half of a dead-key sequence (umlauts
    /// and friends). The Swift import of `nonBaseCharacterSet` is missing in
    /// this SDK, so ask the ObjC runtime for it.
    private static let nonBase: CharacterSet = {
        let selector = NSSelectorFromString("nonBaseCharacterSet")
        guard let result = NSCharacterSet.perform(selector) else { return CharacterSet() }
        return result.takeUnretainedValue() as! CharacterSet
    }()

    /// Paths of rows that are cut, so they dim until paste or Escape.
    var cutPaths: Set<String> = [] {
        didSet {
            if cutPaths != oldValue { reloadData() }
        }
    }

    /// Escape also cancels a pending cut. The window clears the clipboard mark.
    var onCancelCut: (() -> Void)?
    /// Delete and Backspace move the selection to the Trash. No confirm.
    var onTrash: (() -> Void)?
    /// The open folder. A drop below the rows lands here.
    var folderURL: URL?
    /// File URLs dropped on a folder row, or on the empty area. `copying` is Option.
    var onDrop: ((_ urls: [URL], _ destination: URL, _ copying: Bool) -> Void)?
    private var didDrag = false
    private let rubberBand = RubberBandView()

    /// Escape clears the selection. Plain characters are type-ahead.
    /// Everything else (arrows, Shift+arrows, Cmd+A) is the table's own behavior.
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onCancelCut?()
            deselectAll(nil)
            return
        }
        // Space previews the selection. It must not reach type-ahead.
        if event.keyCode == 49,
           event.modifierFlags.intersection([.command, .option, .control]).isEmpty {
            onQuickLook?()
            return
        }
        // Delete (51) and Forward Delete (117). Both move the selection to the Trash.
        if (event.keyCode == 51 || event.keyCode == 117),
           event.modifierFlags.intersection([.command, .option, .control]).isEmpty {
            onTrash?()
            return
        }
        // F2, and Cmd+Return. Plain Return opens, so this has to come first.
        if event.keyCode == 122
            || (event.keyCode == 36 && event.modifierFlags.contains(.command)
                && event.modifierFlags.intersection([.option, .control, .shift]).isEmpty) {
            onRename?()
            return
        }
        // Keypad Enter is 76. Option+Return is "run in Terminal" for a file
        // with no default app; the window decides.
        if (event.keyCode == 36 || event.keyCode == 76),
           !event.modifierFlags.contains(.command) {
            onOpenSelection?(event.modifierFlags.contains(.option))
            return
        }
        // Arrow and function keys live at U+F700 and up. They are not names,
        // and swallowing them stops Shift+Up/Down from extending the selection.
        if event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
           let characters = event.characters, characters.count == 1,
           let scalar = characters.unicodeScalars.first,
           scalar.value >= 32, scalar.value != 127, scalar.value < 0xF700,
           !FileTable.nonBase.contains(scalar) {
            let now = Date()
            if let last = lastTypeAhead, now.timeIntervalSince(last) > 0.5 {
                typeAheadBuffer = ""
            }
            lastTypeAhead = now
            typeAheadBuffer += characters
            let prefix = typeAheadBuffer.lowercased()
            if let row = items.firstIndex(where: { $0.name.lowercased().hasPrefix(prefix) }) {
                selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                scrollRowToVisible(row)
            }
            return
        }
        super.keyDown(with: event)
    }

    @objc private func openClickedRow(_ sender: Any?) {
        cancelPendingRename()
        let row = clickedRow
        guard row >= 0 else { return }
        let option = NSApp.currentEvent?.modifierFlags.contains(.option) ?? false
        onOpenRow?(row, option)
    }

    /// A drag starts only on the filename. Anywhere else, a drag is a rubber band.
    /// A click below the last row clears the selection. A slow second click
    /// on the name of the already-selected row starts a rename.
    override func mouseDown(with event: NSEvent) {
        cancelPendingRename()
        let point = convert(event.locationInWindow, from: nil)
        let clicked = row(at: point)
        let onFilename = clicked >= 0 && isFilenameHit(point, row: clicked)
        if event.clickCount > 1 {
            if clicked >= 0 {
                if onFilename {
                    super.mouseDown(with: event)
                } else {
                    onOpenRow?(clicked, event.modifierFlags.contains(.option))
                }
            }
            return
        }
        guard onFilename else {
            trackRubberBand(from: point, start: event, clicked: clicked)
            return
        }
        let wasOnlySelection = selectedRowIndexes == IndexSet(integer: clicked)
        didDrag = false
        super.mouseDown(with: event)
        if didDrag { return }
        if wasOnlySelection, isNameClick(point, row: clicked) {
            let work = DispatchWorkItem { [weak self] in
                self?.beginEditing(row: clicked, selectingAll: false)
            }
            pendingRename = work
            DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: work)
        }
    }

    /// The table would otherwise drag as soon as the mouse moves, including a rubber band.
    override func canDragRows(with rowIndexes: IndexSet, at mouseDownPoint: NSPoint) -> Bool {
        let row = row(at: mouseDownPoint)
        return row >= 0 && rowIndexes.contains(row) && isFilenameHit(mouseDownPoint, row: row)
    }

    /// Icon plus the name text. The empty stretch of the name column is not a drag.
    private func isFilenameHit(_ point: NSPoint, row: Int) -> Bool {
        let column = column(at: point)
        guard column >= 0, row >= 0, row < items.count,
              tableColumns[column].identifier.rawValue == "Name" else { return false }
        let cell = frameOfCell(atColumn: column, row: row)
        let textWidth = (items[row].name as NSString).size(withAttributes: [.font: listFont]).width
        let hitWidth = min(cell.width, 4 + 16 + 6 + textWidth + 10)
        let hit = NSRect(x: cell.minX, y: cell.minY, width: hitWidth, height: cell.height)
        return hit.contains(point)
    }

    private func trackRubberBand(from start: NSPoint, start event: NSEvent, clicked: Int) {
        let flags = event.modifierFlags
        let extend = flags.contains(.command) || flags.contains(.shift)
        let original = selectedRowIndexes
        var banding = false
        window?.makeFirstResponder(self)
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp { break }
            autoscroll(with: next)
            let current = convert(next.locationInWindow, from: nil)
            let dx = current.x - start.x
            let dy = current.y - start.y
            if !banding, dx * dx + dy * dy < 16 { continue }
            banding = true
            showRubberBand(from: start, to: current, extend: extend, original: original)
        }
        clearRubberBand()
        if banding { return }
        if clicked < 0 {
            if !extend { deselectAll(nil) }
        } else {
            selectClick(row: clicked, flags: flags)
        }
    }

    private func selectClick(row: Int, flags: NSEvent.ModifierFlags) {
        if flags.contains(.command) {
            if selectedRowIndexes.contains(row) {
                deselectRow(row)
            } else {
                selectRowIndexes(IndexSet(integer: row), byExtendingSelection: true)
            }
        } else if flags.contains(.shift), let anchor = selectedRowIndexes.first {
            let lower = min(anchor, row)
            let upper = max(anchor, row)
            selectRowIndexes(IndexSet(integersIn: lower...upper), byExtendingSelection: false)
        } else {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
    }

    private func showRubberBand(
        from start: NSPoint,
        to current: NSPoint,
        extend: Bool,
        original: IndexSet
    ) {
        let band = NSRect(
            x: min(start.x, current.x),
            y: min(start.y, current.y),
            width: abs(current.x - start.x),
            height: abs(current.y - start.y)
        )
        if rubberBand.superview == nil {
            addSubview(rubberBand)
        }
        rubberBand.frame = band
        var indexes = extend ? original : IndexSet()
        for row in 0..<numberOfRows where band.intersects(rect(ofRow: row)) {
            indexes.insert(row)
        }
        selectRowIndexes(indexes, byExtendingSelection: false)
    }

    private func clearRubberBand() {
        rubberBand.removeFromSuperview()
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = menu(for: event) else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let clicked = row(at: point)
        contextRow = clicked >= 0 ? clicked : nil
        if clicked >= 0, !selectedRowIndexes.contains(clicked) {
            selectRowIndexes(IndexSet(integer: clicked), byExtendingSelection: false)
        }
        let menu = NSMenu()
        if clicked >= 0 {
            menu.addItem(withTitle: "Open", action: #selector(WindowController.openSelection(_:)), keyEquivalent: "")
            let openWith = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
            openWith.submenu = openWithSubmenu()
            menu.addItem(openWith)
            menu.addItem(withTitle: infoActionTitle, action: #selector(WindowController.showInfo(_:)), keyEquivalent: "")
            menu.addItem(.separator())
        }
        menu.addItem(withTitle: "New Folder", action: #selector(WindowController.newFolder(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "New File", action: #selector(WindowController.newFile(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Open in Terminal", action: #selector(WindowController.openInTerminal(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "")
        if clicked >= 0 {
            menu.addItem(.separator())
            menu.addItem(withTitle: "Copy Path", action: #selector(WindowController.copyPath(_:)), keyEquivalent: "")
            menu.addItem(withTitle: "Show in Finder", action: #selector(WindowController.showInFinder(_:)), keyEquivalent: "")
            menu.addItem(.separator())
            menu.addItem(withTitle: "Duplicate", action: #selector(WindowController.duplicateSelection(_:)), keyEquivalent: "")
            menu.addItem(withTitle: "Make Alias", action: #selector(WindowController.makeAlias(_:)), keyEquivalent: "")
            menu.addItem(.separator())
            menu.addItem(withTitle: "Rename", action: #selector(WindowController.renameSelection(_:)), keyEquivalent: "")
            menu.addItem(.separator())
            menu.addItem(withTitle: "Move to Trash", action: #selector(WindowController.moveToTrash(_:)), keyEquivalent: "")
            menu.addItem(withTitle: "Delete Immediately", action: #selector(WindowController.deleteImmediately(_:)), keyEquivalent: "")
        }
        return menu
    }

    /// The apps that can open the selection, plus Other….
    /// Opening is the window's job; the items carry the app URL.
    private func openWithSubmenu() -> NSMenu? {
        let urls = selectedItems.map(\.url)
        guard let first = urls.first else { return nil }
        let menu = NSMenu(title: "Open With")
        let apps = NSWorkspace.shared.urlsForApplications(toOpen: first)
        for app in apps {
            let title = FileManager.default.displayName(atPath: app.path)
            let item = NSMenuItem(
                title: title,
                action: #selector(WindowController.openSelectionWithApp(_:)),
                keyEquivalent: ""
            )
            item.representedObject = app
            let icon = NSWorkspace.shared.icon(forFile: app.path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            menu.addItem(item)
        }
        if !apps.isEmpty {
            menu.addItem(.separator())
        }
        menu.addItem(
            withTitle: "Other…",
            action: #selector(WindowController.openSelectionWithOtherApp(_:)),
            keyEquivalent: ""
        )
        return menu
    }

    var isEditingName: Bool { editingURL != nil }

    /// The row Rename should use: the right-clicked one, else the focused one.
    var rowForRename: Int {
        if let contextRow, contextRow >= 0 {
            return contextRow
        }
        return selectedRow
    }

    func beginEditing(row: Int, selectingAll: Bool, text: String? = nil) {
        guard row >= 0, row < items.count else { return }
        cancelPendingRename()
        scrollRowToVisible(row)
        selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        let column = self.column(withIdentifier: NSUserInterfaceItemIdentifier("Name"))
        guard column >= 0,
              let cell = view(atColumn: column, row: row, makeIfNecessary: true) as? NameCellView,
              let field = cell.textField else { return }
        cell.prepareForEditing()
        if let text { field.stringValue = text }
        field.delegate = self
        editingURL = items[row].url
        editCancelled = false
        window?.makeFirstResponder(field)
        let name = field.stringValue
        let range = selectingAll ? NSRange(location: 0, length: (name as NSString).length) : Self.stemRange(of: name)
        field.currentEditor()?.selectedRange = range
        DispatchQueue.main.async {
            field.currentEditor()?.selectedRange = range
        }
    }

    /// The row that already has this name. Two red pulses, so the clash is obvious
    /// without a dialog covering it.
    func flash(row: Int) {
        guard row >= 0, row < numberOfRows else { return }
        let rect = rect(ofRow: row)
        if !visibleRect.intersects(rect) {
            scrollRowToVisible(row)
        }
        guard let rowView = rowView(atRow: row, makeIfNecessary: true) else { return }
        rowView.setAccessibilityLabel("Name already used")
        let overlay = NSView(frame: rowView.bounds)
        overlay.autoresizingMask = [.width, .height]
        overlay.wantsLayer = true
        overlay.layer?.backgroundColor = NSColor.systemRed.cgColor
        overlay.alphaValue = 0
        rowView.addSubview(overlay)
        pulse(overlay, remaining: 2) {
            overlay.removeFromSuperview()
            rowView.setAccessibilityLabel(nil)
        }
    }

    private func pulse(_ view: NSView, remaining: Int, done: @escaping () -> Void) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            view.animator().alphaValue = 0.55
        } completionHandler: {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                view.animator().alphaValue = 0
            } completionHandler: {
                if remaining > 1 {
                    self.pulse(view, remaining: remaining - 1, done: done)
                } else {
                    done()
                }
            }
        }
    }

    private func cancelPendingRename() {
        pendingRename?.cancel()
        pendingRename = nil
    }

    private func isNameClick(_ point: NSPoint, row: Int) -> Bool {
        let column = self.column(at: point)
        guard column >= 0, tableColumns[column].identifier.rawValue == "Name" else { return false }
        let rect = frameOfCell(atColumn: column, row: row)
        return point.x > rect.minX + 24
    }

    /// `notes.md` selects `notes`. `.env` has no extension. The extension stays editable.
    static func stemRange(of name: String) -> NSRange {
        let ns = name as NSString
        let dot = ns.range(of: ".", options: .backwards)
        if dot.location == NSNotFound || dot.location == 0 {
            return NSRange(location: 0, length: ns.length)
        }
        return NSRange(location: 0, length: dot.location)
    }

    /// Keep the table at least as tall as the clip view, so clicks on the
    /// empty area below the rows land here instead of on the scroll view.
    override func tile() {
        super.tile()
        guard let contentSize = enclosingScrollView?.contentSize else { return }
        let headerHeight = headerView?.frame.height ?? 0
        let rowsHeight = CGFloat(numberOfRows) * rowHeight
        var frame = frame
        frame.size.height = max(rowsHeight + headerHeight, contentSize.height)
        self.frame = frame
    }

    private func icon(for item: FileItem) -> NSImage {
        let key = item.url.path as NSString
        if let cached = iconCache.object(forKey: key) { return cached }
        let image = NSWorkspace.shared.icon(forFile: item.url.path)
        image.size = NSSize(width: 16, height: 16)
        iconCache.setObject(image, forKey: key)
        return image
    }
}

extension FileTable {
    override func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        let copying = NSEvent.modifierFlags.contains(.option)
        if context == .outsideApplication {
            // Terminal takes a copy of the path. Finder may move.
            return copying ? .copy : [.copy, .move]
        }
        return copying ? .copy : .move
    }
}

// MARK: - Spring-loaded folders

/// Resting the pointer on a folder row during a drag opens it, so a destination
/// three levels down is one gesture. The drag survives the folder change: only
/// the rows behind the pointer are replaced, not the dragging session.
extension FileTable {
    /// Long enough not to fire while dragging across a row, short enough not
    /// to feel stuck. Finder is about half a second.
    private static let springDelay: TimeInterval = 0.55

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let operation = super.draggingUpdated(sender)
        let point = convert(sender.draggingLocation, from: nil)
        let row = self.row(at: point)
        let urls = DragFiles.urls(from: sender.draggingPasteboard)
        var folder: URL?
        if row >= 0, row < items.count {
            folder = DropTarget.folder(resolving: items[row].url)
        }
        if let folder, DropTarget.canDrop(urls, into: folder) {
            scheduleSpringLoad(for: folder)
        } else {
            cancelSpringLoad()
        }
        return operation
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        cancelSpringLoad()
        super.draggingExited(sender)
    }

    /// Moving to another row restarts the wait. Staying put does not.
    private func scheduleSpringLoad(for folder: URL) {
        guard springTarget != folder else { return }
        cancelSpringLoad()
        springTarget = folder
        let timer = Timer.scheduledTimer(withTimeInterval: Self.springDelay, repeats: false) { [weak self] _ in
            guard let self, self.springTarget == folder else { return }
            self.springTimer = nil
            self.springTarget = nil
            self.onSpringOpen?(folder)
        }
        timer.tolerance = 0.1
        springTimer = timer
    }

    private func cancelSpringLoad() {
        springTimer?.invalidate()
        springTimer = nil
        springTarget = nil
    }
}

extension FileTable: NSTextFieldDelegate {
    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            commitEdit()
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            cancelEdit()
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let url = editingURL else { return }
        let field = obj.object as? NSTextField
        let name = field?.stringValue ?? ""
        let cancelled = editCancelled
        editingURL = nil
        editCancelled = false
        if cancelled {
            field?.stringValue = url.lastPathComponent
        }
        field?.isEditable = false
        field?.isSelectable = false
        onEditEnded?(url, name, cancelled)
    }

    private func commitEdit() {
        guard let url = editingURL, let editor = window?.firstResponder as? NSTextView else { return }
        if onCanCommitEdit?(url, editor.string) == false { return }
        window?.makeFirstResponder(self)
    }

    private func cancelEdit() {
        editCancelled = true
        window?.makeFirstResponder(self)
    }
}

extension FileTable: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        items.count
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        onSelectionChange?()
    }

    /// A header click. Clicking the same header again reverses the direction.
    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldSortDescriptors: [NSSortDescriptor]) {
        guard let descriptor = sortDescriptors.first else { return }
        sortColumn = descriptor.key ?? "Name"
        sortAscending = descriptor.ascending
        applySort()
        reloadData()
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard !isEditingName, row >= 0, row < items.count else { return nil }
        return items[row].url as NSURL
    }

    func tableView(
        _ tableView: NSTableView,
        draggingSession session: NSDraggingSession,
        willBeginAt screenPoint: NSPoint,
        forRowIndexes rowIndexes: IndexSet
    ) {
        didDrag = true
        cancelPendingRename()
        let urls = rowIndexes.compactMap { $0 < items.count ? items[$0].url : nil }
        session.draggingPasteboard.setString(ShellPath.join(urls), forType: .string)
    }

    func tableView(
        _ tableView: NSTableView,
        validateDrop info: NSDraggingInfo,
        proposedRow row: Int,
        proposedDropOperation dropOperation: NSTableView.DropOperation
    ) -> NSDragOperation {
        guard !isEditingName else { return [] }
        let urls = DragFiles.urls(from: info.draggingPasteboard)
        guard let destination = dropDestination(row: row, operation: dropOperation),
              DropTarget.canDrop(urls, into: destination) else { return [] }
        if row >= 0, row < items.count, dropOperation == .on, DropTarget.folder(resolving: items[row].url) != nil {
            setDropRow(row, dropOperation: .on)
        } else {
            setDropRow(-1, dropOperation: .on)
        }
        return DragFiles.operation(for: info)
    }

    func tableView(
        _ tableView: NSTableView,
        acceptDrop info: NSDraggingInfo,
        row: Int,
        dropOperation: NSTableView.DropOperation
    ) -> Bool {
        cancelSpringLoad()
        let urls = DragFiles.urls(from: info.draggingPasteboard)
        guard let destination = dropDestination(row: row, operation: dropOperation),
              DropTarget.canDrop(urls, into: destination) else { return false }
        onDrop?(urls, destination, DragFiles.wantsCopy(info))
        return true
    }

    /// A folder row, or the open folder when the drop is below the rows.
    private func dropDestination(row: Int, operation: NSTableView.DropOperation) -> URL? {
        if row >= 0, row < items.count, operation == .on {
            return DropTarget.folder(resolving: items[row].url)
        }
        if row < 0 || row >= items.count {
            return folderURL.flatMap { DropTarget.folder(resolving: $0) }
        }
        return nil
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, row < items.count else { return nil }
        let item = items[row]
        let cell: NSTableCellView
        if tableColumn.identifier.rawValue == "Name" {
            let nameCell = NameCellView(font: listFont)
            nameCell.imageView?.image = icon(for: item)
            nameCell.textField?.stringValue = item.name
            nameCell.showLinkMark = item.isLink
            cell = nameCell
        } else {
            let textCell = TextCellView(font: listFont)
            textCell.textField?.stringValue = value(for: item, column: tableColumn.identifier.rawValue)
            if tableColumn.identifier.rawValue == "Size" {
                textCell.textField?.alignment = .right
            }
            cell = textCell
        }
        let cut = cutPaths.contains(item.url.standardizedFileURL.path)
        if cut {
            cell.alphaValue = 0.4
            cell.setAccessibilityHelp("Cut")
        } else {
            cell.alphaValue = item.isHidden ? 0.5 : 1
            cell.setAccessibilityHelp(nil)
        }
        return cell
    }

    private func value(for item: FileItem, column: String) -> String {
        switch column {
        case "Date modified":
            return Format.date(item.modified)
        case "Size":
            return item.isFolder ? Format.folderSize : Format.size(item.size)
        case "Kind":
            return item.kind
        default:
            return item.name
        }
    }
}

/// Name column cell: 16 pt icon, name, and a small link mark for symlinks.
private final class RubberBandView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.selectedContentBackgroundColor.withAlphaComponent(0.22).cgColor
        layer?.borderColor = NSColor.selectedContentBackgroundColor.cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 2
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}

private final class NameCellView: NSTableCellView {
    var showLinkMark = false {
        didSet { linkMark.isHidden = !showLinkMark }
    }

    private let linkMark = NSImageView()

    init(font: NSFont) {
        super.init(frame: .zero)
        let iconView = NSImageView()
        iconView.imageScaling = .scaleProportionallyDown
        let label = NSTextField(labelWithString: "")
        label.font = font
        label.lineBreakMode = .byTruncatingTail
        label.cell?.truncatesLastVisibleLine = true

        linkMark.image = NSImage(systemSymbolName: "link", accessibilityDescription: "symbolic link")
        linkMark.contentTintColor = .secondaryLabelColor
        linkMark.isHidden = true

        addSubview(iconView)
        addSubview(label)
        addSubview(linkMark)
        imageView = iconView
        textField = label
    }

    func prepareForEditing() {
        textField?.isEditable = true
        textField?.isSelectable = true
        textField?.isBezeled = false
        textField?.drawsBackground = false
        if let cell = textField?.cell as? NSTextFieldCell {
            cell.isScrollable = true
            cell.usesSingleLineMode = true
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layout() {
        super.layout()
        let iconSide: CGFloat = 16
        let iconView = imageView ?? NSImageView()
        iconView.frame = NSRect(x: 4, y: (bounds.height - iconSide) / 2, width: iconSide, height: iconSide)
        let label = textField ?? NSTextField()
        let textX = iconView.frame.maxX + 6
        let markWidth: CGFloat = showLinkMark ? 16 : 0
        label.frame = NSRect(
            x: textX,
            y: 0,
            width: max(0, bounds.width - textX - 4 - markWidth),
            height: bounds.height
        )
        if !linkMark.isHidden {
            linkMark.frame = NSRect(x: bounds.width - 20, y: (bounds.height - 10) / 2, width: 10, height: 10)
        }
    }
}

/// Plain text cell for the Date modified, Size, and Kind columns.
private final class TextCellView: NSTableCellView {
    init(font: NSFont) {
        super.init(frame: .zero)
        let label = NSTextField(labelWithString: "")
        label.font = font
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        textField = label
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layout() {
        super.layout()
        let label = textField ?? NSTextField()
        label.frame = NSRect(x: 6, y: 0, width: max(0, bounds.width - 10), height: bounds.height)
    }
}
