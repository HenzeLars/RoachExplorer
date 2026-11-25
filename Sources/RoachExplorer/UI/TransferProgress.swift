import AppKit

/// Shown only if a copy or move is still running after a few seconds.
/// Cancel stops between files. "Decide on collisions now" sets the
/// answer for every collision still ahead.
final class TransferProgress: NSObject {
    var onCancel: (() -> Void)?
    var onDecide: (() -> Void)?
    /// Archives have no mid-run collisions, so the "Decide on collisions now"
    /// button is hidden and the bar is indeterminate.
    var showsDecide = true
    var indeterminate = false

    private var panel: NSWindow?
    private var closed = false
    private let nameLabel = NSTextField(labelWithString: "")
    private let bar = NSProgressIndicator()

    func show(title: String) {
        if closed || panel != nil { return }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 118),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.isReleasedWhenClosed = false
        let content = window.contentView ?? NSView()

        nameLabel.font = NSFont.systemFont(ofSize: 12)
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.frame = NSRect(x: 20, y: 72, width: 380, height: 18)
        content.addSubview(nameLabel)

        bar.isIndeterminate = indeterminate
        bar.minValue = 0
        bar.maxValue = 1
        bar.frame = NSRect(x: 20, y: 48, width: 380, height: 16)
        content.addSubview(bar)

        if showsDecide {
            let decide = NSButton(title: "Decide on collisions now", target: self, action: #selector(decide(_:)))
            decide.bezelStyle = .rounded
            decide.frame = NSRect(x: 16, y: 12, width: 210, height: 28)
            content.addSubview(decide)
        }

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        cancel.frame = NSRect(x: 320, y: 12, width: 84, height: 28)
        content.addSubview(cancel)

        window.center()
        window.makeKeyAndOrderFront(nil)
        panel = window
    }

    func update(name: String, index: Int, total: Int) {
        nameLabel.stringValue = name
        bar.doubleValue = total == 0 ? 0 : Double(index) / Double(total)
    }

    /// Hide while the collision question is up. The panel can come back.
    func orderOut() {
        panel?.orderOut(nil)
    }

    func orderFront() {
        guard !closed, panel != nil else { return }
        panel?.makeKeyAndOrderFront(nil)
    }

    func close() {
        closed = true
        panel?.close()
        panel = nil
    }

    @objc private func cancel(_ sender: Any?) {
        onCancel?()
    }

    @objc private func decide(_ sender: Any?) {
        onDecide?()
    }
}
