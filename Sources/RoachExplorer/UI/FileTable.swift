import AppKit

/// The dense four-column list: Name, Date modified, Size, Kind.
/// Dotfiles are shown, but dimmer.
final class FileTable: NSTableView {
    var items: [FileItem] = [] {
        didSet { reloadData() }
    }

    private let iconCache = NSCache<NSString, NSImage>()
    private let listFont = NSFont.systemFont(ofSize: 12)

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
