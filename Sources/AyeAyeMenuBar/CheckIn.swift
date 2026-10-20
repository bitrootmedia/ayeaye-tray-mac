import AppKit

/// "Still working on this?" — the server's question, shown here.
///
/// **The server asks, not this app.** While a timer runs, ayeaye asks every
/// hour or two at random whether you are still on it, and pauses the timer if
/// nobody answers within fifteen to thirty minutes — in Telegram, in the web
/// app's header, and here. It has to be the server: a question only this app
/// could ask would only reach people running this app, and the timer still
/// going at midnight belongs to somebody who isn't. See ayeaye's
/// `services/check_ins.py`; whether and how often is on the Account screen.
///
/// So this only presents. `running_timer` carries `check_in_deadline=` while
/// a question is open, and every refresh of the timer comes through `track`:
/// a deadline appearing raises the panel, and disappearing takes it down —
/// answered here, in Telegram or on the web, it doesn't matter where, since
/// there is one question and the first answer wins. Disappearing *with the
/// timer* at or past the deadline means nobody answered and the server
/// paused it, which the panel then says, with Resume.
final class CheckIn {
    /// Yes (`true`) or stop. A non-nil result is a problem to show.
    var onAnswer: ((_ stillWorking: Bool) async -> String?)?
    /// Start the paused task's timer again.
    var onResume: ((_ timer: MCPClient.RunningTimer) async -> String?)?

    /// What the panel is asking about, while it asks.
    private var asking: MCPClient.RunningTimer?
    /// What it last said was paused, for Resume.
    private var paused: MCPClient.RunningTimer?
    private lazy var panel = CheckInPanel()

    init() {
        panel.onYes = { [weak self] in self?.answer(true) }
        panel.onStop = { [weak self] in self?.answer(false) }
        panel.onResume = { [weak self] in self?.resume() }
        panel.onDismiss = { [weak self] in
            self?.paused = nil
            self?.panel.close()
        }
    }

    /// Every answer to "what is running", nil for nothing. Never a failed
    /// ask — "couldn't reach the server" says nothing about the question.
    func track(_ running: MCPClient.RunningTimer?) {
        if let running = running, let deadline = running.checkInDeadline {
            // Already showing this one: leave it, sound and all.
            if asking?.taskID == running.taskID && asking?.checkInDeadline == deadline { return }
            asking = running
            paused = nil
            panel.ask(about: running, deadline: deadline)
            NSSound(named: "Glass")?.play()
            return
        }
        guard let was = asking else {
            // A paused panel stays up until read — unless a timer is running
            // again, in which case it is old news.
            if running != nil && paused != nil {
                paused = nil
                panel.close()
            }
            return
        }
        asking = nil
        // Gone with the timer, at or past the deadline: the server paused it.
        // A minute's slack for two clocks that don't quite agree. Anything
        // else — answered somewhere, or stopped — just takes the panel down.
        if running == nil, let deadline = was.checkInDeadline,
           Date() >= deadline.addingTimeInterval(-60) {
            paused = was
            panel.paused(was)
        } else {
            panel.close()
        }
    }

    private func answer(_ stillWorking: Bool) {
        Task { @MainActor in
            if let problem = await onAnswer?(stillWorking) {
                panel.report(problem)
                return
            }
            // Down now rather than on the refresh that follows, which would
            // otherwise read a stop as "paused" if it landed past the deadline.
            asking = nil
            panel.close()
        }
    }

    private func resume() {
        guard let timer = paused else {
            panel.close()
            return
        }
        Task { @MainActor in
            if let problem = await onResume?(timer) {
                panel.report(problem)
                return
            }
            paused = nil
            panel.close()
        }
    }
}

/// The question itself, and afterwards what became of it.
///
/// A floating panel in the top-right corner, where notifications appear —
/// not a modal, which would take the keyboard from whatever you were typing,
/// and not a notification, whose buttons hide behind a hover and which can
/// be swept away unread. **Non-activating**, so clicking it doesn't pull
/// focus from the app you are working in either. On every Space, and over
/// full-screen apps, because a question you can't see is one you can't
/// answer — and here, not answering costs you the timer.
final class CheckInPanel: NSPanel {
    var onYes: (() -> Void)?
    var onStop: (() -> Void)?
    var onResume: (() -> Void)?
    var onDismiss: (() -> Void)?

    private let heading = NSTextField(labelWithString: "")
    private let taskLabel = NSTextField(labelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let primary = NSButton()
    private let secondary = NSButton()
    private var isPaused = false

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 120),
            styleMask: [.titled, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered, defer: true)
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovableByWindowBackground = true
        build()
    }

    private func build() {
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        taskLabel.font = .systemFont(ofSize: 12)
        taskLabel.lineBreakMode = .byTruncatingTail
        taskLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.preferredMaxLayoutWidth = 288

        for button in [primary, secondary] {
            button.bezelStyle = .rounded
            button.target = self
        }
        primary.action = #selector(primaryClicked)
        secondary.action = #selector(secondaryClicked)
        primary.keyEquivalent = "\r"

        let buttons = NSStackView(views: [NSView(), secondary, primary])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        let stack = NSStackView(views: [heading, taskLabel, detail, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 28, left: 16, bottom: 14, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        guard let content = contentView else { return }
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.widthAnchor.constraint(equalToConstant: 320),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            taskLabel.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor, constant: -32),
        ])
    }

    func ask(about timer: MCPClient.RunningTimer, deadline: Date) {
        isPaused = false
        heading.stringValue = "Still working on this?"
        taskLabel.stringValue = timer.title
        let elapsed = timer.startedAt.map { QuickAddView.elapsed(since: $0) } ?? timer.elapsed
        let by = DateFormatter.localizedString(from: deadline, dateStyle: .none, timeStyle: .short)
        detail.stringValue = (elapsed.isEmpty ? "" : "Timing for \(elapsed). ")
            + "No answer by \(by) pauses it."
        primary.title = "Yes, still on it"
        secondary.title = "Stop timer"
        primary.isEnabled = true
        secondary.isEnabled = true
        present()
    }

    func paused(_ timer: MCPClient.RunningTimer) {
        isPaused = true
        heading.stringValue = "Timer paused — nobody answered"
        taskLabel.stringValue = timer.title
        detail.stringValue = "It stopped when it asked, so the wait isn't counted as work."
        primary.title = "Resume"
        secondary.title = "Dismiss"
        primary.isEnabled = true
        secondary.isEnabled = true
        present()
    }

    /// Something went wrong; the buttons come back so it can be tried again.
    func report(_ problem: String) {
        detail.stringValue = problem
        primary.isEnabled = true
        secondary.isEnabled = true
        layoutAndPlace()
    }

    private func present() {
        layoutAndPlace()
        orderFrontRegardless()
    }

    private func layoutAndPlace() {
        guard let content = contentView else { return }
        content.layoutSubtreeIfNeeded()
        setContentSize(content.fittingSize)
        // Top right of the screen with the menu bar, under it — where a
        // notification banner would be, which is where the eye already goes.
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        setFrameTopLeftPoint(NSPoint(x: visible.maxX - frame.width - 12, y: visible.maxY - 12))
    }

    @objc private func primaryClicked() {
        primary.isEnabled = false
        secondary.isEnabled = false
        isPaused ? onResume?() : onYes?()
    }

    @objc private func secondaryClicked() {
        if isPaused {
            onDismiss?()
            return
        }
        primary.isEnabled = false
        secondary.isEnabled = false
        onStop?()
    }

    // A titled, non-activating panel still has to be allowed to take clicks
    // on its buttons without becoming the app's main window.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
