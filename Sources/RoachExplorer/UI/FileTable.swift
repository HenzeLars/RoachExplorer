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

    var items: [FileItem] = [] {
        didSet {
            // Selection survives a refresh if the files are still there.
            let selectedURLs = Set(
                selectedRowIndexes.compactMap { $0 < oldValue.count ? oldValue[$0].url : nil }
            )
            reloadData()
            let rows = IndexSet(items.indices.filter { selectedURLs.contains(items[$0].url) })
            if !rows.isEmpty {
                selectRowIndexes(rows, byExtendingSelection: false)
            } else {
                deselectAll(nil)
            }
        }
    }

    /// The items in the current selection, in row order.
    var selectedItems: [FileItem] {
        selectedRowIndexes.compactMap { $0 < items.count ? items[$0] : nil }
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
        addTableColumn(column)
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

    /// Escape clears the selection. Plain characters are type-ahead.
    /// Everything else (arrows, Shift+arrows, Cmd+A) is the table's own behavior.
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onCancelCut?()
            deselectAll(nil)
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

    /// A click below the last row clears the selection. A slow second click
    /// on the name of the already-selected row starts a rename. A double-click
    /// opens, and cancels that.
    override func mouseDown(with event: NSEvent) {
        cancelPendingRename()
        let point = convert(event.locationInWindow, from: nil)
        let clicked = row(at: point)
        if clicked < 0 {
            deselectAll(nil)
            return
        }
        if event.clickCount > 1 {
            super.mouseDown(with: event)
            return
        }
        let wasOnlySelection = selectedRowIndexes == IndexSet(integer: clicked)
        let onName = isNameClick(point, row: clicked)
        didDrag = false
        super.mouseDown(with: event)
        if didDrag { return }
        if wasOnlySelection, onName {
            let work = DispatchWorkItem { [weak self] in
                self?.beginEditing(row: clicked, selectingAll: false)
            }
            pendingRename = work
            DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: work)
        }
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
            menu.addItem(withTitle: infoActionTitle, action: #selector(WindowController.showInfo(_:)), keyEquivalent: "")
            menu.addItem(.separator())
        }
        menu.addItem(withTitle: "New Folder", action: #selector(WindowController.newFolder(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "New File", action: #selector(WindowController.newFile(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "")
        if clicked >= 0 {
            menu.addItem(.separator())
            menu.addItem(withTitle: "Rename", action: #selector(WindowController.renameSelection(_:)), keyEquivalent: "")
            menu.addItem(.separator())
            menu.addItem(withTitle: "Move to Trash", action: #selector(WindowController.moveToTrash(_:)), keyEquivalent: "")
            menu.addItem(withTitle: "Delete Immediately", action: #selector(WindowController.deleteImmediately(_:)), keyEquivalent: "")
        }
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
