import AppKit

/// Find by name, with an optional recursive scope.
final class FilterBar: NSView {
    static let preferredHeight: CGFloat = 30

    let field = NSSearchField()
    var onScopeChange: ((Bool) -> Void)?
    private let subfolders = NSButton(checkboxWithTitle: "Include subfolders", target: nil, action: nil)
    var onChange: ((String) -> Void)?
    /// Escape, or a click on the field's cancel button.
    var onCancel: (() -> Void)?

    var isEditing: Bool {
        window?.firstResponder === field.currentEditor()
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        field.placeholderString = "Find by name"
        field.font = NSFont.systemFont(ofSize: 12)
        field.sendsWholeSearchString = false
        field.sendsSearchStringImmediately = true
        field.target = self
        field.action = #selector(changed(_:))
        field.delegate = self
        addSubview(field)
        subfolders.target = self
        subfolders.action = #selector(scopeChanged(_:))
        addSubview(subfolders)

    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layout() {
        super.layout()
        let scopeWidth = subfolders.intrinsicContentSize.width
        let scopeX = bounds.width - scopeWidth - 8
        field.frame = NSRect(x: 8, y: 4, width: max(0, scopeX - 24), height: 22)
        subfolders.frame = NSRect(x: scopeX, y: 4, width: scopeWidth, height: 22)
    }

    @objc private func changed(_ sender: Any?) {
        onChange?(field.stringValue)
    }

    @objc private func scopeChanged(_ sender: Any?) {
        onScopeChange?(subfolders.state == .on)
    }

    func resetScope() {
        subfolders.state = .off
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
    /// Live while typing. The field's action only fires when editing ends, which
    /// would make the search wait for a click somewhere else.
    func controlTextDidChange(_ obj: Notification) {
        onChange?(field.stringValue)
    }

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
