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
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 380),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Keyboard Shortcuts"
        window.isReleasedWhenClosed = false
        super.init(window: window)

        let content = window.contentView ?? NSView()

        let title = NSTextField(labelWithString: "Keyboard Shortcuts")
        title.font = NSFont.systemFont(ofSize: 17, weight: .semibold)
        title.frame = NSRect(x: 20, y: 340, width: 300, height: 24)
        content.addSubview(title)

        let subtitle = NSTextField(labelWithString: "Roach Explorer — key bindings at a glance")
        subtitle.font = NSFont.systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.frame = NSRect(x: 20, y: 318, width: 380, height: 16)
        content.addSubview(subtitle)

        var y: CGFloat = 280
        for (key, action) in Self.shortcuts {
            let keyField = NSTextField(labelWithString: key)
            keyField.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
            keyField.textColor = .secondaryLabelColor
            keyField.frame = NSRect(x: 20, y: y, width: 80, height: 18)
            content.addSubview(keyField)

            let actionField = NSTextField(labelWithString: action)
            actionField.font = NSFont.systemFont(ofSize: 12)
            actionField.frame = NSRect(x: 110, y: y, width: 290, height: 18)
            content.addSubview(actionField)

            y -= 22
        }

        let note = NSTextField(labelWithString: "Also: ⌘Q Quit, ⌘H Hide, ⌥⌘H Hide Others")
        note.font = NSFont.systemFont(ofSize: 10)
        note.textColor = .tertiaryLabelColor
        note.frame = NSRect(x: 20, y: 16, width: 380, height: 14)
        content.addSubview(note)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}
