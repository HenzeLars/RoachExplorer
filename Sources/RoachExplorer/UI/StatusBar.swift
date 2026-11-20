import AppKit

/// Thin bar at the bottom of the window: item count, selection count,
/// and the size of the selection. Right-aligned, like Nautilus.
final class StatusBarView: NSView {
    private let label = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = NSFont.systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.alignment = .right
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    var text: String {
        get { label.stringValue }
        set { label.stringValue = newValue }
    }

    override func layout() {
        super.layout()
        label.sizeToFit()
        let height = label.frame.height
        label.frame = NSRect(
            x: 0,
            y: (bounds.height - height) / 2,
            width: max(0, bounds.width - 16),
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
