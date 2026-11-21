import AppKit

/// One window for the selection. Several items are a summary, not one window each.
/// Folder size, including subfolders, is counted here and nowhere in the status bar.
/// A single item can change its mode. A folder keeps execute: without it, it cannot be entered.
final class InfoWindow: NSWindowController {
    private let kindValue = InfoWindow.valueField()
    private let sizeValue = InfoWindow.valueField()
    private let createdValue = InfoWindow.valueField()
    private let whenValue = InfoWindow.valueField()
    private let ownerValue = InfoWindow.valueField()
    private let groupValue = InfoWindow.valueField()
    private let whereValue = InfoWindow.valueField()
    private let accessCaption = NSTextField(labelWithString: "Access")
    private let permissions = PermissionEditor()
    private var walk: SummaryWalk?
    private var generation = 0
    private var editingURL: URL?

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 418),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Get Info"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        let content = window.contentView ?? NSView()
        addRow("Kind", kindValue, y: 370, in: content)
        addRow("Size", sizeValue, y: 340, in: content)
        addRow("Created", createdValue, y: 310, in: content)
        addRow("Modified", whenValue, y: 280, in: content)
        addRow("Owner", ownerValue, y: 250, in: content)
        addRow("Group", groupValue, y: 220, in: content)
        addRow("Where", whereValue, y: 164, in: content)
        whereValue.frame.size.height = 36
        whereValue.maximumNumberOfLines = 2
        whereValue.cell?.wraps = true
        whereValue.lineBreakMode = .byTruncatingMiddle

        accessCaption.font = NSFont.systemFont(ofSize: 12)
        accessCaption.textColor = .secondaryLabelColor
        accessCaption.frame = NSRect(x: 20, y: 93, width: 80, height: 22)
        content.addSubview(accessCaption)
        permissions.frame = NSRect(x: 104, y: 16, width: 340, height: 132)
        permissions.onChange = { [weak self] mode in
            self?.apply(mode)
        }
        content.addSubview(permissions)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func show(items: [FileItem], folder: URL) {
        walk?.cancel()
        generation += 1
        let token = generation
        let many = items.count > 1
        let folderSummary = items.count == 1 && items[0].isFolder && !items[0].isLink
        if many {
            window?.title = "Summary"
        } else if folderSummary, let name = items.first?.name {
            window?.title = "Summary — \(name)"
        } else {
            window?.title = items.first?.name ?? "Get Info"
        }
        accessCaption.isHidden = many
        permissions.isHidden = many
        editingURL = many ? nil : items.first?.url

        if many {
            let folders = items.filter { $0.isFolder && !$0.isLink }.count
            kindValue.stringValue = "\(items.count - folders) files, \(folders) folders"
            // A summary does not claim one date or one owner.
            whenValue.stringValue = "—"
            createdValue.stringValue = "—"
            ownerValue.stringValue = "—"
            groupValue.stringValue = "—"
        } else if let item = items.first {
            kindValue.stringValue = item.kind
            whenValue.stringValue = Format.date(item.modified)
            createdValue.stringValue = Permissions.created(of: item.url).map(Format.date) ?? "—"
            if let names = Permissions.ownership(of: item.url) {
                ownerValue.stringValue = names.owner
                groupValue.stringValue = names.group
            } else {
                ownerValue.stringValue = "—"
                groupValue.stringValue = "—"
            }
            if let url = editingURL, let mode = Permissions.mode(of: url) {
                permissions.setMode(mode, lockExecute: Permissions.isDirectory(url))
            }
        }
        whereValue.stringValue = many ? folder.path : (items.first?.url.path ?? folder.path)

        let needsWalk = items.contains { $0.isFolder && !$0.isLink }
        if !needsWalk {
            let known = items.reduce(Int64(0)) { $0 + $1.size }
            sizeValue.stringValue = Format.size(known)
        } else {
            sizeValue.stringValue = folderSummary ? "Calculating contents…" : "Calculating…"
            let snapshot = items.map { ($0.url, $0.isFolder, $0.isLink, $0.size) }
            let job = SummaryWalk()
            walk = job
            DispatchQueue.global(qos: .utility).async { [weak self] in
                var lastPaint = Date.distantPast
                let tally = job.measure(items: snapshot) { bytes in
                    let now = Date()
                    guard now.timeIntervalSince(lastPaint) > 0.12 else { return }
                    lastPaint = now
                    DispatchQueue.main.async {
                        guard let self, token == self.generation else { return }
                        self.sizeValue.stringValue = "Calculating… \(Format.size(bytes))"
                    }
                }
                let text = Self.walkedSize(tally)
                DispatchQueue.main.async {
                    guard let self, token == self.generation else { return }
                    self.sizeValue.stringValue = text
                }
            }
        }
        placeNearMouse()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Beside the pointer, on the same screen. A fixed origin is the bottom-left
    /// corner, which on a wide display is nowhere near the click.
    private func placeNearMouse() {
        guard let window else { return }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? window.screen
            ?? NSScreen.main
        guard let screen else { return }
        let visible = screen.visibleFrame
        let frame = window.frame
        let gap: CGFloat = 12

        var x = mouse.x + gap
        if x + frame.width > visible.maxX - 8 {
            x = mouse.x - frame.width - gap
        }
        var y = mouse.y - frame.height - gap
        if y < visible.minY + 8 {
            y = mouse.y + gap
        }
        x = clamped(x, lower: visible.minX + 8, upper: visible.maxX - frame.width - 8)
        y = clamped(y, lower: visible.minY + 8, upper: visible.maxY - frame.height - 8)
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func clamped(_ value: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
        if upper < lower { return lower }
        return min(max(value, lower), upper)
    }

    /// A walked size always names the item count, including zero, so an empty
    /// folder does not look like a size that was never counted.
    private static func walkedSize(_ tally: SummaryTally) -> String {
        let items = tally.files == 1 ? "1 item" : "\(tally.files) items"
        var text = Format.size(tally.bytes)
        if tally.bytes >= 1024 {
            text += " (\(Format.groupedBytes(tally.bytes)), \(items))"
        } else {
            text += " (\(items))"
        }
        if tally.unreadable > 0 {
            text += ", some unreadable"
        }
        return text
    }

    private func apply(_ mode: UInt16) {
        guard let editingURL else { return }
        do {
            try Permissions.setMode(mode, of: editingURL)
        } catch {
            if let restored = Permissions.mode(of: editingURL) {
                permissions.setMode(restored, lockExecute: Permissions.isDirectory(editingURL))
            }
            guard let window else { return }
            let alert = NSAlert(error: error)
            alert.beginSheetModal(for: window, completionHandler: nil)
        }
    }

    private func addRow(_ caption: String, _ value: NSTextField, y: CGFloat, in content: NSView) {
        let key = NSTextField(labelWithString: caption)
        key.font = NSFont.systemFont(ofSize: 12)
        key.textColor = .secondaryLabelColor
        key.frame = NSRect(x: 20, y: y, width: 80, height: 22)
        value.frame = NSRect(x: 104, y: y, width: 336, height: 22)
        value.setAccessibilityLabel(caption)
        content.addSubview(key)
        content.addSubview(value)
    }

    private static func valueField() -> NSTextField {
        let field = NSTextField(labelWithString: "")
        field.font = NSFont.systemFont(ofSize: 12)
        field.lineBreakMode = .byTruncatingMiddle
        return field
    }
}

/// Nine letters: user, group, other. A filled chip is set. An empty chip is not.
/// Under each group: the dashes (`rwx`, `r-x`) and the octal digit (`7`, `5`).
/// Execute on a folder does not toggle off.
final class PermissionEditor: NSView {
    var onChange: ((UInt16) -> Void)?
    private var mode: UInt16 = 0
    private var lockExecute = false
    private var buttons: [NSButton] = []
    private var readouts: [NSTextField] = []
    private var digits: [NSTextField] = []
    private let groups = ["User", "Group", "Other"]
    private let buttonSize: CGFloat = 28
    private let buttonGap: CGFloat = 6
    private let groupGap: CGFloat = 18

    override init(frame: NSRect) {
        super.init(frame: frame)
        let letters = ["r", "w", "x"]
        for index in 0..<9 {
            let button = ModeBitButton(title: letters[index % 3], target: self, action: #selector(toggle(_:)))
            button.tag = index
            button.setButtonType(.toggle)
            button.isBordered = false
            button.setAccessibilityLabel(accessName(index))
            buttons.append(button)
            addSubview(button)
        }
        for name in groups {
            let readout = NSTextField(labelWithString: "---")
            readout.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
            readout.alignment = .center
            readouts.append(readout)
            addSubview(readout)

            let digit = NSTextField(labelWithString: "0")
            digit.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold)
            digit.alignment = .center
            digit.setAccessibilityLabel("\(name) number")
            digits.append(digit)
            addSubview(digit)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func setMode(_ mode: UInt16, lockExecute: Bool) {
        self.mode = mode
        self.lockExecute = lockExecute
        refresh()
    }

    override func layout() {
        super.layout()
        let groupWidth = buttonSize * 3 + buttonGap * 2
        for (group, title) in groups.enumerated() {
            let x = CGFloat(group) * (groupWidth + groupGap)
            let label = groupLabel(title)
            label.frame = NSRect(x: x, y: 110, width: groupWidth, height: 16)
            for bit in 0..<3 {
                let button = buttons[group * 3 + bit]
                let buttonX = x + CGFloat(bit) * (buttonSize + buttonGap)
                button.frame = NSRect(x: buttonX, y: 74, width: buttonSize, height: buttonSize)
            }
            readouts[group].frame = NSRect(x: x, y: 48, width: groupWidth, height: 18)
            digits[group].frame = NSRect(x: x, y: 24, width: groupWidth, height: 18)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        buttons.forEach { $0.needsDisplay = true }
        refresh()
    }

    private func groupLabel(_ title: String) -> NSTextField {
        if let existing = subviews.first(where: { ($0 as? NSTextField)?.stringValue == title }) as? NSTextField {
            return existing
        }
        let label = NSTextField(labelWithString: title)
        label.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        addSubview(label)
        return label
    }

    @objc private func toggle(_ sender: NSButton) {
        let index = sender.tag
        let bit = UInt16(1 << (8 - index))
        let clearingExecute = lockExecute && index % 3 == 2 && (mode & bit) != 0
        if clearingExecute {
            refresh()
            NSSound.beep()
            return
        }
        if mode & bit == 0 {
            mode |= bit
        } else {
            mode &= ~bit
        }
        refresh()
        onChange?(mode)
    }

    private func refresh() {
        let letters = ["r", "w", "x"]
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
        for (index, button) in buttons.enumerated() {
            let bit = UInt16(1 << (8 - index))
            let on = mode & bit != 0
            button.state = on ? .on : .off
            button.needsDisplay = true
            if lockExecute && index % 3 == 2 {
                button.toolTip = "A folder needs execute, or it cannot be entered."
            } else {
                button.toolTip = nil
            }
        }
        for group in 0..<3 {
            let text = NSMutableAttributedString()
            for bit in 0..<3 {
                let index = group * 3 + bit
                let on = mode & UInt16(1 << (8 - index)) != 0
                text.append(NSAttributedString(string: on ? letters[bit] : "-", attributes: [
                    .font: font,
                    .foregroundColor: on ? NSColor.labelColor : NSColor.secondaryLabelColor,
                ]))
            }
            readouts[group].attributedStringValue = text
            digits[group].integerValue = triad(group)
        }
        setAccessibilityValue(Permissions.symbolic(mode))
    }

    /// `rwx` is 7, `rw-` is 6, `r-x` is 5, and so on.
    private func triad(_ group: Int) -> Int {
        var value = 0
        for bit in 0..<3 where mode & UInt16(1 << (8 - (group * 3 + bit))) != 0 {
            value |= 1 << (2 - bit)
        }
        return value
    }

    private func accessName(_ index: Int) -> String {
        let who = ["User", "Group", "Other"][index / 3]
        let what = ["read", "write", "execute"][index % 3]
        return "\(who) \(what)"
    }
}

/// Filled accent chip when the bit is set. Empty box when it is not.
final class ModeBitButton: NSButton {
    override func draw(_ dirtyRect: NSRect) {
        let on = state == .on
        let rect = bounds.insetBy(dx: 1.5, dy: 1.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        if on {
            NSColor.controlAccentColor.setFill()
            path.fill()
        } else {
            NSColor.separatorColor.setStroke()
            path.lineWidth = 1.5
            path.stroke()
        }
        let font = NSFont.monospacedSystemFont(ofSize: 14, weight: .bold)
        let color: NSColor = on ? .alternateSelectedControlTextColor : .labelColor
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let text = title as NSString
        let size = text.size(withAttributes: attrs)
        let point = NSPoint(
            x: floor((bounds.width - size.width) / 2),
            y: floor((bounds.height - size.height) / 2) - 1
        )
        text.draw(at: point, withAttributes: attrs)
    }
}
