import AppKit

/// The whole app, visually: one text field, the organisation it will file
/// into, and a hint.
///
/// No Create button. Return submits and Escape dismisses, which is what
/// anybody typing into a box that appeared under a keystroke will try
/// first — and a button you never press is a button taking up space in a
/// popover that exists to be small. The organisation is a label rather than
/// a picker for the same reason: it is there so you can see where the task
/// is going, and changing it is a once-a-month act that belongs in Settings.
final class QuickAddView: NSView, NSTextFieldDelegate {
    private let field = NSTextField()
    private let orgLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()

    /// Called with the title to create. Returns when the task exists.
    var onSubmit: ((String) async -> Void)?
    var onEscape: (() -> Void)?
    var onOpenSettings: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        build()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func build() {
        field.placeholderString = "New task…"
        field.font = .systemFont(ofSize: 15)
        field.delegate = self
        field.bezelStyle = .roundedBezel
        field.focusRingType = .none

        orgLabel.font = .systemFont(ofSize: 11)
        orgLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .right
        statusLabel.stringValue = "⏎ to create"
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.maximumNumberOfLines = 2

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        let footer = NSStackView(views: [orgLabel, NSView(), spinner, statusLabel])
        footer.orientation = .horizontal
        footer.spacing = 6

        let stack = NSStackView(views: [field, footer])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
        ])
    }

    /// Called every time the popover opens, not just once: the organisation
    /// can change in Settings while this view is alive, and a stale label
    /// would be a quiet lie about where the next task is going.
    func refresh() {
        if Settings.isConfigured {
            orgLabel.stringValue = Settings.organisationName ?? "Unknown organisation"
            field.isEnabled = true
            statusLabel.stringValue = "⏎ to create"
        } else {
            orgLabel.stringValue = "Not set up"
            field.isEnabled = false
            statusLabel.stringValue = "Open Settings…"
        }
        field.stringValue = ""
        window?.makeFirstResponder(field)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            submit()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onEscape?()
            return true
        default:
            return false
        }
    }

    private func submit() {
        let title = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        guard Settings.isConfigured else {
            onOpenSettings?()
            return
        }
        field.isEnabled = false
        spinner.startAnimation(nil)
        statusLabel.stringValue = "Creating…"
        Task { @MainActor in
            await onSubmit?(title)
            spinner.stopAnimation(nil)
            field.isEnabled = true
            // Deliberately not cleared on failure. The text you typed is the
            // only copy of it, and a popover that empties itself when the
            // network is down loses the thought it was created to catch.
            window?.makeFirstResponder(field)
        }
    }

    func report(_ message: String, isError: Bool) {
        statusLabel.stringValue = message
        statusLabel.textColor = isError ? .systemRed : .secondaryLabelColor
        if !isError { field.stringValue = "" }
    }
}
