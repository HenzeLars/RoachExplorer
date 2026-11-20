import AppKit

/// The dense four-column list: Name, Date modified, Size, Kind.
/// Dotfiles are shown, but dimmer.
final class FileTable: NSTableView {
    /// Called after the selection changes, so the window can update its status bar.
    var onSelectionChange: (() -> Void)?

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

    private let iconCache = NSCache<NSString, NSImage>()
    private let listFont = NSFont.systemFont(ofSize: 12)

    private var typeAheadBuffer = ""
    private var lastTypeAhead: Date?

    override init(frame: NSRect) {
        super.init(frame: frame)
        dataSource = self
        delegate = self
        rowHeight = 22
        usesAlternatingRowBackgroundColors = false
        allowsEmptySelection = true
        allowsMultipleSelection = true
        style = .inset

        addColumn(title: "Name", width: 300)
        addColumn(title: "Date modified", width: 120)
        addColumn(title: "Size", width: 80)
        addColumn(title: "Kind", width: 180)
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

    /// Escape clears the selection. Plain characters are type-ahead.
    /// Everything else (arrows, Shift+arrows, Cmd+A) is the table's own behavior.
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            deselectAll(nil)
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

    /// A click below the last row clears the selection.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if row(at: point) < 0 {
            deselectAll(nil)
            return
        }
        super.mouseDown(with: event)
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

extension FileTable: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        items.count
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        onSelectionChange?()
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
        cell.alphaValue = item.isHidden ? 0.5 : 1
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
