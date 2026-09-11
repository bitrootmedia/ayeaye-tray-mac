import AppKit

/// An `NSTextView` that says what it is for while it is empty.
///
/// AppKit gives `NSTextField` a `placeholderString` and gives `NSTextView`
/// nothing, which leaves a bordered empty rectangle sitting under four
/// labelled menus with no label of its own — the one control in the panel
/// that doesn't say what it does. Twelve lines of `draw` is cheaper than the
/// alternatives (a floating label to show and hide, or a text field that
/// treats Return as "done" in the middle of a paragraph).
private final class PlaceholderTextView: NSTextView {
    var placeholder = ""

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? .systemFont(ofSize: 12),
            .foregroundColor: NSColor.placeholderTextColor,
        ]
        // Inset by the container's own inset plus the line fragment padding,
        // so the placeholder starts exactly where typing will.
        let origin = NSPoint(
            x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0),
            y: textContainerInset.height)
        placeholder.draw(at: origin, withAttributes: attributes)
    }
}

/// The scroll view around the description, drawn to match the title field.
///
/// AppKit has one bezel for a text field and another for a scroll view, and
/// they do not look like each other: `roundedBezel` is a soft capsule, and
/// `bezelType = .bezelBorder` is a hard grey rectangle. Side by side in a
/// panel four inches wide, the two boxes you type into read as two
/// different kinds of control — which they are, underneath, and shouldn't
/// be to anybody using them.
///
/// So the scroll view's own border is turned off and this draws the field's
/// instead. In `draw`, deliberately, rather than on a layer: `NSColor`
/// resolves against whatever appearance is current at draw time, so light
/// mode, dark mode and a switch between them while the popover is open are
/// all handled by not doing anything about them. A `CGColor` on a layer is
/// a fixed number and would need every one of those handled by hand.
private final class FieldBox: NSScrollView {
    /// The radius AppKit gives a `roundedBezel` field, which is half the
    /// 22 points such a field is tall — a capsule. There is no API that
    /// reports it, so it is a number here, checked by putting the two boxes
    /// side by side and looking.
    private let radius: CGFloat = 11

    override func draw(_ dirtyRect: NSRect) {
        // Inset by half the line width: a stroke straddles its path, and on
        // the frame's exact edge half of it lands outside the view and is
        // clipped, leaving a border that looks thinner at the edges than in
        // the corners.
        let outline = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        // The appearance is set explicitly rather than assumed: the ordinary
        // draw path makes this view's own current, and `cacheDisplay` —
        // which is how the popover gets rendered offscreen to be looked at —
        // does not.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            // **These two came off a real field's pixels, not out of a
            // guess.** A `roundedBezel` `NSTextField` was drawn into a
            // bitmap in each appearance and sampled: in light mode it is an
            // opaque white with a black hairline at about 8% — near enough
            // `separatorColor` — and in dark mode it is *white at 5%* over
            // whatever is behind it, with **no border at all**. Reaching for
            // `textBackgroundColor` in both, which is the obvious thing to
            // write, gives a box two shades too dark in dark mode; that is
            // the version this replaced.
            if effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua {
                NSColor(white: 1, alpha: 0.05).setFill()
                outline.fill()
            } else {
                NSColor.textBackgroundColor.setFill()
                outline.fill()
                NSColor.separatorColor.setStroke()
                outline.lineWidth = 1
                outline.stroke()
            }
        }
        super.draw(dirtyRect)
    }
}

/// The whole app, visually: a Task/Spark picker, one text field, the
/// organisation it will file into, a Details panel for the times you already
/// know more than a title, and — when there are any — the critical tasks
/// waiting for you.
///
/// **The two modes file two different things.** A task is work somebody is
/// accountable for, in an organisation, with a project and a priority and
/// possibly somebody's name on it. A spark is a line in a notebook — one
/// field, nobody else ever sees it, and no organisation at all. The picker
/// is at the top and not hidden behind anything, because it changes what
/// Return does, and a control that changes what Return does cannot be one
/// you have to go looking for.
///
/// No Create button. Return submits and Escape dismisses, which is what
/// anybody typing into a box that appeared under a keystroke will try
/// first, and a button you never press is a button taking up space in a
/// popover that exists to be small.
///
/// **Everything past the title is behind a disclosure**, closed by default.
/// The whole point of this app is a keystroke, a sentence and Return; five
/// controls on screen for the common case would make the box three times
/// taller to serve the uncommon one. Whether the panel is open is
/// remembered (see `Settings.detailsExpanded`) — what is *in* it is not.
final class QuickAddView: NSView, NSTextFieldDelegate, NSTextViewDelegate {
    /// Task or spark, at the top of the box.
    private let modePicker = NSSegmentedControl()
    private let field = NSTextField()
    private let orgButton = NSButton()
    /// Takes the organisation button's place in spark mode, where naming an
    /// organisation would be a lie about where the thing is going.
    private let sparkNote = NSTextField(labelWithString: "Yours alone, any organisation")
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
    /// The same shape as the critical section, one row below it: hidden when
    /// nothing is being timed, and naming the one task when something is.
    private let timerSection = NSStackView()
    private let timerHeading = NSTextField(labelWithString: "")
    private let timerRow = NSButton()
    private let timerStop = NSButton()

    // The optional half.
    private let detailsToggle = NSButton()
    private let details = NSStackView()
    private let descriptionView = PlaceholderTextView()
    private let projectPopUp = NSPopUpButton()
    private let priorityPopUp = NSPopUpButton()
    private let actionPopUp = NSPopUpButton()
    private let plannerPopUp = NSPopUpButton()
    /// "Work on it now" — start a timer on the task the moment it exists.
    ///
    /// **Unchecked every time the box opens**, and deliberately not a
    /// remembered preference like the panel's visibility is. It is a
    /// statement about one task rather than a way of working: "I am starting
    /// this one now" is true of the thing you are typing and says nothing
    /// about the next thought, and a box that quietly started a clock on
    /// everything you filed would be recording work you were not doing.
    private let timerCheck = NSButton()

    /// Somewhere in the web app this view can send you.
    enum Destination {
        /// A task in the organisation currently selected — which is every
        /// task this box files or lists, since both are org-scoped.
        case task(String)
        /// The task being timed, which is the one thing here that **may be in
        /// another organisation**: there is one running timer per person
        /// across the whole installation, so it carries no id at all and the
        /// caller looks up both halves — see `MCPClient.runningTimer`.
        case timedTask
        /// The Sparks screen. There is no route to a single spark — the list
        /// is the screen — so this carries nothing.
        case sparks
    }

    /// Called with the whole draft. Returns when the task exists.
    var onSubmit: ((MCPClient.Draft) async -> Void)?
    /// The same, in spark mode: one field, and that is the whole record.
    var onSubmitSpark: ((String) async -> Void)?
    var onEscape: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    /// The organisation name was clicked — show the picker, anchored to it.
    var onPickOrganisation: ((NSView) -> Void)?
    var onOpen: ((Destination) -> Void)?
    /// The Details panel was opened and its menus have nothing in them yet.
    var onNeedsLists: (() -> Void)?
    /// The view is a different height now, and only the popover can resize.
    var onResize: (() -> Void)?
    /// The Stop button on the timing row was clicked.
    var onStopTimer: (() -> Void)?

    /// What the confirmation's Open button will open, or `nil` for no button.
    private var createdDestination: Destination?

    /// Six levels, most urgent first — the same order and the same words as
    /// the web app's own Priority menu, so the two don't disagree about what
    /// this field is called or which end is which.
    private static let priorities: [(String, String)] = [
        ("Critical", "critical"),
        ("Urgent", "urgent"),
        ("High", "high"),
        ("Normal", "normal"),
        ("Low", "low"),
        ("Very low", "very_low"),
    ]

    /// The five planner buckets, in the app's own decreasing-urgency order.
    private static let buckets: [(String, String)] = [
        ("Today", "today"),
        ("Tomorrow", "tomorrow"),
        ("This week", "this_week"),
        ("Next week", "next_week"),
        ("Someday", "someday"),
    ]

    override init(frame: NSRect) {
        super.init(frame: frame)
        build()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func build() {
        // Labels, not icons: "Task" and "Spark" are the words the web app
        // uses for the two things, and a 16pt glyph for "a thought you have
        // not decided anything about yet" does not exist.
        modePicker.segmentCount = 2
        modePicker.setLabel("Task", forSegment: 0)
        modePicker.setLabel("Spark", forSegment: 1)
        modePicker.trackingMode = .selectOne
        modePicker.controlSize = .small
        modePicker.font = .systemFont(ofSize: 11)
        modePicker.selectedSegment = Settings.capturesSparks ? 1 : 0
        modePicker.target = self
        modePicker.action = #selector(modeChanged)
        modePicker.toolTip = "What ⏎ files: a task, or a spark only you ever see (⌘J)"
        modePicker.setContentHuggingPriority(.required, for: .horizontal)

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

        sparkNote.font = .systemFont(ofSize: 11)
        sparkNote.textColor = .secondaryLabelColor
        sparkNote.lineBreakMode = .byTruncatingTail

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

        buildDetails()

        // No spacer view: the status label is the thing that stretches now.
        // `orgButton` and `sparkNote` swap places with the mode — an
        // `NSStackView` collapses a hidden arranged view rather than leaving
        // a hole where it was.
        let footer = NSStackView(views: [orgButton, sparkNote, spinner, statusLabel])
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

        // The running timer, built like the critical section above it and for
        // the same reason: it is the other thing this box reports rather than
        // files, it is absent most of the time, and a heading with nothing
        // under it teaches you to stop reading that part of the popover.
        //
        // Green, where critical is red — and again as a glyph rather than as
        // coloured text, which is the rule the heading above settled on. A
        // timer is not a warning: it is the one indicator here that means
        // things are going *well*, and borrowing red for it would spend the
        // colour this app has already given to "look at this now".
        let clock = NSImageView()
        clock.image = NSImage(systemSymbolName: "timer", accessibilityDescription: nil)
        clock.symbolConfiguration = .init(pointSize: 9, weight: .medium)
        clock.contentTintColor = .systemGreen
        clock.setContentHuggingPriority(.required, for: .horizontal)
        timerHeading.font = .systemFont(ofSize: 11, weight: .medium)
        timerHeading.textColor = .labelColor
        timerHeading.lineBreakMode = .byTruncatingTail
        // The heading takes the row's slack so Stop ends up against the right
        // edge — the same trick the footer's status label uses, and for the
        // same reason there is no spacer view here.
        timerHeading.setContentHuggingPriority(
            NSLayoutConstraint.Priority(1), for: .horizontal)
        // Right of the heading, not under the row: it is an action on the
        // thing the heading names, and the row below is the task's own link.
        timerStop.title = "Stop"
        timerStop.bezelStyle = .rounded
        timerStop.controlSize = .small
        timerStop.font = .systemFont(ofSize: 11)
        timerStop.target = self
        timerStop.action = #selector(stopTimer)
        timerStop.setContentHuggingPriority(.required, for: .horizontal)
        timerStop.toolTip = "Stop the timer"
        let timerHeadingRow = NSStackView(views: [clock, timerHeading, timerStop])
        timerHeadingRow.orientation = .horizontal
        timerHeadingRow.spacing = 5
        timerRow.bezelStyle = .inline
        timerRow.isBordered = false
        timerRow.font = .systemFont(ofSize: 12)
        timerRow.alignment = .left
        timerRow.contentTintColor = .labelColor
        timerRow.lineBreakMode = .byTruncatingTail
        timerRow.target = self
        timerRow.action = #selector(openTimed)
        let timerRule = NSBox()
        timerRule.boxType = .separator
        timerSection.setViews([timerRule, timerHeadingRow, timerRow], in: .leading)
        timerSection.orientation = .vertical
        timerSection.spacing = 6
        timerSection.alignment = .leading
        timerSection.isHidden = true

        let stack = NSStackView(
            views: [
                modePicker, field, confirmation, detailsToggle, details, footer,
                criticalSection, timerSection,
            ])
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
            details.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            criticalSection.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            rule.widthAnchor.constraint(equalTo: criticalSection.widthAnchor),
            timerSection.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            timerRule.widthAnchor.constraint(equalTo: timerSection.widthAnchor),
            timerHeadingRow.widthAnchor.constraint(equalTo: timerSection.widthAnchor),
            timerRow.widthAnchor.constraint(equalTo: timerSection.widthAnchor),
        ])
    }

    private func buildDetails() {
        detailsToggle.bezelStyle = .inline
        detailsToggle.isBordered = false
        detailsToggle.font = .systemFont(ofSize: 11)
        detailsToggle.contentTintColor = .secondaryLabelColor
        detailsToggle.imagePosition = .imageLeading
        detailsToggle.target = self
        detailsToggle.action = #selector(toggleDetails)
        // ⌘D reaches it through the responder chain even while the title
        // field has focus, which is where the cursor always is when somebody
        // decides this one needs a project after all.
        detailsToggle.keyEquivalent = "d"
        detailsToggle.keyEquivalentModifierMask = [.command]
        detailsToggle.toolTip = "Description, project, priority, and who it's for (⌘D)"

        // A real NSTextView, not a taller NSTextField: the description is
        // markdown on the server and multi-line by nature, and a field
        // treats Return as "done" — which is exactly the wrong answer inside
        // a paragraph, and the right one in the title box above.
        let scroll = FieldBox()
        scroll.hasVerticalScroller = true
        // Both off: the bezel and the background are `FieldBox`'s job now,
        // and its rounded corners have to be drawn onto something, not over
        // a square grey box already sitting there.
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        // The four lines an `NSTextView` in a scroll view needs and does not
        // get from its initialiser: grow downwards without limit, never
        // sideways, and let the text container follow the view's width.
        // Without the last of them the container keeps the zero width it was
        // born with, and every line of text lays out off the right-hand edge
        // — a box that swallows what you type and shows nothing.
        descriptionView.minSize = NSSize(width: 0, height: 0)
        descriptionView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        descriptionView.isVerticallyResizable = true
        descriptionView.isHorizontallyResizable = false
        descriptionView.textContainer?.widthTracksTextView = true
        descriptionView.textContainer?.containerSize = NSSize(
            width: 0, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = descriptionView
        descriptionView.delegate = self
        // The same size as the title. It is the same thought continued into
        // a second box, and a smaller face there says "fine print", which a
        // description of the work is not.
        descriptionView.font = .systemFont(ofSize: 15)
        descriptionView.drawsBackground = false
        descriptionView.placeholder = "Description — markdown is fine"
        descriptionView.isRichText = false
        // Off, both of them. This is a box for "ring the yard about the
        // shackle" — substitution turning a straight quote curly or
        // capitalising a part number is a change nobody asked for in text
        // that is about to become a permanent record.
        descriptionView.isAutomaticQuoteSubstitutionEnabled = false
        descriptionView.isAutomaticDashSubstitutionEnabled = false
        // Enough to clear the rounded corners, and it lines the first
        // character up with the title's above it — which needs the text
        // container's own five points of padding out of the way first,
        // since AppKit adds that on top of the inset and the field above
        // has no such thing.
        descriptionView.textContainer?.lineFragmentPadding = 0
        descriptionView.textContainerInset = NSSize(width: 7, height: 6)
        descriptionView.autoresizingMask = [.width]
        // Three lines at the title's size, plus the inset.
        scroll.heightAnchor.constraint(equalToConstant: 66).isActive = true

        for popUp in [projectPopUp, priorityPopUp, actionPopUp, plannerPopUp] {
            popUp.controlSize = .small
            popUp.font = .systemFont(ofSize: 11)
        }
        // The two that are just fixed lists can be filled in now. The other
        // two need the server, and are filled in by `showLists`.
        for (title, value) in Self.priorities {
            priorityPopUp.addItem(withTitle: title)
            priorityPopUp.lastItem?.representedObject = value
        }
        priorityPopUp.selectItem(withTitle: "Normal")
        plannerPopUp.addItem(withTitle: "Not planned")
        for (title, value) in Self.buckets {
            plannerPopUp.addItem(withTitle: title)
            plannerPopUp.lastItem?.representedObject = value
        }
        resetLists()

        // A fifth row rather than a line of its own under the grid, so it
        // keeps the panel's rhythm: every optional thing about this task is a
        // label on the left and a control on the right.
        //
        // **In the Details panel, which is closed by default — so the box
        // reads "unchecked" by simply not being on screen.** It belongs with
        // the other four because it is the same kind of thing: something you
        // already know about this one task and would otherwise have to open
        // the web app to say. The one-line version of this box stays one
        // line, which is the whole argument the panel exists to win.
        timerCheck.setButtonType(.switch)
        timerCheck.title = "Work on it now"
        timerCheck.font = .systemFont(ofSize: 11)
        timerCheck.controlSize = .small
        timerCheck.state = .off
        timerCheck.toolTip = "Start timing it as soon as it's created"

        let grid = NSGridView(views: [
            [Self.rowLabel("Project"), projectPopUp],
            [Self.rowLabel("Priority"), priorityPopUp],
            [Self.rowLabel("Action required"), actionPopUp],
            [Self.rowLabel("Planner"), plannerPopUp],
            [Self.rowLabel("Timer"), timerCheck],
        ])
        grid.rowSpacing = 4
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        // Pinned, not sized to content. Left to itself an `NSGridView` hands
        // the leftover width out between its columns, and the labels ended up
        // marooned in the middle of the panel with the menus crammed against
        // the right edge. The label column is as wide as its longest label
        // and no wider; the menus take everything else.
        grid.column(at: 0).width = 92
        // Which they do by filling, rather than each sizing to its own
        // longest project name — four controls of four different widths in a
        // panel this narrow reads as a mistake.
        grid.column(at: 1).xPlacement = .fill

        details.setViews([scroll, grid], in: .leading)
        details.orientation = .vertical
        details.spacing = 8
        details.alignment = .leading
        details.isHidden = !Settings.detailsExpanded
        scroll.widthAnchor.constraint(equalTo: details.widthAnchor).isActive = true
        grid.widthAnchor.constraint(equalTo: details.widthAnchor).isActive = true
        updateDetailsToggle()
    }

    private static func rowLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        return label
    }

    /// Called every time the popover opens, not just once: the organisation
    /// can change while this view is alive, and a stale label would be a
    /// quiet lie about where the next task is going.
    func refresh() {
        clearConfirmation()
        orgButton.title = Settings.isConfigured
            ? (Settings.organisationName ?? "Unknown organisation")
            : "Not set up"
        orgButton.isEnabled = Settings.isConfigured
        field.stringValue = ""
        clearDetails()
        applyMode()
        window?.makeFirstResponder(field)
    }

    // MARK: - Which of the two things this box files

    var isSparkMode: Bool { modePicker.selectedSegment == 1 }

    /// Set from outside — the right-click menu offers both by name, and
    /// picking one there has to arrive here before the box is shown.
    func setSparkMode(_ on: Bool) {
        modePicker.selectedSegment = on ? 1 : 0
        Settings.capturesSparks = on
        applyMode()
    }

    /// Everything that differs between a task and a spark, in one place.
    ///
    /// A spark has no project, no priority, nobody else's name on it and no
    /// organisation, so the Details panel and the organisation button are
    /// not merely disabled but gone: a disabled Project menu invites the
    /// question "why can't I", and the answer is that there is no such
    /// thing here rather than that you lack something.
    ///
    /// **`Settings.detailsExpanded` is left alone while the panel is hidden
    /// this way.** It is the answer to "do you want to see the extra
    /// fields", and switching to Spark for one thought is not a change of
    /// mind about that — switching back has to bring the panel back exactly
    /// as it was.
    private func applyMode() {
        let spark = isSparkMode
        // A spark needs no organisation, so the bar for it is lower — the
        // server's own record has no organisation_id at all, and somebody
        // who has been invited nowhere yet can still capture one.
        let ready = spark ? Settings.isConnected : Settings.isConfigured
        let confirming = !confirmation.isHidden

        field.placeholderString = spark ? "New spark…" : "New task…"
        field.isEnabled = ready
        modePicker.isEnabled = Settings.isConnected
        orgButton.isHidden = spark
        sparkNote.isHidden = !spark
        detailsToggle.isHidden = spark || confirming
        detailsToggle.isEnabled = Settings.isConfigured
        details.isHidden = spark || confirming || !Settings.detailsExpanded
        updateDetailsToggle()
        // Not while the confirmation is up: that owns this line, in green,
        // and it has to outlive anything else touching the box.
        guard !confirming else { return }
        statusLabel.stringValue = ready
            ? (spark ? "⏎ to capture" : "⏎ to create")
            : "Open Settings…"
        // The colour has to be reset too, not just the text: `report` leaves
        // it red after a failure, and without this the next time you opened
        // the box its ordinary hint was still red — a warning about nothing,
        // on a box you had not yet typed into.
        statusLabel.textColor = .secondaryLabelColor
    }

    @objc private func modeChanged() {
        Settings.capturesSparks = isSparkMode
        applyMode()
        onResize?()
        window?.makeFirstResponder(field)
        // Coming back to Task with the panel already open: its menus may
        // never have been fetched, since the panel was closed the whole time
        // the box was in the other mode.
        if !details.isHidden && needsLists { onNeedsLists?() }
    }

    /// Everything optional, back to "not set" — every time the box opens.
    ///
    /// Not remembered on purpose. The panel's *visibility* is a preference;
    /// its contents are one task's answers, and a quick-capture box that
    /// silently applies the last one's project to the next one files work
    /// in the wrong place without ever saying so.
    private func clearDetails() {
        descriptionView.string = ""
        projectPopUp.selectItem(at: 0)
        priorityPopUp.selectItem(withTitle: "Normal")
        actionPopUp.selectItem(at: 0)
        plannerPopUp.selectItem(at: 0)
        timerCheck.state = .off
    }

    // MARK: - The two menus that come from the server

    /// Placeholders, so the panel is never a pair of empty menus.
    private func resetLists() {
        projectPopUp.removeAllItems()
        projectPopUp.addItem(withTitle: "None")
        projectPopUp.isEnabled = true
        actionPopUp.removeAllItems()
        actionPopUp.addItem(withTitle: "Nobody")
        actionPopUp.isEnabled = true
    }

    var needsLists: Bool { projectPopUp.numberOfItems <= 1 && actionPopUp.numberOfItems <= 1 }

    /// `nil` for either list means the server couldn't be asked.
    ///
    /// Said in the menu itself — the whole control goes to "Couldn't load
    /// projects", disabled — rather than in the status line, which is where
    /// "⏎ to create" lives, because this is not a reason not to create.
    /// Every field in this panel is optional, and a task with no project is
    /// exactly what this app made before any of them existed. Disabled and
    /// not merely empty because the two say different things: an empty menu
    /// reads as "you have no projects", which would be a lie about your work
    /// told by a failed network request.
    func showLists(projects: [MCPClient.Project]?, members: [MCPClient.Member]?) {
        resetLists()
        if let projects = projects {
            for project in projects {
                projectPopUp.addItem(withTitle: project.name)
                projectPopUp.lastItem?.representedObject = project.id
            }
        } else {
            projectPopUp.removeAllItems()
            projectPopUp.addItem(withTitle: "Couldn't load projects")
            projectPopUp.isEnabled = false
        }
        if let members = members {
            for member in members {
                actionPopUp.addItem(withTitle: member.isYou ? "\(member.name) (you)" : member.name)
                actionPopUp.lastItem?.representedObject = member.email
            }
        } else {
            actionPopUp.removeAllItems()
            actionPopUp.addItem(withTitle: "Couldn't load people")
            actionPopUp.isEnabled = false
        }
        projectPopUp.selectItem(at: 0)
        actionPopUp.selectItem(at: 0)
    }

    /// The organisation changed, so both menus are about somewhere else now.
    func forgetLists() {
        resetLists()
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

    // MARK: - The running timer

    /// `nil` means "nothing running", which is also what "no answer yet"
    /// renders as — the caller can tell them apart and only one of the two
    /// should be allowed to clear a live indicator.
    ///
    /// The elapsed time is worked out here from the start time rather than
    /// shown as the server sent it: `elapsed=25m` is correct when it is
    /// written and wrong a minute later, and this line is redrawn every time
    /// the popover opens.
    func showTiming(_ timer: MCPClient.RunningTimer?) {
        guard let timer = timer else {
            timerSection.isHidden = true
            return
        }
        timerSection.isHidden = false
        // Whatever a Stop in flight left it as: the control's state belongs
        // to what is on screen rather than to the order two callbacks
        // happened to arrive in.
        timerStop.isEnabled = true
        let elapsed = timer.startedAt.map { Self.elapsed(since: $0) } ?? timer.elapsed
        timerHeading.stringValue = elapsed.isEmpty ? "Timing" : "Timing — \(elapsed)"
        timerRow.title = timer.title
    }

    /// `"25m"`, `"1h 30m"` — the same shape the server's own
    /// `format_duration` writes, so the two never disagree about how long
    /// something has been going.
    static func elapsed(since start: Date) -> String {
        let minutes = max(0, Int(Date().timeIntervalSince(start)) / 60)
        let (hours, rest) = (minutes / 60, minutes % 60)
        if hours > 0 && rest > 0 { return "\(hours)h \(rest)m" }
        if hours > 0 { return "\(hours)h" }
        return "\(minutes)m"
    }

    // MARK: - Actions

    @objc private func pickOrganisation() {
        onPickOrganisation?(orgButton)
    }

    @objc private func openCreated() {
        if let destination = createdDestination { onOpen?(destination) }
    }

    @objc private func openCritical(_ sender: NSButton) {
        if let id = sender.identifier?.rawValue { onOpen?(.task(id)) }
    }

    @objc private func openTimed() {
        onOpen?(.timedTask)
    }

    @objc private func stopTimer() {
        // Disabled straight away, before the call: the answer takes a moment
        // to come back and a Stop button that still looks clickable invites
        // the second click that makes it look broken.
        timerStop.isEnabled = false
        onStopTimer?()
    }

    /// Put Stop back, whatever the call did. Failing and staying disabled
    /// would leave the one control that fixes a forgotten timer dead.
    func timerStopFinished() {
        timerStop.isEnabled = true
    }

    @objc private func toggleDetails() {
        details.isHidden.toggle()
        Settings.detailsExpanded = !details.isHidden
        updateDetailsToggle()
        onResize?()
        if !details.isHidden && needsLists { onNeedsLists?() }
    }

    private func updateDetailsToggle() {
        let open = !details.isHidden
        detailsToggle.title = "Details"
        detailsToggle.image = NSImage(
            systemSymbolName: open ? "chevron.down" : "chevron.right",
            accessibilityDescription: nil)
    }

    /// Whether the panel is showing — the caller needs it to decide whether
    /// fetching the two menus on open is work worth doing.
    var detailsAreVisible: Bool { !details.isHidden }

    /// ⌘⏎ creates from anywhere in the box.
    ///
    /// Return alone belongs to whichever field has the cursor, and in the
    /// description that has to mean a new paragraph. Which leaves somebody
    /// who has just finished typing one with no way to submit at all — this
    /// popover has no Create button to reach for — short of tabbing back to
    /// the title. ⌘⏎ is the same key those forms have always used.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else {
            return super.performKeyEquivalent(with: event)
        }
        switch event.charactersIgnoringModifiers {
        case "\r":
            submit()
            return true
        // The same key the web app binds for spark capture, doing the
        // nearest thing it can here: the box is already open, so ⌘J is what
        // turns it into the spark one — and back, since a keystroke that
        // only goes one way is a keystroke you have to undo with a mouse.
        case "j" where modePicker.isEnabled:
            setSparkMode(!isSparkMode)
            modeChanged()
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
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

    /// The description box, which needs different answers to the same two
    /// keys: Return is a new paragraph here, not a submit, and Tab moves on
    /// rather than indenting — nobody reaches for Tab in a three-line
    /// description meaning "insert a tab character", and the next control is
    /// what they are after.
    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)):
            onEscape?()
            return true
        case #selector(NSResponder.insertTab(_:)):
            window?.selectNextKeyView(nil)
            return true
        case #selector(NSResponder.insertBacktab(_:)):
            window?.selectPreviousKeyView(nil)
            return true
        default:
            return false
        }
    }

    /// What is currently in the box, as the server's arguments.
    ///
    /// The "not set" item of every menu is index 0 and carries no
    /// `representedObject`, so "nothing chosen" and "chosen" need no separate
    /// flag — an unset menu simply contributes nothing to the draft.
    private var draft: MCPClient.Draft {
        let priority = priorityPopUp.selectedItem?.representedObject as? String
        return MCPClient.Draft(
            title: field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            description: descriptionView.string.trimmingCharacters(in: .whitespacesAndNewlines),
            projectID: projectPopUp.selectedItem?.representedObject as? String,
            // The server's own default. Sending it explicitly would work, and
            // would also mean this app has an opinion about what the default
            // priority is — which is the server's to change.
            priority: priority == "normal" ? nil : priority,
            actionRequiredEmail: actionPopUp.selectedItem?.representedObject as? String,
            plannerBucket: plannerPopUp.selectedItem?.representedObject as? String,
            // Not a field on the task — the timer is a second call, made once
            // the task has an id to start it against. It rides along in the
            // draft because it is one of the answers this box collected.
            startTimer: timerCheck.state == .on)
    }

    private func submit() {
        let spark = isSparkMode
        let typed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { return }
        guard spark ? Settings.isConnected : Settings.isConfigured else {
            onOpenSettings?()
            return
        }
        let draft = self.draft
        field.isEnabled = false
        // Along with the field, and for the same reason: the mode decides
        // what this call is, and changing it while the call is in flight
        // would leave the box describing something other than what it just
        // filed.
        modePicker.isEnabled = false
        spinner.startAnimation(nil)
        statusLabel.stringValue = spark ? "Capturing…" : "Creating…"
        Task { @MainActor in
            if spark {
                await onSubmitSpark?(typed)
            } else {
                await onSubmit?(draft)
            }
            spinner.stopAnimation(nil)
            field.isEnabled = true
            modePicker.isEnabled = Settings.isConnected
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
    /// **Open appears only when there is somewhere to go.** A task's id is
    /// parsed out of the server's prose answer, so if that ever changes
    /// shape the button disappears rather than opening the web app at a URL
    /// with a hole in it. A spark's destination is the Sparks screen, which
    /// needs nothing parsed and so is always there.
    func confirm(title: String, opens: Destination?) {
        field.isHidden = true
        confirmation.isHidden = false
        confirmationLabel.stringValue = title
        createdDestination = opens
        openButton.isHidden = opens == nil
        statusLabel.stringValue = isSparkMode ? "Captured" : "Created"
        statusLabel.textColor = .systemGreen
        // The panel goes away with it. It is a form that has been submitted,
        // and leaving four filled-in menus under a green tick invites the
        // reading that they still apply to something.
        if !details.isHidden {
            details.isHidden = true
            updateDetailsToggle()
            onResize?()
        }
        detailsToggle.isHidden = true
    }

    /// Put the box back the way it was. Called from `refresh()`, i.e. when
    /// the popover reopens, rather than on a timer of its own — so the
    /// confirmation stays up for exactly as long as the popover does, and
    /// no caller has to remember to undo it.
    private func clearConfirmation() {
        field.isHidden = false
        confirmation.isHidden = true
        createdDestination = nil
        // `applyMode` puts the disclosure and the panel back, which in spark
        // mode means leaving both away.
        applyMode()
    }
}
