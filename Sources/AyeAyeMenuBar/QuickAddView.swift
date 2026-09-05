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
    /// Takes the field's place after a successful create — same row, so the
    /// popover doesn't change height and jump under the pointer.
    private let confirmation = NSStackView()
    private let confirmationLabel = NSTextField(labelWithString: "")

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
        orgLabel.lineBreakMode = .byTruncatingTail
        orgLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .right
        statusLabel.stringValue = "⏎ to create"
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.maximumNumberOfLines = 2
        // Given the row's leftover width rather than sized to its own text,
        // and right-aligned inside it.
        //
        // Sized to its text, "⏎ to create" drew as "⏎ to crea…" — with the
        // label's frame *wider* than the intrinsic width AppKit had just
        // reported for it. The measurement and the drawing disagree, which
        // they can when a string reaches for a glyph outside the label's own
        // font (⏎ is one) and picks up a fallback face at draw time that
        // measures differently. Three points of disagreement is enough to
        // lose the last letter, and no amount of compression-resistance
        // fiddling helps, because nothing is compressing it — it was handed
        // exactly what it asked for. Letting it stretch means there is
        // always more room than the text needs, so the disagreement has
        // nowhere to show up.
        statusLabel.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        let tick = NSImageView()
        tick.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)
        tick.contentTintColor = .systemGreen
        tick.setContentHuggingPriority(.required, for: .horizontal)
        confirmationLabel.font = .systemFont(ofSize: 13)
        confirmationLabel.lineBreakMode = .byTruncatingTail
        confirmation.setViews([tick, confirmationLabel], in: .leading)
        confirmation.orientation = .horizontal
        confirmation.spacing = 6
        confirmation.isHidden = true
        // Matches the field's own height so swapping one for the other
        // doesn't resize the popover.
        confirmation.heightAnchor.constraint(equalToConstant: 22).isActive = true

        // No spacer view: the status label is the thing that stretches now.
        let footer = NSStackView(views: [orgLabel, spinner, statusLabel])
        footer.orientation = .horizontal
        footer.spacing = 6

        let stack = NSStackView(views: [field, confirmation, footer])
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
        clearConfirmation()
        if Settings.isConfigured {
            orgLabel.stringValue = Settings.organisationName ?? "Unknown organisation"
            field.isEnabled = true
            statusLabel.stringValue = "⏎ to create"
        } else {
            orgLabel.stringValue = "Not set up"
            field.isEnabled = false
            statusLabel.stringValue = "Open Settings…"
        }
        // The colour has to be reset too, not just the text: `report` leaves
        // it red after a failure, and without this the next time you opened
        // the box its ordinary "⏎ to create" hint was still red — a warning
        // about nothing, on a box you had not yet typed into.
        statusLabel.textColor = .secondaryLabelColor
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

    /// The confirmation, and it is deliberately louder than the rest of this
    /// view is.
    ///
    /// The first version reported success as a grey "Created" in the corner
    /// for 700ms and then closed the popover — which is a confirmation you
    /// can miss completely, and missing it on a capture tool means
    /// wondering whether to type the thing again. So the whole box says it
    /// instead: the field is replaced by the title that was filed, under a
    /// green tick, and it stays up long enough to actually read.
    func confirm(title: String) {
        field.isHidden = true
        confirmation.isHidden = false
        confirmationLabel.stringValue = title
        statusLabel.stringValue = "Created"
        statusLabel.textColor = .systemGreen
    }

    /// Put the box back the way it was. Called from `refresh()`, i.e. when
    /// the popover reopens, rather than on a timer of its own — so the
    /// confirmation stays up for exactly as long as the popover does, and
    /// no caller has to remember to undo it.
    private func clearConfirmation() {
        field.isHidden = false
        confirmation.isHidden = true
    }
}
