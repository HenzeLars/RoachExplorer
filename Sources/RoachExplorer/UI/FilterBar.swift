import AppKit

/// The Cmd+F row under the path bar. Hidden until asked for. It narrows
/// the open folder by name; it never searches the disk.
final class FilterBar: NSView {
    static let preferredHeight: CGFloat = 30

    let field = NSSearchField()

    var onChange: ((String) -> Void)?
    /// Escape, or a click on the field's cancel button.
    var onCancel: (() -> Void)?

    var isEditing: Bool {
        window?.firstResponder === field.currentEditor()
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        field.placeholderString = "Filter by name"
        field.font = NSFont.systemFont(ofSize: 12)
        field.sendsWholeSearchString = false
        field.sendsSearchStringImmediately = true
        field.target = self
        field.action = #selector(changed(_:))
        field.delegate = self
        addSubview(field)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layout() {
        super.layout()
        field.frame = NSRect(x: 8, y: 4, width: max(0, bounds.width - 16), height: 22)
    }

    @objc private func changed(_ sender: Any?) {
        onChange?(field.stringValue)
    }

    func focus() {
        window?.makeFirstResponder(field)
        let range = NSRange(location: 0, length: (field.stringValue as NSString).length)
        field.currentEditor()?.selectedRange = range
    }

    func clear() {
        field.stringValue = ""
        onChange?("")
    }
}

extension FilterBar: NSSearchFieldDelegate {
    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            onCancel?()
            return true
        }
        return false
    }
}
