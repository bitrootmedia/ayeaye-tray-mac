import AppKit

/// The whole app, visually: one text field, the organisation it will file
/// into, and — when there are any — the critical tasks waiting for you.
///
/// No Create button. Return submits and Escape dismisses, which is what
/// anybody typing into a box that appeared under a keystroke will try
/// first, and a button you never press is a button taking up space in a
/// popover that exists to be small.
final class QuickAddView: NSView, NSTextFieldDelegate {
    private let field = NSTextField()
    private let orgButton = NSButton()
    private let statusLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    /// Takes the field's place after a successful create — same row, so the
    /// popover doesn't change height and jump under the pointer.
    private let confirmation = NSStackView()
    private let confirmationLabel = NSTextField(labelWithString: "")
    private let openButton = NSButton()
    /// Hidden entirely when nothing is critical. A heading over an empty
    /// list is a heading that trains you to stop reading it.
    private let criticalSection = NSStackView()
    private let criticalHeading = NSTextField(labelWithString: "")
    private let criticalList = NSStackView()

    /// Called with the title to create. Returns when the task exists.
    var onSubmit: ((String) async -> Void)?
    var onEscape: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    /// The organisation name was clicked — show the picker, anchored to it.
    var onPickOrganisation: ((NSView) -> Void)?
    var onOpenTask: ((String) -> Void)?

    private var createdTaskID: String?

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

        // A real button, not a label with a click handler: it has to *look*
        // clickable, and the chevron is what says the organisation is a
        // choice rather than a caption. Borderless keeps it as quiet as the
        // label it replaced.
        orgButton.bezelStyle = .inline
        orgButton.isBordered = false
        orgButton.font = .systemFont(ofSize: 11)
        orgButton.contentTintColor = .secondaryLabelColor
        orgButton.imagePosition = .imageTrailing
        orgButton.image = NSImage(
            systemSymbolName: "chevron.up.chevron.down", accessibilityDescription: nil)
        orgButton.target = self
        orgButton.action = #selector(pickOrganisation)
        orgButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

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
        // always more room than the text needs.
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
        openButton.title = "Open"
        openButton.bezelStyle = .rounded
        openButton.controlSize = .small
        openButton.font = .systemFont(ofSize: 11)
        openButton.target = self
        openButton.action = #selector(openCreated)
        openButton.setContentHuggingPriority(.required, for: .horizontal)
        confirmation.setViews([tick, confirmationLabel, openButton], in: .leading)
        confirmation.orientation = .horizontal
        confirmation.spacing = 6
        confirmation.isHidden = true
        // Matches the field's own height so swapping one for the other
        // doesn't resize the popover.
        confirmation.heightAnchor.constraint(equalToConstant: 22).isActive = true

        // No spacer view: the status label is the thing that stretches now.
        let footer = NSStackView(views: [orgButton, spinner, statusLabel])
        footer.orientation = .horizontal
        footer.spacing = 6

        // Red as a dot, with the words at full contrast beside it.
        //
        // The heading was `.systemRed` text and it was reported unreadable —
        // correctly: system red at 11pt on the popover's own light grey is
        // right at the edge of legible, and this is a line you are meant to
        // read at a glance. It is the same rule the web app already settled
        // on for status ("colour lives in a dot, not a pill" — a table of
        // saturated text is confetti, and the dot keeps the label at full
        // contrast). The red is still there and still means the same thing;
        // it just stopped being the thing the words are made of.
        let dot = NSImageView()
        dot.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)
        dot.symbolConfiguration = .init(pointSize: 7, weight: .regular)
        dot.contentTintColor = .systemRed
        dot.setContentHuggingPriority(.required, for: .horizontal)
        criticalHeading.font = .systemFont(ofSize: 11, weight: .medium)
        criticalHeading.textColor = .labelColor
        let headingRow = NSStackView(views: [dot, criticalHeading])
        headingRow.orientation = .horizontal
        headingRow.spacing = 5
        criticalList.orientation = .vertical
        criticalList.spacing = 2
        criticalList.alignment = .leading
        let rule = NSBox()
        rule.boxType = .separator
        criticalSection.setViews([rule, headingRow, criticalList], in: .leading)
        criticalSection.orientation = .vertical
        criticalSection.spacing = 6
        criticalSection.alignment = .leading
        criticalSection.isHidden = true

        let stack = NSStackView(views: [field, confirmation, footer, criticalSection])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            // A floor, because the popover is sized from `fittingSize` and
            // that is a *fitting* size: with a short organisation name and
            // nothing critical, the content happily fits in about 240pt,
            // and the box you type into shrinks to match. A quick-capture
            // field that changes width depending on what else is on screen
            // is a worse thing than a little unused space.
            widthAnchor.constraint(greaterThanOrEqualToConstant: 320),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            field.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            confirmation.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            criticalSection.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            rule.widthAnchor.constraint(equalTo: criticalSection.widthAnchor),
        ])
    }

    /// Called every time the popover opens, not just once: the organisation
    /// can change while this view is alive, and a stale label would be a
    /// quiet lie about where the next task is going.
    func refresh() {
        clearConfirmation()
        if Settings.isConfigured {
            orgButton.title = Settings.organisationName ?? "Unknown organisation"
            orgButton.isEnabled = true
            field.isEnabled = true
            statusLabel.stringValue = "⏎ to create"
        } else {
            orgButton.title = "Not set up"
            orgButton.isEnabled = false
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

    // MARK: - Critical tasks

    /// `nil` means "no answer yet", which renders the same as none — but
    /// only one of the two should stay that way, and the caller can tell
    /// them apart.
    func showCritical(_ tasks: [MCPClient.TaskSummary]?) {
        criticalList.setViews([], in: .leading)
        guard let tasks = tasks, !tasks.isEmpty else {
            criticalSection.isHidden = true
            return
        }
        criticalSection.isHidden = false
        criticalHeading.stringValue = tasks.count == 1
            ? "1 critical task waiting for you"
            : "\(tasks.count) critical tasks waiting for you"
        // Five, then a count. A popover that grows without limit stops being
        // a popover, and anybody with more than five critical tasks has a
        // problem this list can't help with anyway.
        for task in tasks.prefix(5) {
            let row = NSButton(title: task.title, target: self, action: #selector(openCritical(_:)))
            row.bezelStyle = .inline
            row.isBordered = false
            row.font = .systemFont(ofSize: 12)
            row.alignment = .left
            row.contentTintColor = .labelColor
            row.identifier = NSUserInterfaceItemIdentifier(task.id)
            row.lineBreakMode = .byTruncatingTail
            criticalList.addView(row, in: .leading)
        }
        if tasks.count > 5 {
            let more = NSTextField(labelWithString: "and \(tasks.count - 5) more")
            more.font = .systemFont(ofSize: 11)
            more.textColor = .secondaryLabelColor
            criticalList.addView(more, in: .leading)
        }
    }

    // MARK: - Actions

    @objc private func pickOrganisation() {
        onPickOrganisation?(orgButton)
    }

    @objc private func openCreated() {
        if let id = createdTaskID { onOpenTask?(id) }
    }

    @objc private func openCritical(_ sender: NSButton) {
        if let id = sender.identifier?.rawValue { onOpenTask?(id) }
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
    /// green tick, with a way straight to it.
    ///
    /// **Open appears only when there is an id to open.** The id is parsed
    /// out of the server's prose answer, so if that ever changes shape the
    /// button disappears rather than opening the web app at a URL with a
    /// hole in it.
    func confirm(title: String, taskID: String?) {
        field.isHidden = true
        confirmation.isHidden = false
        confirmationLabel.stringValue = title
        createdTaskID = taskID
        openButton.isHidden = taskID == nil
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
        createdTaskID = nil
    }
}
