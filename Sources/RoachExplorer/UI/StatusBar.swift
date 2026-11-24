import AppKit

/// Thin bar at the bottom of the window: item count, selection count,
/// and the size of the selection. Right-aligned, like Nautilus.
/// The one control on it is "Folders first", a per-folder view setting.
final class StatusBarView: NSView {
    private let label = NSTextField(labelWithString: "")
    private let foldersFirst = NSButton(checkboxWithTitle: "Folders first", target: nil, action: nil)

    /// Called when the user flips the checkbox.
    var onFoldersFirstChange: ((Bool) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = NSFont.systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.alignment = .right

        foldersFirst.font = NSFont.systemFont(ofSize: 11)
        foldersFirst.controlSize = .small
        foldersFirst.target = self
        foldersFirst.action = #selector(toggleFoldersFirst(_:))

        addSubview(label)
        addSubview(foldersFirst)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    var text: String {
        get { label.stringValue }
        set { label.stringValue = newValue }
    }

    /// Shows the state stored for the open folder, without firing the callback.
    var showsFoldersFirst: Bool {
        get { foldersFirst.state == .on }
        set { foldersFirst.state = newValue ? .on : .off }
    }

    @objc private func toggleFoldersFirst(_ sender: NSButton) {
        onFoldersFirstChange?(sender.state == .on)
    }

    override func layout() {
        super.layout()
        foldersFirst.sizeToFit()
        let boxHeight = foldersFirst.frame.height
        foldersFirst.frame = NSRect(
            x: 10,
            y: (bounds.height - boxHeight) / 2,
            width: foldersFirst.frame.width,
            height: boxHeight
        )

        label.sizeToFit()
        let height = label.frame.height
        let textX = foldersFirst.frame.maxX + 8
        label.frame = NSRect(
            x: textX,
            y: (bounds.height - height) / 2,
            width: max(0, bounds.width - textX - 8),
            height: height
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.separatorColor.setStroke()
        let line = NSBezierPath()
        line.move(to: NSPoint(x: 0, y: bounds.maxY - 0.5))
        line.line(to: NSPoint(x: bounds.maxX, y: bounds.maxY - 0.5))
        line.lineWidth = 1
        line.stroke()
    }
}
