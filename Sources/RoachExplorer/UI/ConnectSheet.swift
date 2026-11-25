import AppKit

/// The connect sheet: a protocol, an address, and credentials only when the
/// protocol uses them. It builds the URL, so nobody has to type
/// `smb://user:pass@host/share` by hand. Addresses that connected are offered
/// again while typing.
final class ConnectSheet: NSWindow {
    private let protocolControl = NSSegmentedControl()
    private let addressField = NSTextField()
    private let userField = NSTextField()
    private let passwordField = NSSecureTextField()
    private let note = NSTextField(labelWithString: "")
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let connectButton = NSButton(title: "Connect", target: nil, action: nil)
    private let recentList = RecentList()
    private let recentButton = NSButton(title: "", target: nil, action: nil)

    private weak var hostWindow: NSWindow?
    private var onConnect: ((URL, String) -> Void)?
    private var recentServers: [String] = []

    private let fullHeight: CGFloat = 252
    private let shortHeight: CGFloat = 196

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: fullHeight),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        title = "Connect to Server"
        isReleasedWhenClosed = false
        isMovableByWindowBackground = true

        let content = contentView ?? NSView()
        content.wantsLayer = true

        protocolControl.segmentStyle = .texturedRounded
        protocolControl.trackingMode = .selectOne
        protocolControl.segmentCount = 2
        protocolControl.setLabel("NFS", forSegment: 0)
        protocolControl.setLabel("Windows (SMB)", forSegment: 1)
        protocolControl.selectedSegment = 0
        protocolControl.target = self
        protocolControl.action = #selector(protocolChanged(_:))
        protocolControl.setAccessibilityLabel("Protocol")

        addressField.placeholderString = "192.168.100.100/share"
        addressField.bezelStyle = .roundedBezel
        addressField.delegate = self
        addressField.setAccessibilityLabel("Address")

        userField.placeholderString = "Username (optional)"
        userField.bezelStyle = .roundedBezel
        userField.setAccessibilityLabel("Username")

        passwordField.placeholderString = "Password (optional)"
        passwordField.bezelStyle = .roundedBezel
        passwordField.setAccessibilityLabel("Password")

        note.font = NSFont.systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.lineBreakMode = .byTruncatingTail

        cancelButton.bezelStyle = .rounded
        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked(_:))
        cancelButton.keyEquivalent = "\u{1b}"
        connectButton.bezelStyle = .rounded
        connectButton.target = self
        connectButton.action = #selector(connectClicked(_:))
        connectButton.keyEquivalent = "\r"

        recentList.onPick = { [weak self] address in
            self?.acceptRecent(address)
        }

        recentButton.bezelStyle = NSButton.BezelStyle.shadowlessSquare
        recentButton.isBordered = false
        recentButton.imageScaling = NSImageScaling.scaleProportionallyDown
        recentButton.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Recent servers")
        recentButton.target = self
        recentButton.action = #selector(recentClicked(_:))
        recentButton.toolTip = "Recent servers"
        recentButton.setAccessibilityLabel("Recent servers")

        for view in [protocolControl, addressField, recentButton, userField, passwordField, note, cancelButton, connectButton] {
            content.addSubview(view)
        }
        layoutContent()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Show it as a sheet on `parent`. The second value is the address to
    /// remember when the mount succeeds.
    func present(in parent: NSWindow, recent: [String], onConnect: @escaping (URL, String) -> Void) {
        hostWindow = parent
        self.onConnect = onConnect
        recentServers = recent
        parent.beginSheet(self) { _ in }
        makeFirstResponder(addressField)
    }

    private var showsCredentials: Bool {
        protocolControl.selectedSegment == 1
    }

    private func layoutContent() {
        guard let content = contentView else { return }
        let width = content.frame.width
        let height = showsCredentials ? fullHeight : shortHeight
        setContentSize(NSSize(width: width, height: height))

        var y = height - 18
        protocolControl.frame = NSRect(x: 20, y: y - 24, width: 240, height: 24)
        y -= 24 + 14

        addressField.frame = NSRect(x: 20, y: y - 24, width: width - 40, height: 24)
        recentButton.frame = NSRect(
            x: addressField.frame.maxX - 22,
            y: addressField.frame.minY + 4,
            width: 16,
            height: 16
        )
        y -= 24 + 10

        if showsCredentials {
            userField.frame = NSRect(x: 20, y: y - 24, width: width - 40, height: 24)
            y -= 24 + 10
            passwordField.frame = NSRect(x: 20, y: y - 24, width: width - 40, height: 24)
            y -= 24 + 10
            note.stringValue = "The password is handed to macOS and may be saved in Keychain."
        } else {
            note.stringValue = "NFS uses the system's own authentication; no password is sent."
        }
        userField.isHidden = !showsCredentials
        passwordField.isHidden = !showsCredentials

        note.frame = NSRect(x: 20, y: 52, width: width - 40, height: 16)

        cancelButton.sizeToFit()
        connectButton.sizeToFit()
        let buttonHeight: CGFloat = 24
        cancelButton.frame = NSRect(
            x: width - 20 - connectButton.frame.width - 8 - cancelButton.frame.width,
            y: 16,
            width: cancelButton.frame.width,
            height: buttonHeight
        )
        connectButton.frame = NSRect(
            x: width - 20 - connectButton.frame.width,
            y: 16,
            width: connectButton.frame.width,
            height: buttonHeight
        )

        positionRecent()
    }

    private func positionRecent() {
        guard recentList.isShown else { return }
        let height = recentList.preferredHeight
        recentList.frame = NSRect(
            x: addressField.frame.minX,
            y: addressField.frame.minY - height - 4,
            width: addressField.frame.width,
            height: height
        )
    }

    @objc private func protocolChanged(_ sender: NSSegmentedControl) {
        addressField.placeholderString = showsCredentials ? "server/share" : "192.168.100.100/share"
        hideRecent()
        layoutContent()
    }

    @objc private func cancelClicked(_ sender: NSButton) {
        dismiss()
    }

    @objc private func connectClicked(_ sender: NSButton) {
        guard let url = makeURL() else {
            NSSound.beep()
            return
        }
        let handler = onConnect
        let address = displayAddress()
        dismiss()
        handler?(url, address)
    }

    private func dismiss() {
        hideRecent()
        if let hostWindow {
            hostWindow.endSheet(self)
        }
        close()
    }

    /// The address line may be `host`, `host/share`, `host:/share` or
    /// `host:port/share`. Credentials are only added for SMB.
    private func makeURL() -> URL? {
        ServerAddress.url(
            scheme: showsCredentials ? "smb" : "nfs",
            address: addressField.stringValue,
            user: userField.stringValue,
            password: passwordField.stringValue
        )
    }

    /// What to show in the recent list: the address, with the user in front for
    /// SMB. Never the password.
    private func displayAddress() -> String {
        let address = addressField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard showsCredentials else { return address }
        let user = userField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !user.isEmpty, !address.hasPrefix(user + "@") else { return address }
        return user + "@" + address
    }

    // MARK: Recent addresses

    private func updateRecent() {
        let text = addressField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = recentMatches()
        guard !matches.isEmpty, matches != [text] else {
            hideRecent()
            return
        }
        showRecent(matches)
    }

    /// The button always shows something when there is a history; typing
    /// narrows it to the prefix.
    @objc private func recentClicked(_ sender: NSButton) {
        if recentList.isShown {
            hideRecent()
            return
        }
        let matches = recentMatches()
        guard !matches.isEmpty else {
            NSSound.beep()
            return
        }
        showRecent(matches)
        // Keep the keys with the field: Return picks, typing narrows.
        makeFirstResponder(addressField)
    }

    private func recentMatches() -> [String] {
        let text = addressField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return recentServers }
        let lowered = text.lowercased()
        return recentServers.filter { entry in
            if entry.lowercased().hasPrefix(lowered) { return true }
            // "astral@host/share" should still match when typing the host.
            if let at = entry.firstIndex(of: "@") {
                let rest = String(entry[entry.index(after: at)...]).lowercased()
                return rest.hasPrefix(lowered)
            }
            return false
        }
    }

    private func showRecent(_ matches: [String]) {
        recentList.names = matches
        if recentList.superview == nil {
            contentView?.addSubview(recentList)
        }
        positionRecent()
        recentList.reload()
    }

    private func hideRecent() {
        recentList.removeFromSuperview()
    }

    private func acceptRecent(_ entry: String) {
        // `user@host/share` fills both fields, so only the password is left.
        if let at = entry.firstIndex(of: "@"), !entry[..<at].contains("/") {
            userField.stringValue = String(entry[..<at])
            addressField.stringValue = String(entry[entry.index(after: at)...])
        } else {
            userField.stringValue = ""
            addressField.stringValue = entry
        }
        hideRecent()
        makeFirstResponder(addressField)
    }
}

extension ConnectSheet: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        updateRecent()
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        if recentList.isShown, commandSelector == #selector(NSResponder.moveDown(_:)) {
            recentList.move(1)
            return true
        }
        if recentList.isShown, commandSelector == #selector(NSResponder.moveUp(_:)) {
            recentList.move(-1)
            return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            if recentList.isShown, let pick = recentList.highlighted() {
                acceptRecent(pick)
            } else {
                connectClicked(connectButton)
            }
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            if recentList.isShown {
                hideRecent()
                return true
            }
            return false
        }
        return false
    }
}

/// The list under the address field. It does not take focus; the field editor
/// owns the keys and asks this view to move the highlight.
private final class RecentList: NSView, NSTableViewDataSource, NSTableViewDelegate {
    var names: [String] = []
    var onPick: ((String) -> Void)?

    private let scroll = NSScrollView(frame: .zero)
    private let table = NSTableView(frame: .zero)
    private let rowHeight: CGFloat = 18
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

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("address"))
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
        table.setAccessibilityLabel("Recent servers")

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

    func highlighted() -> String? {
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
        label.font = NSFont.systemFont(ofSize: 11)
        label.lineBreakMode = .byTruncatingTail
        let cell = NSTableCellView()
        cell.addSubview(label)
        cell.textField = label
        return cell
    }

    @objc private func clicked(_ sender: Any?) {
        let row = table.clickedRow
        guard row >= 0, row < names.count else { return }
        onPick?(names[row])
    }
}