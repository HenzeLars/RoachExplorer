import AppKit

/// Flat places list. No vibrancy. Home, Desktop, Documents, Downloads, the
/// volume, Dropbox and iCloud Drive when those folders exist. A folder dragged
/// onto the empty area becomes a favorite. A drop on a row moves into it.
final class Sidebar: NSView, NSTableViewDataSource, NSTableViewDelegate {
    static let preferredWidth: CGFloat = 196

    var onNavigate: ((URL) -> Void)?
    /// File URLs dropped on a row. `copying` is Option.
    var onDrop: ((_ urls: [URL], _ destination: URL, _ copying: Bool) -> Void)?
    var onFavoritesChanged: (([String]) -> Void)?
    /// A row held under a drag. The window peeks into that folder, so a drop
    /// can be made deeper without a sidebar tree.
    var onSpringOpen: ((URL) -> Void)?
    /// Eject was asked for on a volume row.
    var onEject: ((URL) -> Void)?

    private let table = SidebarTable()
    private var rows: [Row] = []
    private var favoritePaths: [String] = []
    private var currentPath: String?
    private var springTimer: Timer?
    private var springTarget: URL?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        // Subviews must not paint over the file list. macOS 14 does not clip by default.
        clipsToBounds = true
        table.dataSource = self
        table.delegate = self
        table.onRemoveFavorite = { [weak self] row in
            self?.removeFavorite(at: row)
        }
        table.isFavoriteRow = { [weak self] row in
            guard let self, row >= 0, row < self.rows.count,
                  case .item(_, _, true, _) = self.rows[row] else { return false }
            return true
        }
        table.isVolumeRow = { [weak self] row in
            guard let self, row >= 0, row < self.rows.count else { return false }
            return self.rows[row].isVolume
        }
        table.canEjectRow = { [weak self] row in
            guard let self, row >= 0, row < self.rows.count,
                  case .volume(_, let url, _) = self.rows[row] else { return false }
            return Volumes.mounted().first { $0.url == url }?.isUnmountable ?? false
        }
        table.onEject = { [weak self] row in
            guard let self, row >= 0, row < self.rows.count,
                  case .volume(_, let url, _) = self.rows[row] else { return }
            self.onEject?(url)
        }
        table.doubleAction = nil
        table.target = self
        table.action = #selector(openClickedRow(_:))
        table.onDraggingUpdated = { [weak self] point, urls in
            self?.updateSpringLoad(at: point, urls: urls)
        }
        table.onDraggingExited = { [weak self] in
            self?.cancelSpringLoad()
        }

        let scroll = NSScrollView(frame: bounds)
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = true
        scroll.backgroundColor = .windowBackgroundColor
        scroll.borderType = .noBorder
        scroll.clipsToBounds = true
        scroll.documentView = table
        scroll.setAccessibilityLabel("Sidebar")
        addSubview(scroll)

        table.registerForDraggedTypes([.fileURL])
        table.setAccessibilityLabel("Sidebar")

        // A share mounted or ejected elsewhere should show up here at once.
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(
            forName: NSWorkspace.didMountNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.reloadPlaces()
        }
        center.addObserver(
            forName: NSWorkspace.didUnmountNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.reloadPlaces()
        }

        reloadPlaces()
    }

    /// Re-read the places and the mounted volumes.
    func refresh() {
        reloadPlaces()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func setFavorites(_ paths: [String]) {
        favoritePaths = unique(paths)
        rebuild()
    }

    func highlight(url: URL?) {
        currentPath = url?.standardizedFileURL.path
        selectCurrent()
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
        NSColor.separatorColor.setStroke()
        let line = NSBezierPath()
        line.move(to: NSPoint(x: bounds.maxX - 0.5, y: bounds.minY))
        line.line(to: NSPoint(x: bounds.maxX - 0.5, y: bounds.maxY))
        line.lineWidth = 1
        line.stroke()
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < rows.count else { return nil }
        switch rows[row] {
        case .header(let title):
            let field = NSTextField(labelWithString: title)
            field.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
            field.textColor = .secondaryLabelColor
            field.setAccessibilityLabel(title)
            return field
        case .item(let title, let url, _, let missing):
            return makeCell(title: title, url: url, missing: missing, symbol: nil)
        case .volume(let title, let url, let network):
            return makeCell(title: title, url: url, missing: false, symbol: network ? "network" : "externaldrive")
        }
    }

    private func makeCell(title: String, url: URL, missing: Bool, symbol: String?) -> NSView {
        let cell = NSTableCellView()
        let image = NSImageView(frame: NSRect(x: 8, y: 4, width: 16, height: 16))
        if missing {
            image.image = NSImage(systemSymbolName: "questionmark.folder", accessibilityDescription: nil)
        } else if let symbol {
            image.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        } else {
            image.image = NSWorkspace.shared.icon(forFile: url.path)
        }
        image.image?.size = NSSize(width: 16, height: 16)
        let label = NSTextField(labelWithString: title)
        label.font = NSFont.systemFont(ofSize: 12)
        label.textColor = missing ? .tertiaryLabelColor : .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.frame = NSRect(x: 30, y: 3, width: 150, height: 18)
        label.setAccessibilityLabel(title)
        cell.addSubview(image)
        cell.addSubview(label)
        cell.textField = label
        cell.imageView = image
        cell.toolTip = url.path
        cell.setAccessibilityLabel(title)
        return cell
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        rows[row].isHeader ? 22 : 24
    }

    func tableView(_ tableView: NSTableView, selectionIndexesForProposedSelection proposed: IndexSet) -> IndexSet {
        IndexSet(proposed.filter { $0 < rows.count && !rows[$0].isHeader })
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        SidebarRowView()
    }

    func tableView(
        _ tableView: NSTableView,
        validateDrop info: NSDraggingInfo,
        proposedRow row: Int,
        proposedDropOperation dropOperation: NSTableView.DropOperation
    ) -> NSDragOperation {
        let urls = DragFiles.urls(from: info.draggingPasteboard)
        if let destination = folderDestination(row: row, operation: dropOperation),
           DropTarget.canDrop(urls, into: destination) {
            table.setDropRow(row, dropOperation: .on)
            return DragFiles.operation(for: info)
        }
        let folders = urls.filter(Self.isFolder)
        guard !folders.isEmpty else { return [] }
        table.setDropRow(favoritesHeaderRow, dropOperation: .on)
        return .copy
    }

    func tableView(
        _ tableView: NSTableView,
        acceptDrop info: NSDraggingInfo,
        row: Int,
        dropOperation: NSTableView.DropOperation
    ) -> Bool {
        cancelSpringLoad()
        let urls = DragFiles.urls(from: info.draggingPasteboard)
        if let destination = folderDestination(row: row, operation: dropOperation),
           DropTarget.canDrop(urls, into: destination) {
            onDrop?(urls, destination, DragFiles.wantsCopy(info))
            return true
        }
        let folders = urls.filter(Self.isFolder)
        guard !folders.isEmpty else { return false }
        addFavorites(folders)
        return true
    }

    private var favoritesHeaderRow: Int {
        rows.firstIndex {
            if case .header("Favorites") = $0 { return true }
            return false
        } ?? max(0, rows.count - 1)
    }

    @objc private func openClickedRow(_ sender: Any?) {
        let row = table.clickedRow
        guard row >= 0, row < rows.count, let url = rows[row].itemURL else { return }
        if rows[row].isMissing {
            NSSound.beep()
            return
        }
        onNavigate?(url)
    }

    private func removeFavorite(at row: Int) {
        guard row >= 0, row < rows.count, case .item(_, let url, true, _) = rows[row] else { return }
        let path = url.standardizedFileURL.path
        favoritePaths.removeAll { $0 == path }
        onFavoritesChanged?(favoritePaths)
        rebuild()
    }

    private func addFavorites(_ urls: [URL]) {
        var changed = false
        for url in urls {
            let path = url.standardizedFileURL.path
            if favoritePaths.contains(path) { continue }
            favoritePaths.append(path)
            changed = true
        }
        guard changed else { return }
        onFavoritesChanged?(favoritePaths)
        rebuild()
    }

    private func folderDestination(row: Int, operation: NSTableView.DropOperation) -> URL? {
        guard operation == .on, row >= 0, row < rows.count,
              let url = rows[row].itemURL, !rows[row].isMissing else { return nil }
        return DropTarget.folder(resolving: url)
    }

    /// Finder is about half a second. Same delay as the file list.
    private static let springDelay: TimeInterval = 0.55

    private func updateSpringLoad(at point: NSPoint, urls: [URL]) {
        guard let folder = springFolder(at: point), DropTarget.canDrop(urls, into: folder) else {
            cancelSpringLoad()
            return
        }
        scheduleSpringLoad(for: folder)
    }

    private func springFolder(at point: NSPoint) -> URL? {
        let row = table.row(at: point)
        guard row >= 0, row < rows.count,
              let url = rows[row].itemURL, !rows[row].isMissing,
              let folder = DropTarget.folder(resolving: url) else { return nil }
        // The folder already open: reloading it under the drag does nothing useful.
        if folder.standardizedFileURL.path == currentPath { return nil }
        return folder
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

    private func reloadPlaces() {
        rebuild()
    }

    private func rebuild() {
        var next: [Row] = [.header("Places")]
        next += Self.places().map { Row.item(title: $0.title, url: $0.url, favorite: false, missing: false) }
        next.append(.header("Favorites"))
        for path in favoritePaths {
            let url = URL(fileURLWithPath: path)
            let missing = !Self.isFolder(url)
            let title = url.lastPathComponent.isEmpty ? path : url.lastPathComponent
            next.append(.item(title: title, url: url, favorite: true, missing: missing))
        }
        let volumes = Volumes.sidebarVolumes()
        if !volumes.isEmpty {
            next.append(.header("Volumes"))
            for volume in volumes {
                next.append(.volume(title: volume.name, url: volume.url, network: volume.isNetwork))
            }
        }
        rows = next
        table.reloadData()
        table.tile()
        selectCurrent()
    }

    private func selectCurrent() {
        guard let currentPath else {
            table.deselectAll(nil)
            return
        }
        if let row = rows.firstIndex(where: { row in
            guard let url = row.itemURL else { return false }
            return url.standardizedFileURL.path == currentPath
        }) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            table.scrollRowToVisible(row)
        } else {
            table.deselectAll(nil)
        }
    }

    private static func places() -> [(title: String, url: URL)] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var items: [(String, URL)] = [("Home", home)]
        for name in ["Desktop", "Documents", "Downloads"] {
            let url = home.appendingPathComponent(name, isDirectory: true)
            if isFolder(url) { items.append((name, url)) }
        }
        let root = URL(fileURLWithPath: "/", isDirectory: true)
        if let values = try? root.resourceValues(forKeys: [.volumeLocalizedNameKey, .volumeNameKey]) {
            let name = values.volumeLocalizedName ?? values.volumeName ?? "Macintosh HD"
            items.append((name, root))
        } else {
            items.append(("Macintosh HD", root))
        }
        if let dropbox = dropboxURL() { items.append(("Dropbox", dropbox)) }
        if let icloud = iCloudURL() { items.append(("iCloud Drive", icloud)) }
        return items
    }

    private static func dropboxURL() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let classic = home.appendingPathComponent("Dropbox", isDirectory: true)
        if isFolder(classic) { return classic }
        return cloudStorage(prefix: "Dropbox")
    }

    private static func iCloudURL() -> URL? {
        let classic = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        if isFolder(classic) { return classic }
        return cloudStorage(prefix: "iCloud")
    }

    private static func cloudStorage(prefix: String) -> URL? {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/CloudStorage", isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return nil }
        for name in names.sorted() where name.hasPrefix(prefix) {
            let url = root.appendingPathComponent(name, isDirectory: true)
            if isFolder(url) { return url }
        }
        return nil
    }

    private static func isFolder(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    private func unique(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        return paths.compactMap { path in
            let standard = URL(fileURLWithPath: path).standardizedFileURL.path
            if standard.isEmpty || seen.contains(standard) { return nil }
            seen.insert(standard)
            return standard
        }
    }
}

private enum Row {
    case header(String)
    case item(title: String, url: URL, favorite: Bool, missing: Bool)
    case volume(title: String, url: URL, network: Bool)

    var isHeader: Bool {
        if case .header = self { return true }
        return false
    }

    var isVolume: Bool {
        if case .volume = self { return true }
        return false
    }

    var isMissing: Bool {
        if case .item(_, _, _, let missing) = self { return missing }
        return false
    }

    var itemURL: URL? {
        switch self {
        case .item(_, let url, _, _): return url
        case .volume(_, let url, _): return url
        case .header: return nil
        }
    }
}

private final class SidebarTable: NSTableView {
    var onRemoveFavorite: ((Int) -> Void)?
    var isFavoriteRow: ((Int) -> Bool)?
    var isVolumeRow: ((Int) -> Bool)?
    var canEjectRow: ((Int) -> Bool)?
    var onEject: ((Int) -> Void)?
    /// Table-space pointer and the dragged files, on every drag step.
    var onDraggingUpdated: ((NSPoint, [URL]) -> Void)?
    var onDraggingExited: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Sidebar"))
        column.resizingMask = .autoresizingMask
        addTableColumn(column)
        headerView = nil
        rowHeight = 24
        intercellSpacing = NSSize(width: 0, height: 0)
        style = .plain
        selectionHighlightStyle = .regular
        allowsEmptySelection = true
        allowsMultipleSelection = false
        backgroundColor = .windowBackgroundColor
        focusRingType = .none
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func tile() {
        super.tile()
        guard let contentSize = enclosingScrollView?.contentSize else { return }
        var frame = frame
        frame.size.width = contentSize.width
        frame.size.height = max(frame.size.height, contentSize.height)
        self.frame = frame
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let operation = super.draggingUpdated(sender)
        let point = convert(sender.draggingLocation, from: nil)
        onDraggingUpdated?(point, DragFiles.urls(from: sender.draggingPasteboard))
        return operation
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onDraggingExited?()
        super.draggingExited(sender)
    }

    override func rightMouseDown(with event: NSEvent) {
        let row = row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0 else { return }
        let menu = NSMenu()
        if isVolumeRow?(row) == true {
            let eject = menu.addItem(withTitle: "Eject", action: #selector(ejectClicked(_:)), keyEquivalent: "")
            eject.tag = row
            eject.target = self
            eject.isEnabled = canEjectRow?(row) ?? false
        } else if isFavoriteRow?(row) == true {
            let item = menu.addItem(withTitle: "Remove from Sidebar", action: #selector(removeClicked(_:)), keyEquivalent: "")
            item.tag = row
            item.target = self
        } else {
            return
        }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func removeClicked(_ sender: NSMenuItem) {
        onRemoveFavorite?(sender.tag)
    }

    @objc private func ejectClicked(_ sender: NSMenuItem) {
        onEject?(sender.tag)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        nil
    }
}

private final class SidebarRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        NSColor.selectedContentBackgroundColor.withAlphaComponent(0.35).setFill()
        bounds.fill()
    }
}
