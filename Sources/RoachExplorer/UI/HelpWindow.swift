import AppKit

/// Keyboard shortcuts reference panel.
final class HelpWindow: NSWindowController {
    private static let shortcuts: [(key: String, action: String)] = [
        ("⌘N", "New Window"),
        ("⇧⌘N", "New Folder"),
        ("⌘O", "Open"),
        ("⌘I", "Get Info"),
        ("⌘C", "Copy"),
        ("⌘⌥C", "Copy Path"),
        ("⌘V", "Paste"),
        ("⌘A", "Select All"),
        ("⌘F", "Filter / Find"),
        ("⌘L", "Focus Path Bar"),
        ("⌘Z", "Undo"),
        ("⇧⌘Z", "Redo"),
        ("⌘R", "Reload"),
        ("⌘[", "Back"),
        ("⌘]", "Forward"),
        ("⌘↑", "Enclosing Folder"),
        ("⌘D", "Duplicate"),
        ("Space", "Quick Look"),
    ]

    init() {
        let rowHeight: CGFloat = 22
        let contentHeight = 60 + CGFloat(HelpWindow.shortcuts.count) * rowHeight + 60
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: contentHeight),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Keyboard Shortcuts"
        window.isReleasedWhenClosed = false
        super.init(window: window)

        let content = window.contentView ?? NSView()

        let title = NSTextField(labelWithString: "Keyboard Shortcuts")
        title.font = NSFont.systemFont(ofSize: 17, weight: .semibold)
        title.frame = NSRect(x: 20, y: contentHeight - 40, width: 300, height: 24)
        content.addSubview(title)

        let subtitle = NSTextField(labelWithString: "Roach Explorer — key bindings at a glance")
        subtitle.font = NSFont.systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.frame = NSRect(x: 20, y: contentHeight - 62, width: 400, height: 16)
        content.addSubview(subtitle)

        var y: CGFloat = contentHeight - 90
        for (key, action) in HelpWindow.shortcuts {
            let keyField = NSTextField(labelWithString: key)
            keyField.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
            keyField.textColor = .secondaryLabelColor
            keyField.frame = NSRect(x: 20, y: y, width: 90, height: 18)
            content.addSubview(keyField)

            let actionField = NSTextField(labelWithString: action)
            actionField.font = NSFont.systemFont(ofSize: 12)
            actionField.frame = NSRect(x: 120, y: y, width: 300, height: 18)
            content.addSubview(actionField)

            y -= rowHeight
        }

        let note = NSTextField(labelWithString: "Also: ⌘Q Quit, ⌘H Hide, ⌥⌘H Hide Others")
        note.font = NSFont.systemFont(ofSize: 10)
        note.textColor = .tertiaryLabelColor
        note.frame = NSRect(x: 20, y: 16, width: 400, height: 14)
        content.addSubview(note)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}
