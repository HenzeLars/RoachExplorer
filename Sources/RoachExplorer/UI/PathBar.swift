import AppKit

/// The two path rows: a monospace text field, and one button per segment.
/// The segment row scrolls. It never hides a segment.
final class PathBar: NSView, NSTextFieldDelegate {
    static let preferredHeight: CGFloat = 60

    /// Go to this folder. The window updates the bar afterwards.
    var onNavigate: ((URL) -> Void)?
    /// Editing finished (Escape, or a click that left the field). Focus the list.
    var onFinishEditing: (() -> Void)?
    var onBack: (() -> Void)?
    var onForward: (() -> Void)?
    var onReload: (() -> Void)?
    var onFind: (() -> Void)?
    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?
    /// File URLs dropped on a path segment. `copying` is Option.
    var onDrop: ((_ urls: [URL], _ destination: URL, _ copying: Bool) -> Void)?
    private var dropHighlight: NSButton?

    private let navigationButtons = NSSegmentedControl()
    private let reloadButton = NSSegmentedControl()
    private let searchButton = NSSegmentedControl()
    private let historyButtons = NSSegmentedControl()
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
        configurePair(navigationButtons, items: [("chevron.backward", "Back"), ("chevron.forward", "Forward")],
                      action: #selector(navigationClicked(_:)))
        configurePair(reloadButton, items: [("arrow.clockwise", "Reload")], action: #selector(reloadClicked(_:)))
        reloadButton.setWidth(36, forSegment: 0)
        reloadButton.setToolTip("Reload", forSegment: 0)
        configurePair(historyButtons, items: [("arrow.uturn.backward", "Undo"), ("arrow.uturn.forward", "Redo")],
                      action: #selector(historyClicked(_:)))
        configurePair(searchButton, items: [("magnifyingglass", "Find")], action: #selector(findClicked(_:)))
        searchButton.setWidth(72, forSegment: 0)
        searchButton.setLabel("Find", forSegment: 0)
        searchButton.setToolTip("Find by name (⌘F)", forSegment: 0)
        setNavigation(canGoBack: false, canGoForward: false)
        setUndo(canUndo: false, canRedo: false, undoTitle: "Undo", redoTitle: "Redo")

        segmentScroll.drawsBackground = false
        segmentScroll.borderType = .noBorder
        segmentScroll.hasHorizontalScroller = true
        segmentScroll.hasVerticalScroller = false
        segmentScroll.autohidesScrollers = true
        segmentScroll.documentView = segmentDocument
        segmentScroll.setAccessibilityLabel("Path segments")
        addSubview(segmentScroll)
        registerForDraggedTypes([.fileURL])
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

    /// The segment row scrolls sideways. A history swipe over it should scroll,
    /// not go back.
    func ownsSegmentScroller(_ view: NSView) -> Bool {
        var current: NSView? = view
        while let candidate = current {
            if candidate === segmentScroll { return true }
            current = candidate.superview
        }
        return false
    }

    func setNavigation(canGoBack: Bool, canGoForward: Bool) {
        navigationButtons.setEnabled(canGoBack, forSegment: 0)
        navigationButtons.setEnabled(canGoForward, forSegment: 1)
    }

    /// The buttons carry the action name, like the Edit menu does,
    /// so "Undo Paste" is visible without opening a menu.
    func setUndo(canUndo: Bool, canRedo: Bool, undoTitle: String, redoTitle: String) {
        historyButtons.setEnabled(canUndo, forSegment: 0)
        historyButtons.setEnabled(canRedo, forSegment: 1)
        historyButtons.setToolTip(canUndo ? undoTitle : "Undo", forSegment: 0)
        historyButtons.setToolTip(canRedo ? redoTitle : "Redo", forSegment: 1)
    }



    @objc private func findClicked(_ sender: Any?) { onFind?() }

    @objc private func navigationClicked(_ sender: NSSegmentedControl) {
        if sender.selectedSegment == 0 { onBack?() }
        if sender.selectedSegment == 1 { onForward?() }
    }

    @objc private func historyClicked(_ sender: NSSegmentedControl) {
        if sender.selectedSegment == 0 { onUndo?() }
        if sender.selectedSegment == 1 { onRedo?() }
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
        let buttonWidth: CGFloat = 36
        let pairWidth = buttonWidth * 2
        let buttonHeight: CGFloat = 26
        let groupGap: CGFloat = 8
        let navY = bounds.height - 32
        navigationButtons.frame = NSRect(x: 8, y: navY, width: pairWidth, height: buttonHeight)
        // Reload: right-aligned with nav buttons' right edge, row 2.
        let navRightEdge = navigationButtons.frame.maxX
        reloadButton.frame = NSRect(x: navRightEdge - buttonWidth, y: 2, width: buttonWidth, height: 24)
        // Undo/Redo sits at the right edge of row 1.
        let actionsX = bounds.width - pairWidth - 8
        historyButtons.frame = NSRect(x: actionsX, y: navY, width: pairWidth, height: buttonHeight)
        // Find: same width as Undo/Redo, right side aligned with Undo/Redo's right edge.
        searchButton.frame = NSRect(x: bounds.width - pairWidth - 8, y: 2, width: pairWidth, height: 24)
        let fieldX = navigationButtons.frame.maxX + groupGap
        let fieldEnd = actionsX - groupGap
        field.frame = NSRect(x: fieldX, y: navY + 2, width: max(0, fieldEnd - fieldX), height: 22)
        // Breadcrumbs line up with the address text and stop before Find.
        let segmentsX = fieldX - 8
        segmentScroll.frame = NSRect(x: segmentsX, y: 2, width: max(0, fieldEnd - segmentsX), height: 24)
        scrollSegmentsToEnd()
        positionCompletion()
    }

    private func configurePair(_ control: NSSegmentedControl, items: [(String, String)], action: Selector) {
        control.segmentStyle = .rounded
        control.trackingMode = .momentary
        control.segmentCount = items.count
        control.target = self
        control.action = action
        let style = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        for (index, item) in items.enumerated() {
            let image = NSImage(systemSymbolName: item.0, accessibilityDescription: item.1)
            control.setImage(image?.withSymbolConfiguration(style), forSegment: index)
            control.setToolTip(item.1, forSegment: index)
            control.setWidth(36, forSegment: index)
        }
        addSubview(control)
    }

    private func configure(_ button: NSButton, symbol: String, label: String, action: Selector) {
        let symbolStyle = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(symbolStyle)
        button.title = label
        button.font = .systemFont(ofSize: 12, weight: .semibold)
        button.imagePosition = .imageOnly
        button.bezelStyle = .rounded
        button.setButtonType(.momentaryPushIn)
        button.controlSize = .regular
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.target = self
        button.action = action
        addSubview(button)
    }

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

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        dropOperation(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        dropOperation(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        clearDropHighlight()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { clearDropHighlight() }
        guard let destination = segmentURL(for: sender) else { return false }
        let urls = DragFiles.urls(from: sender.draggingPasteboard)
        guard DropTarget.canDrop(urls, into: destination) else { return false }
        onDrop?(urls, destination, DragFiles.wantsCopy(sender))
        return true
    }

    private func dropOperation(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let destination = segmentURL(for: sender) else {
            clearDropHighlight()
            return []
        }
        let urls = DragFiles.urls(from: sender.draggingPasteboard)
        guard DropTarget.canDrop(urls, into: destination) else {
            clearDropHighlight()
            return []
        }
        return DragFiles.operation(for: sender)
    }

    private func segmentURL(for info: NSDraggingInfo) -> URL? {
        let local = segmentDocument.convert(info.draggingLocation, from: nil)
        var found: NSButton?
        for case let button as NSButton in segmentDocument.subviews {
            if button.frame.contains(local) {
                found = button
                break
            }
        }
        guard let found, found.tag >= 0, found.tag < segmentURLs.count else {
            clearDropHighlight()
            return nil
        }
        if dropHighlight !== found {
            clearDropHighlight()
            dropHighlight = found
            found.wantsLayer = true
            found.layer?.backgroundColor = NSColor.selectedContentBackgroundColor.withAlphaComponent(0.45).cgColor
            found.layer?.cornerRadius = 4
        }
        return segmentURLs[found.tag]
    }

    private func clearDropHighlight() {
        dropHighlight?.layer?.backgroundColor = nil
        dropHighlight = nil
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
