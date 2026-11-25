import AppKit

/// The "Compress" sheet: pick a format, a compression, and an editable name.
/// It is a sheet on the window, so the window stays put behind it.
final class ArchiveSheet: NSObject {
    private var window: NSWindow?
    private var panel: NSWindow?
    private let formatPop = NSPopUpButton()
    private let compressionPop = NSPopUpButton()
    private let nameField = NSTextField()
    private let extensionLabel = NSTextField(labelWithString: "")
    private var spec = ArchiveSpec(format: .zip, compression: .none)

    /// `completion` gets the chosen spec and the typed stem (no extension).
    /// The controls' targets are not retained, so the sheet object must outlive
    /// `present`; hold it until the sheet closes.
    private static var active: ArchiveSheet?

    static func present(
        for parent: NSWindow?,
        defaultStem: String,
        completion: @escaping (ArchiveSpec, String) -> Void
    ) {
        let sheet = ArchiveSheet()
        sheet.build(defaultStem: defaultStem)
        sheet.completion = completion
        active = sheet
        if let parent {
            parent.beginSheet(sheet.panel!) { _ in }
        } else {
            sheet.panel!.makeKeyAndOrderFront(nil)
        }
    }

    private var completion: ((ArchiveSpec, String) -> Void)?

    private func build(defaultStem: String) {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 168))
        let labelFont = NSFont.systemFont(ofSize: 12)
        let controlFont = NSFont.systemFont(ofSize: 12)

        func label(_ text: String, _ x: CGFloat, _ y: CGFloat, width: CGFloat) -> NSTextField {
            let l = NSTextField(labelWithString: text)
            l.font = labelFont
            l.frame = NSRect(x: x, y: y, width: width, height: 18)
            return l
        }

        content.addSubview(label("Format:", 20, 128, width: 90))
        formatPop.frame = NSRect(x: 116, y: 124, width: 244, height: 26)
        formatPop.font = controlFont
        for format in ArchiveFormat.allCases {
            formatPop.addItem(withTitle: format.title)
        }
        formatPop.target = self
        formatPop.action = #selector(formatChanged(_:))
        formatPop.menu?.autoenablesItems = false
        content.addSubview(formatPop)

        content.addSubview(label("Compression:", 20, 92, width: 90))
        compressionPop.frame = NSRect(x: 116, y: 88, width: 244, height: 26)
        compressionPop.font = controlFont
        for compression in ArchiveCompression.allCases {
            compressionPop.addItem(withTitle: compression.title)
        }
        compressionPop.target = self
        compressionPop.action = #selector(compressionChanged(_:))
        compressionPop.menu?.autoenablesItems = false
        content.addSubview(compressionPop)

        content.addSubview(label("Save as:", 20, 56, width: 90))
        nameField.frame = NSRect(x: 116, y: 52, width: 180, height: 24)
        nameField.font = controlFont
        nameField.stringValue = defaultStem
        nameField.setAccessibilityLabel("Archive name")
        content.addSubview(nameField)

        extensionLabel.font = controlFont
        extensionLabel.textColor = .secondaryLabelColor
        extensionLabel.frame = NSRect(x: 300, y: 54, width: 60, height: 18)
        content.addSubview(extensionLabel)

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        cancel.frame = NSRect(x: 196, y: 12, width: 80, height: 28)
        content.addSubview(cancel)

        let create = NSButton(title: "Create", target: self, action: #selector(create(_:)))
        create.bezelStyle = .rounded
        create.keyEquivalent = "\r"
        create.frame = NSRect(x: 282, y: 12, width: 80, height: 28)
        content.addSubview(create)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 168),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = "Compress"
        window.isReleasedWhenClosed = false
        window.contentView = content
        window.initialFirstResponder = nameField
        self.window = window
        self.panel = window

        updateSpec()
    }

    private func updateSpec() {
        let format = ArchiveFormat(rawValue: formatPop.indexOfSelectedItem) ?? .zip
        let compression = ArchiveCompression(rawValue: compressionPop.indexOfSelectedItem) ?? .none
        spec = ArchiveSpec(format: format, compression: compression)
        // Compression only applies to TAR; ZIP is always deflate inside.
        compressionPop.isEnabled = format == .tar
        extensionLabel.stringValue = spec.fileExtension
    }

    @objc private func formatChanged(_ sender: Any?) { updateSpec() }
    @objc private func compressionChanged(_ sender: Any?) { updateSpec() }

    @objc private func cancel(_ sender: Any?) { finish(stem: nil) }

    @objc private func create(_ sender: Any?) {
        let stem = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        finish(stem: stem.isEmpty ? "Archive" : stem)
    }

    private func finish(stem: String?) {
        let done = completion
        completion = nil
        if ArchiveSheet.active === self { ArchiveSheet.active = nil }
        if let panel {
            window?.parent?.endSheet(panel)
        }
        panel?.close()
        if let stem {
            done?(spec, stem)
        } else {
            // Cancel: no completion call.
        }
    }
}