import AppKit

final class WindowController: NSWindowController, NSWindowDelegate {
    private let contentView = NSView()

    init(startingURL: URL?) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Roach Explorer"
        window.minSize = NSSize(width: 480, height: 300)
        window.isReleasedWhenClosed = false

        super.init(window: window)

        window.delegate = self
        window.contentView = contentView
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}
