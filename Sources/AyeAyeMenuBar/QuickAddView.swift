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
    /// The instance itself, as a globe beside the organisation name.
    ///
    /// This box otherwise only links to things that have *happened* — the
    /// task you just filed, a critical one, the one being timed — and there
    /// was no way to simply go and look at the installation the app is
    /// pointed at. An icon rather than words because the address is already
    /// spelled out in the tooltip and in Settings, and the footer is the
    /// one row here that has to stay quiet.
    private let instanceButton = NSButton()
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
    /// The Planner tab's whole content: a heading per bucket and a row per
    /// task, built fresh each time an answer arrives.
    ///
    /// It takes the text field's place rather than sitting under it — this
    /// is the one mode that files nothing, so leaving an empty box above a
    /// list would be inviting a Return that has nowhere to go.
    private let plannerSection = NSStackView()
    /// The Notifications tab's whole content, built the same way and in the
    /// same place as the planner's — one row per unread notification, and a
    /// Mark all read under them.
    ///
    /// **The one list here that is not about the selected organisation.** A
    /// notification is addressed to a person, so this is every organisation
    /// at once, which is also what the badge counts. The footer says so
    /// rather than the tab having an organisation button that would be a
    /// lie about what it filters.
    private let notificationsSection = NSStackView()
    private let notificationsList = NSStackView()
    private let markAllButton = NSButton()

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
        /// The installation's own front page — `Settings.baseURL` and
        /// nothing after it.
        case instance
        /// Wherever a notification says its subject is, as the path the
        /// server stored with it — `/orgs/…/tasks/…`. **Not `.task`**, even
        /// though most of them are tasks: the notification already carries a
        /// route, and rebuilding one from the selected organisation would
        /// open the wrong page for a notification raised somewhere else.
        case link(String)
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
    /// The Planner tab is showing and wants today's and tomorrow's work.
    var onNeedsPlanner: (() -> Void)?
    /// The Notifications tab is showing and wants the unread ones.
    var onNeedsNotifications: (() -> Void)?
    /// One notification's tick was clicked — mark it read.
    var onCloseNotification: ((String) -> Void)?
    /// Mark all read was clicked.
    var onCloseAllNotifications: (() -> Void)?
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
        modePicker.segmentCount = 4
        modePicker.setLabel("Task", forSegment: 0)
        modePicker.setLabel("Spark", forSegment: 1)
        // The last two are not further kinds of thing to file — they are the
        // tabs that read rather than write. They sit in the same control
        // anyway because they are the same question answered a different way
        // ("what am I doing?", "what happened?"), and a separate control for
        // two buttons would be a second row of chrome above a box whose whole
        // argument is that it is small.
        modePicker.setLabel("Planner", forSegment: 2)
        // The badge on the icon is what sends anybody here, so the tab is
        // named after the thing the badge counts rather than after the bell
        // or an inbox — three words for the same idea in one app is two too
        // many.
        modePicker.setLabel("Notifications", forSegment: 3)
        modePicker.trackingMode = .selectOne
        modePicker.controlSize = .small
        modePicker.font = .systemFont(ofSize: 11)
        modePicker.selectedSegment = Settings.capturesSparks ? 1 : 0
        modePicker.target = self
        modePicker.action = #selector(modeChanged)
        modePicker.toolTip =
            "What ⏎ files: a task, or a spark only you ever see (⌘J) — "
            + "or today's and tomorrow's planner, or what you haven't read"
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

        // Borderless and secondary, like the organisation button next to it:
        // it is a way out of the box, not one of the two things the box is
        // for, and a bordered button here would read as a third action
        // competing with Return.
        instanceButton.bezelStyle = .inline
        instanceButton.isBordered = false
        instanceButton.image = NSImage(
            systemSymbolName: "globe", accessibilityDescription: "Open in the browser")
        instanceButton.symbolConfiguration = .init(pointSize: 11, weight: .regular)
        instanceButton.contentTintColor = .secondaryLabelColor
        instanceButton.imagePosition = .imageOnly
        instanceButton.target = self
        instanceButton.action = #selector(openInstance)
        instanceButton.setContentHuggingPriority(.required, for: .horizontal)

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
        let footer = NSStackView(
            views: [orgButton, instanceButton, sparkNote, spinner, statusLabel])
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

        // No heading of its own and no separator: the tab *is* the heading,
        // and this is the whole body of the box while it is showing rather
        // than a footnote under something else.
        plannerSection.orientation = .vertical
        plannerSection.spacing = 8
        plannerSection.alignment = .leading
        plannerSection.isHidden = true

        // Built like the planner's, and for the same reasons — no heading of
        // its own, because the tab is the heading, and the whole body of the
        // box while it is showing.
        notificationsList.orientation = .vertical
        notificationsList.spacing = 6
        notificationsList.alignment = .leading
        // Not a destructive-looking button and not a prominent one: it is the
        // tidying-up gesture at the bottom of a list, and the rows above are
        // what somebody came here to read.
        markAllButton.title = "Mark all read"
        markAllButton.bezelStyle = .rounded
        markAllButton.controlSize = .small
        markAllButton.font = .systemFont(ofSize: 11)
        markAllButton.target = self
        markAllButton.action = #selector(closeAllNotifications)
        markAllButton.isHidden = true
        markAllButton.toolTip = "Mark every notification read, in every organisation"
        notificationsSection.setViews([notificationsList, markAllButton], in: .leading)
        notificationsSection.orientation = .vertical
        notificationsSection.spacing = 8
        notificationsSection.alignment = .leading
        notificationsSection.isHidden = true

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
                modePicker, field, confirmation, plannerSection, notificationsSection,
                detailsToggle, details, footer, criticalSection, timerSection,
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
            plannerSection.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            notificationsSection.widthAnchor.constraint(
                equalTo: stack.widthAnchor, constant: -24),
            notificationsList.widthAnchor.constraint(equalTo: notificationsSection.widthAnchor),
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
        // The box opens ready to type, never onto the list it was last
        // showing — see `isReadingMode` for why those two aren't remembered.
        if isReadingMode { modePicker.selectedSegment = Settings.capturesSparks ? 1 : 0 }
        clearConfirmation()
        orgButton.title = Settings.isConfigured
            ? (Settings.organisationName ?? "Unknown organisation")
            : "Not set up"
        orgButton.isEnabled = Settings.isConfigured
        // Gone rather than disabled when there is no address yet: the footer
        // already says "Not set up", and a globe that opens nothing is a
        // second, worse answer to the same question.
        if let base = Settings.baseURL, let url = MCPClient.homeURL(base: base) {
            instanceButton.isHidden = false
            instanceButton.toolTip = "Open \(url.host ?? url.absoluteString) in the browser"
        } else {
            instanceButton.isHidden = true
            instanceButton.toolTip = nil
        }
        field.stringValue = ""
        clearDetails()
        applyMode()
        window?.makeFirstResponder(field)
    }

    // MARK: - Which of the two things this box files

    var isSparkMode: Bool { modePicker.selectedSegment == 1 }

    /// The read-only tab. Not a capture mode, and deliberately not
    /// remembered the way Task and Spark are: `Settings.capturesSparks` is
    /// the answer to "what does Return file", and a box that opened onto a
    /// list because you last looked at one would have quietly stopped being
    /// a keystroke, a sentence and Return. `refresh` puts it back.
    var isPlannerMode: Bool { modePicker.selectedSegment == 2 }

    /// The other read-only tab: what you haven't read, across every
    /// organisation. Not remembered either, for the identical reason.
    var isNotificationsMode: Bool { modePicker.selectedSegment == 3 }

    /// Either of the two that read rather than file. Nearly everything the
    /// box does differently in one of them it does in both — no text field,
    /// no Details, nothing for Return to do — so the difference worth naming
    /// is reading versus filing, and the two tabs differ only in what they
    /// then put on screen.
    var isReadingMode: Bool { isPlannerMode || isNotificationsMode }

    /// Set from outside — the right-click menu offers both by name, and
    /// picking one there has to arrive here before the box is shown.
    func setSparkMode(_ on: Bool) {
        modePicker.selectedSegment = on ? 1 : 0
        Settings.capturesSparks = on
        applyMode()
    }

    /// Show the Planner tab, from outside — the right-click menu offers it by
    /// name alongside the two capture modes.
    func setPlannerMode() {
        modePicker.selectedSegment = 2
        applyMode()
        onNeedsPlanner?()
    }

    /// Show the Notifications tab, from outside — the right-click menu
    /// offers it by name, and the badge on the icon is a thing you click.
    func setNotificationsMode() {
        modePicker.selectedSegment = 3
        applyMode()
        onNeedsNotifications?()
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
        let planner = isPlannerMode
        let inbox = isNotificationsMode
        let reading = planner || inbox
        // A spark needs no organisation, so the bar for it is lower — the
        // server's own record has no organisation_id at all, and somebody
        // who has been invited nowhere yet can still capture one.
        let ready = spark ? Settings.isConnected : Settings.isConfigured
        let confirming = !confirmation.isHidden && !reading

        field.placeholderString = spark ? "New spark…" : "New task…"
        field.isEnabled = ready
        // The field and the confirmation both go: a reading tab replaces
        // the whole writing half of the box rather than sitting under it.
        field.isHidden = reading
        confirmation.isHidden = !confirming
        plannerSection.isHidden = !planner
        notificationsSection.isHidden = !inbox
        modePicker.isEnabled = Settings.isConnected
        // The organisation still names where this list comes from — a planner
        // is read one organisation at a time, same as everything else here —
        // so the button stays, and switching from it reloads the tab.
        //
        // **Except on the inbox**, which is the one list here that is not
        // about an organisation at all: notifications are addressed to a
        // person, so an organisation name over this list would be a filter
        // that isn't being applied. The spark note's own row says so instead.
        orgButton.isHidden = spark || inbox
        sparkNote.isHidden = !spark || planner
        detailsToggle.isHidden = spark || reading || confirming
        detailsToggle.isEnabled = Settings.isConfigured
        details.isHidden = spark || reading || confirming || !Settings.detailsExpanded
        updateDetailsToggle()
        // Not while the confirmation is up: that owns this line, in green,
        // and it has to outlive anything else touching the box.
        guard !confirming else { return }
        if reading {
            // Whatever the tab last said about itself — "Loading…", a count,
            // or why there is nothing to show. Set by `showPlanner` and
            // `showNotifications`, and left alone here so switching away and
            // back doesn't blank it.
            let failed = planner ? plannerFailed : inboxFailed
            statusLabel.textColor = failed ? .systemRed : .secondaryLabelColor
            statusLabel.stringValue = planner ? plannerStatus : inboxStatus
            return
        }
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
        // Only the two capture modes are remembered — see `isReadingMode`.
        if !isReadingMode { Settings.capturesSparks = isSparkMode }
        if isReadingMode {
            // A green tick about the task you just filed is about the writing
            // half of the box, and the writing half has just gone away.
            createdDestination = nil
            confirmation.isHidden = true
            if isPlannerMode {
                plannerStatus = "Loading…"
                plannerFailed = false
            } else {
                inboxStatus = "Loading…"
                inboxFailed = false
            }
        }
        applyMode()
        onResize?()
        // Nothing to type into on a reading tab, and handing first responder
        // to a hidden field is how a popover stops answering Escape.
        window?.makeFirstResponder(isReadingMode ? self : field)
        if isPlannerMode { onNeedsPlanner?() }
        if isNotificationsMode { onNeedsNotifications?() }
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
            let row = NSButton(title: task.title, target: self, action: #selector(openTaskRow(_:)))
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

    // MARK: - The planner

    /// What the footer says while the Planner tab is up. Kept here rather
    /// than read back off the label so switching tabs and back doesn't have
    /// to re-ask the server to know what to write.
    private var plannerStatus = "Loading…"
    private var plannerFailed = false

    /// The two buckets this tab shows, in the server's own order.
    ///
    /// Today and Tomorrow and no further, which is the whole of the feature
    /// as asked for and is also the honest limit of a menu bar popover: This
    /// week, Next week and Someday are a board to arrange, not a list to
    /// glance at, and the web app is where you drag things between them.
    private static let plannerBuckets: [(String, String)] = [
        ("today", "Today"),
        ("tomorrow", "Tomorrow"),
    ]

    /// The buckets to ask the server for — the same two, as the tool spells
    /// them.
    static var plannerBucketNames: [String] { plannerBuckets.map { $0.0 } }

    /// `nil` means the ask failed, and `reason` says why. An empty array is
    /// the other answer entirely: nothing is planned, which is a fact about
    /// your week rather than about the network.
    func showPlanner(_ buckets: [MCPClient.PlannerBucket]?, reason: String? = nil) {
        plannerSection.setViews([], in: .leading)
        guard let buckets = buckets else {
            plannerFailed = true
            // The tool is newer than the rest of this app's reads, so the
            // likeliest failure here is an installation that simply doesn't
            // have it — and the server's own refusal names it, which is more
            // use than anything this app could guess.
            plannerStatus = reason ?? "Couldn't load your planner"
            plannerSection.addView(
                Self.quietNote("Nothing to show — the server couldn't be asked."),
                in: .leading)
            if isPlannerMode { applyMode() }
            onResize?()
            return
        }
        plannerFailed = false
        let total = buckets.reduce(0) { $0 + $1.tasks.count }
        plannerStatus = total == 1 ? "1 task planned" : "\(total) tasks planned"
        if buckets.isEmpty {
            plannerStatus = "Nothing planned"
            plannerSection.addView(
                Self.quietNote("Nothing in Today or Tomorrow."), in: .leading)
        }
        for (name, label) in Self.plannerBuckets {
            guard let bucket = buckets.first(where: { $0.name == name }) else { continue }
            let heading = NSTextField(labelWithString: "\(label) (\(bucket.tasks.count))")
            heading.font = .systemFont(ofSize: 11, weight: .medium)
            heading.textColor = .secondaryLabelColor
            let rows = NSStackView(views: [heading])
            rows.orientation = .vertical
            rows.spacing = 2
            rows.alignment = .leading
            // Six a bucket, then a count — the same bargain the critical list
            // makes, and for the same reason: a popover that grows with your
            // workload is one that stops fitting on the screen on the day you
            // most need to read it.
            for task in bucket.tasks.prefix(6) {
                rows.addView(Self.plannerRow(task, target: self, action: #selector(openTaskRow(_:))), in: .leading)
            }
            if bucket.tasks.count > 6 {
                rows.addView(
                    Self.quietNote("and \(bucket.tasks.count - 6) more"), in: .leading)
            }
            plannerSection.addView(rows, in: .leading)
        }
        if isPlannerMode { applyMode() }
        onResize?()
    }

    /// A task in a bucket: the same borderless row the critical list uses,
    /// opening the same way, because they are the same gesture on the same
    /// kind of thing and two styles for that would be two things to learn.
    private static func plannerRow(
        _ task: MCPClient.TaskSummary, target: AnyObject, action: Selector
    ) -> NSButton {
        let row = NSButton(title: task.title, target: target, action: action)
        row.bezelStyle = .inline
        row.isBordered = false
        row.font = .systemFont(ofSize: 12)
        row.alignment = .left
        row.contentTintColor = .labelColor
        row.identifier = NSUserInterfaceItemIdentifier(task.id)
        row.lineBreakMode = .byTruncatingTail
        return row
    }

    /// The small grey line a list uses to say something that isn't a row —
    /// "and four more", why it is empty, what kind a notification is. Shared
    /// by both reading tabs, which is why it is not named after either.
    private static func quietNote(_ text: String) -> NSTextField {
        let note = NSTextField(labelWithString: text)
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        return note
    }

    // MARK: - The inbox

    /// What the footer says while the Notifications tab is up, kept here for
    /// the same reason the planner's is: switching tabs and back must not
    /// have to re-ask the server what to write.
    private var inboxStatus = "Loading…"
    private var inboxFailed = false

    /// How many rows a popover can honestly show.
    ///
    /// The same bargain the critical list and the planner's buckets make. It
    /// is a lower number here because a notification is two lines rather than
    /// one, and because an inbox is the list most likely to have forty things
    /// in it — the count in the footer is the honest total, and Mark all read
    /// is right there for the case this limit exists to describe.
    private static let inboxLimit = 8

    /// The link path of each row on screen, by notification id. Rebuilt with
    /// the list, because the rows themselves can only carry one string each
    /// and the id is the one both buttons need.
    private var shownNotifications: [String: String?] = [:]

    /// `nil` means the ask failed and `reason` says why; an empty list is the
    /// other answer entirely — you have read everything, which is a fact
    /// about your week rather than about the network.
    ///
    /// `unread` is the server's own count rather than `items.count`: the tool
    /// answers with the total on its first line, so a person with forty
    /// unread sees eight rows and the true number under them.
    func showNotifications(
        _ items: [MCPClient.Notification]?, unread: Int = 0, reason: String? = nil
    ) {
        notificationsList.setViews([], in: .leading)
        shownNotifications = [:]
        guard let items = items else {
            inboxFailed = true
            // The likeliest failure is an installation older than the
            // `notifications` tool, and the server's own refusal names it —
            // which is more use than anything this app could guess.
            inboxStatus = reason ?? "Couldn't read your notifications"
            markAllButton.isHidden = true
            notificationsList.addView(
                Self.quietNote("Nothing to show — the server couldn't be asked."),
                in: .leading)
            if isNotificationsMode { applyMode() }
            onResize?()
            return
        }
        inboxFailed = false
        inboxStatus = unread == 1 ? "1 unread" : "\(unread) unread"
        if items.isEmpty {
            inboxStatus = "Nothing unread"
            markAllButton.isHidden = true
            // Named for what it is rather than "Nothing to show": an empty
            // inbox is the good outcome, and this is the one list in the app
            // whose emptiness is worth sounding pleased about.
            notificationsList.addView(
                Self.quietNote("You have read everything."), in: .leading)
            if isNotificationsMode { applyMode() }
            onResize?()
            return
        }
        for item in items.prefix(Self.inboxLimit) {
            let row = notificationRow(item)
            notificationsList.addView(row, in: .leading)
            // After it is in the list, not before: an anchor pinned to a view
            // the row is not yet inside has no common ancestor to resolve
            // against, and AppKit throws rather than ignoring it.
            row.widthAnchor.constraint(equalTo: notificationsList.widthAnchor).isActive = true
        }
        if items.count > Self.inboxLimit {
            notificationsList.addView(
                Self.quietNote("and \(items.count - Self.inboxLimit) more"), in: .leading)
        }
        markAllButton.isHidden = false
        if isNotificationsMode { applyMode() }
        onResize?()
    }

    /// One notification: what it says, what kind it is and how old, and the
    /// tick that puts it down.
    ///
    /// Two lines rather than one. A task row elsewhere in this box is a title
    /// and nothing else because the tab it is on already says what the list
    /// is — these are thirteen different kinds of thing in one list, and
    /// "Ada closed it" and "Ada shared it with you" are the same sentence
    /// until something says which.
    private func notificationRow(_ item: MCPClient.Notification) -> NSView {
        // Where this one goes, against its id — the row buttons carry ids,
        // like every other row in this box, and a click needs the link too.
        shownNotifications[item.id] = item.linkPath
        // **Nothing to open is not a broken link.** A couple of kinds are
        // about something that has no page — a finished export, a daily
        // digest — and those rows are a label rather than a disabled button:
        // a dimmed row reads as "less important", which is the one thing it
        // does not mean.
        let title: NSControl
        if let link = item.linkPath, !link.isEmpty {
            let button = NSButton(
                title: item.title, target: self, action: #selector(openNotification(_:)))
            button.bezelStyle = .inline
            button.isBordered = false
            button.alignment = .left
            button.contentTintColor = .labelColor
            button.identifier = NSUserInterfaceItemIdentifier(item.id)
            button.lineBreakMode = .byTruncatingTail
            title = button
        } else {
            let label = NSTextField(labelWithString: item.title)
            label.lineBreakMode = .byTruncatingTail
            title = label
        }
        title.font = .systemFont(ofSize: 12)
        // The title, not a hint about clicking: these are sentences, this row
        // truncates them, and the tooltip is where the rest of one lives.
        title.toolTip = item.title
        // The row takes the slack so the tick sits against the right edge —
        // the same trick the timer's heading row uses, and the reason there
        // is no spacer view in either.
        title.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        // **And it is allowed to be squeezed.** A notification's title is a
        // sentence the server wrote — "Ada Lovelace needs you on “Ring the
        // foundry”" — not a task's few words, and a row that insisted on its
        // full width would make the popover as wide as the longest thing in
        // somebody's inbox. `fittingSize` is what the popover is sized from,
        // so the limit has to be a constraint rather than a preference.
        //
        // A *ceiling*, not the 320pt floor: this box has always grown to fit
        // a long project name or a critical task's title, and clamping these
        // rows to the narrowest the popover ever gets would cut every one of
        // them off before the part that says which task it is about. 420 is
        // about ten more words and still a popover rather than a window; past
        // it the title truncates and the tooltip has the rest.
        //
        // Compression resistance is left alone on purpose. Lowering it — the
        // obvious way to let a long row shrink — makes `fittingSize` settle
        // on the *narrowest* width that satisfies everything, which is the
        // 320pt floor, and every row then truncates whether it needed to or
        // not. The required ceiling below does the shrinking instead, and
        // ordinary resistance is what asks for the width up to it.
        title.widthAnchor.constraint(lessThanOrEqualToConstant: 420 - 24 - 6 - 22).isActive = true

        // A tick, because this marks read rather than deletes: nothing is
        // thrown away, and the notification is still in the web app's inbox
        // afterwards. A bin here would promise something this button
        // deliberately doesn't do.
        let close = NSButton(
            image: NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Mark read")
                ?? NSImage(), target: self, action: #selector(closeNotification(_:)))
        close.bezelStyle = .inline
        close.isBordered = false
        close.contentTintColor = .secondaryLabelColor
        close.identifier = NSUserInterfaceItemIdentifier(item.id)
        close.toolTip = "Mark read"
        close.setContentHuggingPriority(.required, for: .horizontal)

        let top = NSStackView(views: [title, close])
        top.orientation = .horizontal
        top.spacing = 6

        var caption = MCPClient.label(forKind: item.kind)
        if let at = item.createdAt { caption += " · " + MCPClient.age(since: at) }
        let row = NSStackView(views: [top, Self.quietNote(caption)])
        row.orientation = .vertical
        row.spacing = 1
        row.alignment = .leading
        // The heading row has to be as wide as the whole row, or the tick
        // ends up beside the title rather than at the edge of the popover.
        // The row's own width is pinned by the caller, once it is in the list.
        top.widthAnchor.constraint(equalTo: row.widthAnchor).isActive = true
        return row
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

    @objc private func openInstance() {
        onOpen?(.instance)
    }

    @objc private func openCreated() {
        if let destination = createdDestination { onOpen?(destination) }
    }

    /// Every task row in this view — the critical list and the planner's
    /// buckets — carries its id in `identifier` and opens the same way.
    @objc private func openTaskRow(_ sender: NSButton) {
        if let id = sender.identifier?.rawValue { onOpen?(.task(id)) }
    }

    /// A notification's own row. It opens where the server said, and marks
    /// itself read on the way — the same thing the web app's inbox does when
    /// you click one, and for the same reason: a notification you have acted
    /// on is not one you still need telling about.
    @objc private func openNotification(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue,
              let path = shownNotifications[id] ?? nil
        else { return }
        // Read first, then away: the popover closes on an open, and a call
        // made after it has gone is one whose failure has nowhere to be
        // reported. Both are fire-and-forget from here either way — the
        // caller reloads the badge from the server rather than from this.
        onCloseNotification?(id)
        onOpen?(.link(path))
    }

    @objc private func closeNotification(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        // Disabled rather than removed: the row goes when the reload says it
        // has gone, not when it was clicked. A list that tidied itself up
        // optimistically would quietly disagree with the badge the moment a
        // call failed — and the badge is the reason anybody opened this tab.
        sender.isEnabled = false
        onCloseNotification?(id)
    }

    @objc private func closeAllNotifications() {
        markAllButton.isEnabled = false
        onCloseAllNotifications?()
    }

    /// Put the button back, whatever the call did — the same rule the
    /// timer's Stop follows. Failing and staying disabled would leave the
    /// one control that empties the list dead until the box is reopened.
    func markAllFinished() {
        markAllButton.isEnabled = true
    }

    /// Why a tick didn't work, in the line the tab already owns.
    ///
    /// Not `report`: that writes the status line directly, and the next
    /// reload of this list — which a failed tick asks for, because the row it
    /// was clicked on is now of unknown state — would paint the count back
    /// over it a moment later. This is kept as the tab's own status, so it
    /// survives exactly as long as the list it is about.
    func reportInbox(_ message: String) {
        inboxStatus = message
        inboxFailed = true
        if isNotificationsMode { applyMode() }
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
    /// So the Planner tab has somewhere to put first responder. Every other
    /// mode hands it to the text field, which answers Escape itself through
    /// `control(_:textView:doCommandBy:)`; a tab with no field would
    /// otherwise leave the key nowhere to land.
    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        // 53 is Escape. Matched by key code rather than by character because
        // it has no sensible character, and every layout agrees about it.
        if event.keyCode == 53 {
            onEscape?()
            return
        }
        super.keyDown(with: event)
    }

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
