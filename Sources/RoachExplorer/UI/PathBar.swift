import AppKit

/// The two path rows: a monospace text field, and one button per segment.
/// The segment row scrolls. It never hides a segment.
final class PathBar: NSView, NSTextFieldDelegate {
    static let preferredHeight: CGFloat = 56

    /// Go to this folder. The window updates the bar afterwards.
    var onNavigate: ((URL) -> Void)?
    /// Editing finished (Escape, or a click that left the field). Focus the list.
    var onFinishEditing: (() -> Void)?
    var onBack: (() -> Void)?
    var onForward: (() -> Void)?
    var onReload: (() -> Void)?

    private let backButton = NSButton()
    private let forwardButton = NSButton()
    private let reloadButton = NSButton()
    private let field = NSTextField(frame: .zero)
    private let segmentScroll = NSScrollView(frame: .zero)
    private let segmentDocument = NSView(frame: .zero)
    private let completion = CompletionList()

    private var currentURL: URL?
    private var segmentURLs: [URL] = []
    /// Return is navigating. Ending the edit must not restore the old text over the new path.
    private var committing = false
    /// Tab is rewriting the field. The change notification must not close the popup.
    private var applying = false
    private var flashToken = 0

    private let fieldFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    private let segmentFont = NSFont.systemFont(ofSize: 12)

    override init(frame: NSRect) {
        super.init(frame: frame)

        field.isEditable = true
        field.isSelectable = true
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.font = fieldFont
        field.delegate = self
        field.setAccessibilityLabel("Path")
        if let cell = field.cell as? NSTextFieldCell {
            cell.usesSingleLineMode = true
            cell.isScrollable = true
            cell.lineBreakMode = .byTruncatingHead
        }
        addSubview(field)
        configure(backButton, symbol: "chevron.backward", label: "Back", action: #selector(backClicked(_:)))
        configure(forwardButton, symbol: "chevron.forward", label: "Forward", action: #selector(forwardClicked(_:)))
        configure(reloadButton, symbol: "arrow.clockwise", label: "Reload", action: #selector(reloadClicked(_:)))
        backButton.isEnabled = false
        forwardButton.isEnabled = false

        segmentScroll.drawsBackground = false
        segmentScroll.borderType = .noBorder
        segmentScroll.hasHorizontalScroller = true
        segmentScroll.hasVerticalScroller = false
        segmentScroll.autohidesScrollers = true
        segmentScroll.documentView = segmentDocument
        segmentScroll.setAccessibilityLabel("Path segments")
        addSubview(segmentScroll)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// The folder on screen. Skipped while the field is being edited, so a refresh
    /// cannot eat what the user is typing.
    func show(url: URL) {
        currentURL = url.standardizedFileURL
        if !isEditing {
            field.stringValue = currentURL?.path ?? ""
        }
        reloadSegments()
    }

    func setNavigation(canGoBack: Bool, canGoForward: Bool) {
        backButton.isEnabled = canGoBack
        forwardButton.isEnabled = canGoForward
    }

    /// Cmd+L. Selects the whole path, so typing replaces it.
    func focusField() {
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    var isEditingField: Bool { isEditing }

    private var isEditing: Bool {
        guard let editor = field.currentEditor() else { return false }
        return window?.firstResponder === editor
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setStroke()
        let line = NSBezierPath()
        line.move(to: NSPoint(x: 0, y: 0.5))
        line.line(to: NSPoint(x: bounds.maxX, y: 0.5))
        line.lineWidth = 1
        line.stroke()
    }

    override func layout() {
        super.layout()
        let navWidth: CGFloat = 26
        let navY = bounds.height - 30
        backButton.frame = NSRect(x: 8, y: navY, width: navWidth, height: 22)
        forwardButton.frame = NSRect(x: 8 + navWidth, y: navY, width: navWidth, height: 22)
        reloadButton.frame = NSRect(x: 8 + navWidth * 2, y: navY, width: navWidth, height: 22)
        let fieldX = 8 + navWidth * 3 + 6
        field.frame = NSRect(x: fieldX, y: navY, width: max(0, bounds.width - fieldX - 8), height: 22)
        // Segments line up with the text, not with the buttons.
        segmentScroll.frame = NSRect(x: fieldX - 8, y: 2, width: max(0, bounds.width - (fieldX - 8)), height: 24)
        scrollSegmentsToEnd()
        positionCompletion()
    }

    private func configure(_ button: NSButton, symbol: String, label: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.title = label
        button.imagePosition = .imageOnly
        button.bezelStyle = .recessed
        button.setButtonType(.momentaryPushIn)
        button.controlSize = .small
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.target = self
        button.action = action
        addSubview(button)
    }

    @objc private func backClicked(_ sender: Any?) { onBack?() }
    @objc private func forwardClicked(_ sender: Any?) { onForward?() }
    @objc private func reloadClicked(_ sender: Any?) { onReload?() }

    override func viewWillStartLiveResize() {
        super.viewWillStartLiveResize()
        hideCompletion()
    }

    // MARK: Segments

    private func reloadSegments() {
        segmentDocument.subviews.forEach { $0.removeFromSuperview() }
        segmentURLs = PathInput.segments(of: currentURL)

        var x: CGFloat = 8
        let rowHeight = segmentScroll.contentSize.height > 1 ? segmentScroll.contentSize.height : 24
        for (index, url) in segmentURLs.enumerated() {
            if index > 0 {
                let chevron = NSImageView(frame: NSRect(x: x, y: (rowHeight - 8) / 2, width: 8, height: 8))
                chevron.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
                chevron.contentTintColor = .tertiaryLabelColor
                chevron.imageScaling = .scaleProportionallyDown
                segmentDocument.addSubview(chevron)
                x += 12
            }
            let button = NSButton(title: PathInput.title(for: url), target: self, action: #selector(segmentClicked(_:)))
            button.tag = index
            button.bezelStyle = .recessed
            button.setButtonType(.momentaryPushIn)
            button.controlSize = .small
            button.font = index == segmentURLs.count - 1
                ? NSFont.systemFont(ofSize: 12, weight: .semibold)
                : segmentFont
            button.sizeToFit()
            var frame = button.frame
            frame.origin = NSPoint(x: x, y: (rowHeight - frame.height) / 2)
            frame.size.width += 8
            button.frame = frame
            segmentDocument.addSubview(button)
            x += frame.width + 2
        }

        let width = max(x + 8, segmentScroll.bounds.width)
        segmentDocument.frame = NSRect(x: 0, y: 0, width: width, height: rowHeight)
        scrollSegmentsToEnd()
    }

    private func scrollSegmentsToEnd() {
        let visible = segmentScroll.contentSize.width
        let maxX = max(0, segmentDocument.frame.width - visible)
        segmentScroll.contentView.scroll(to: NSPoint(x: maxX, y: 0))
        segmentScroll.reflectScrolledClipView(segmentScroll.contentView)
    }

    @objc private func segmentClicked(_ sender: NSButton) {
        guard sender.tag >= 0, sender.tag < segmentURLs.count else { return }
        hideCompletion()
        finishEditingThenNavigate(segmentURLs[sender.tag])
    }

    // MARK: Field editor

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            if completion.isShown, let name = completion.highlightedName() {
                accept(name, in: textView)
            } else {
                commit(textView)
            }
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            if completion.isShown {
                hideCompletion()
            } else {
                restoreAndFinish()
            }
            return true
        }
        if commandSelector == #selector(NSResponder.insertTab(_:)) {
            complete(textView)
            return true
        }
        if completion.isShown, commandSelector == #selector(NSResponder.moveDown(_:)) {
            completion.move(1)
            return true
        }
        if completion.isShown, commandSelector == #selector(NSResponder.moveUp(_:)) {
            completion.move(-1)
            return true
        }
        return false
    }

    func controlTextDidChange(_ obj: Notification) {
        if applying { return }
        hideCompletion()
        clearColor()
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        hideCompletion()
        if committing {
            committing = false
            return
        }
        if let currentURL {
            field.stringValue = currentURL.path
        }
    }

    private func commit(_ textView: NSTextView) {
        let text = textView.string
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let currentURL else {
            restoreAndFinish()
            return
        }
        let destination = PathInput.resolve(trimmed, relativeTo: currentURL)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDir), isDir.boolValue {
            hideCompletion()
            finishEditingThenNavigate(destination)
            return
        }
        flash(textView)
        if let range = PathInput.brokenRange(in: text, relativeTo: currentURL) {
            mark(range, in: textView)
        }
    }

    private func complete(_ textView: NSTextView) {
        guard let currentURL else { return }
        let text = textView.string
        let selection = textView.selectedRange()
        let cursor = selection.location + selection.length

        if let tilde = PathInput.bareTildeRange(text, cursor: cursor) {
            replace(tilde, with: "~/", in: textView)
            return
        }

        guard let context = PathInput.completion(text: text, cursor: cursor, relativeTo: currentURL) else {
            hideCompletion()
            NSSound.beep()
            return
        }

        if context.matches.count == 1, let only = context.matches.first {
            replace(context.partialRange, with: only + "/", in: textView)
            hideCompletion()
            return
        }

        let shared = PathInput.sharedPrefix(of: context.matches)
        // Only extend. Rewriting a same-length prefix just changes the user's casing.
        if shared.count > context.partial.count,
           shared.lowercased().hasPrefix(context.partial.lowercased()) {
            replace(context.partialRange, with: shared, in: textView)
        }
        showCompletion(context.matches)
    }

    private func accept(_ name: String, in textView: NSTextView) {
        guard let currentURL else { return }
        let text = textView.string
        let cursor = textView.selectedRange().location + textView.selectedRange().length
        guard let context = PathInput.completion(text: text, cursor: cursor, relativeTo: currentURL) else {
            hideCompletion()
            return
        }
        replace(context.partialRange, with: name + "/", in: textView)
        hideCompletion()
    }

    private func replace(_ range: NSRange, with insertion: String, in textView: NSTextView) {
        applying = true
        textView.insertText(insertion, replacementRange: range)
        applying = false
        clearColor()
    }

    /// End the edit before navigating. `show` refuses to overwrite the field
    /// while the editor is up, so the full path would otherwise be dropped.
    private func finishEditingThenNavigate(_ url: URL) {
        committing = true
        onFinishEditing?()
        onNavigate?(url)
        committing = false
    }

    private func restoreAndFinish() {
        hideCompletion()
        if let currentURL {
            field.stringValue = currentURL.path
        }
        onFinishEditing?()
    }

    private func clearColor() {
        guard let textView = field.currentEditor() as? NSTextView,
              let storage = textView.textStorage else { return }
        let full = NSRange(location: 0, length: storage.length)
        storage.setAttributes([
            .font: fieldFont,
            .foregroundColor: NSColor.labelColor,
        ], range: full)
    }

    private func mark(_ range: Range<String.Index>, in textView: NSTextView) {
        guard let storage = textView.textStorage else { return }
        let nsRange = NSRange(range, in: textView.string)
        clearColor()
        storage.addAttribute(.foregroundColor, value: NSColor.systemRed, range: nsRange)
    }

    private func flash(_ textView: NSTextView) {
        flashToken += 1
        let token = flashToken
        textView.drawsBackground = true
        let previous = textView.backgroundColor
        textView.backgroundColor = NSColor.systemRed.withAlphaComponent(0.45)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { [weak textView] in
            guard self.flashToken == token else { return }
            textView?.backgroundColor = previous
        }
    }

    // MARK: Completion popup

    private func showCompletion(_ names: [String]) {
        guard let content = window?.contentView else { return }
        completion.names = names
        completion.onClick = { [weak self] name in
            guard let self, let textView = self.field.currentEditor() as? NSTextView else { return }
            self.accept(name, in: textView)
        }
        if completion.superview == nil {
            content.addSubview(completion)
        }
        positionCompletion()
        completion.reload()
    }

    private func hideCompletion() {
        completion.removeFromSuperview()
    }

    private func positionCompletion() {
        guard completion.isShown, let content = window?.contentView else { return }
        let fieldFrame = field.convert(field.bounds, to: content)
        let height = completion.preferredHeight
        completion.frame = NSRect(
            x: fieldFrame.minX,
            y: fieldFrame.minY - height,
            width: fieldFrame.width,
            height: height
        )
    }
}

/// Path text in, folder URL out. No views.
enum PathInput {
    static func resolve(_ text: String, relativeTo current: URL) -> URL {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return current.standardizedFileURL }
        let expanded = (trimmed as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded).standardizedFileURL
        }
        let base = current.standardizedFileURL.path
        let joined = base.hasSuffix("/") ? base + expanded : base + "/" + expanded
        return URL(fileURLWithPath: joined).standardizedFileURL
    }

    /// From the volume root to `url`, root included.
    static func segments(of url: URL?) -> [URL] {
        guard let url else { return [] }
        var urls: [URL] = []
        var current = url.standardizedFileURL
        while current.path != "/" {
            urls.append(current)
            let parent = current.deletingLastPathComponent().standardizedFileURL
            if parent.path == current.path { break }
            current = parent
        }
        urls.append(URL(fileURLWithPath: "/"))
        return urls.reversed()
    }

    static func title(for url: URL) -> String {
        let standard = url.standardizedFileURL
        if standard.path == "/" {
            let name = FileManager.default.displayName(atPath: "/")
            return name.isEmpty ? "/" : name
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        if standard == home { return "Home" }
        return standard.lastPathComponent
    }

    /// The first missing component, through the end of `text`. Nil if the whole
    /// path is an existing directory. A file counts as missing: it is not a place to go.
    static func brokenRange(in text: String, relativeTo current: URL) -> Range<String.Index>? {
        guard let start = text.firstIndex(where: { !$0.isWhitespace }) else { return nil }
        let end = text.index(after: text.lastIndex(where: { !$0.isWhitespace }) ?? text.startIndex)
        if start >= end { return nil }
        let body = text[start..<end]

        var base = current.standardizedFileURL
        var rest = body[body.startIndex..<body.endIndex]
        if body.hasPrefix("/") {
            base = URL(fileURLWithPath: "/")
            rest = body.dropFirst()
        } else if body.hasPrefix("~") {
            let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
            if !isDirectory(home) { return start..<end }
            base = home
            rest = body.dropFirst()
            if rest.hasPrefix("/") { rest = rest.dropFirst() }
        }

        var url = base
        var index = rest.startIndex
        while index < rest.endIndex {
            if rest[index] == "/" {
                index = rest.index(after: index)
                continue
            }
            let nameStart = index
            while index < rest.endIndex, rest[index] != "/" {
                index = rest.index(after: index)
            }
            url = url.appendingPathComponent(String(rest[nameStart..<index])).standardizedFileURL
            if !isDirectory(url) {
                return nameStart..<end
            }
        }
        return nil
    }

    /// The range of a lone `~` ending at the cursor, if that is all that was typed.
    static func bareTildeRange(_ text: String, cursor: Int) -> NSRange? {
        guard let index = index(in: text, utf16: cursor) else { return nil }
        let prefix = text[..<index]
        guard prefix.trimmingCharacters(in: .whitespacesAndNewlines) == "~",
              let tilde = prefix.lastIndex(of: "~") else { return nil }
        return NSRange(tilde..<prefix.index(after: tilde), in: text)
    }

    struct Completion {
        let partialRange: NSRange
        let partial: String
        let matches: [String]
    }

    /// Folders in the parent of the component being typed. Nil if that parent
    /// does not exist, or nothing matches. Dot-directories match only when the
    /// typed prefix starts with ".".
    static func completion(text: String, cursor: Int, relativeTo current: URL) -> Completion? {
        guard let cursorIndex = index(in: text, utf16: cursor) else { return nil }
        let prefix = text[..<cursorIndex]
        guard let slash = prefix.lastIndex(of: "/") else {
            let partialStart = prefix.firstIndex(where: { !$0.isWhitespace }) ?? prefix.endIndex
            return matches(in: current, partial: String(prefix[partialStart..<prefix.endIndex]), range: partialStart..<prefix.endIndex, text: text)
        }
        let partialStart = prefix.index(after: slash)
        let parentText = String(prefix[...slash])
        let parent = resolve(parentText, relativeTo: current)
        guard isDirectory(parent) else { return nil }
        return matches(in: parent, partial: String(prefix[partialStart..<prefix.endIndex]), range: partialStart..<prefix.endIndex, text: text)
    }

    static func sharedPrefix(of names: [String]) -> String {
        guard var prefix = names.first else { return "" }
        for name in names.dropFirst() {
            var i = prefix.startIndex
            var j = name.startIndex
            while i < prefix.endIndex, j < name.endIndex,
                  String(prefix[i]).lowercased() == String(name[j]).lowercased() {
                i = prefix.index(after: i)
                j = name.index(after: j)
            }
            prefix = String(prefix[..<i])
            if prefix.isEmpty { break }
        }
        return prefix
    }

    private static func matches(in directory: URL, partial: String, range: Range<String.Index>, text: String) -> Completion? {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: []
        )) ?? []
        let wantHidden = partial.hasPrefix(".")
        let names = urls.compactMap { url -> String? in
            let name = url.lastPathComponent
            if name.hasPrefix("."), !wantHidden { return nil }
            guard isDirectory(url) else { return nil }
            if partial.isEmpty { return name }
            guard name.range(of: partial, options: [.anchored, .caseInsensitive]) != nil else { return nil }
            return name
        }.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        guard !names.isEmpty else { return nil }
        return Completion(partialRange: NSRange(range, in: text), partial: partial, matches: names)
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    private static func index(in text: String, utf16 offset: Int) -> String.Index? {
        let clamped = min(max(0, offset), text.utf16.count)
        return String.Index(utf16Offset: clamped, in: text)
    }
}

/// The folder list under the path field. It does not take keyboard focus;
/// the field editor owns the keys and asks this view to move the highlight.
private final class CompletionList: NSView, NSTableViewDataSource, NSTableViewDelegate {
    var names: [String] = []
    var onClick: ((String) -> Void)?

    private let scroll = NSScrollView(frame: .zero)
    private let table = NSTableView(frame: .zero)
    private let rowHeight: CGFloat = 20
    private let visibleRows = 8

    var isShown: Bool { superview != nil }

    var preferredHeight: CGFloat {
        CGFloat(min(visibleRows, max(names.count, 1))) * rowHeight + 2
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = rowHeight
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.backgroundColor = .controlBackgroundColor
        table.style = .fullWidth
        table.refusesFirstResponder = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked(_:))
        table.setAccessibilityLabel("Path completion")

        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = table
        scroll.frame = bounds
        scroll.autoresizingMask = [.width, .height]
        addSubview(scroll)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func reload() {
        table.tableColumns.first?.width = bounds.width
        table.reloadData()
        if !names.isEmpty {
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }

    func highlightedName() -> String? {
        let row = table.selectedRow
        guard row >= 0, row < names.count else { return names.first }
        return names[row]
    }

    func move(_ delta: Int) {
        guard !names.isEmpty else { return }
        let next = min(max(0, table.selectedRow + delta), names.count - 1)
        table.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        table.scrollRowToVisible(next)
    }

    override func layout() {
        super.layout()
        table.tableColumns.first?.width = bounds.width
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        names.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let label = NSTextField(labelWithString: names[row])
        label.font = NSFont.systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingTail
        let cell = CompletionCell()
        cell.addSubview(label)
        cell.textField = label
        return cell
    }

    @objc private func clicked(_ sender: Any?) {
        let row = table.clickedRow
        guard row >= 0, row < names.count else { return }
        onClick?(names[row])
    }
}

private final class CompletionCell: NSTableCellView {
    override func layout() {
        super.layout()
        textField?.frame = NSRect(x: 6, y: 0, width: max(0, bounds.width - 10), height: bounds.height)
    }
}
