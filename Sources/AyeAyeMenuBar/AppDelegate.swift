import AppKit
import Carbon.HIToolbox

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let quickAdd = QuickAddView(frame: NSRect(x: 0, y: 0, width: 320, height: 84))
    private var settingsWindow: SettingsWindow?
    private var hotKeyRef: EventHotKeyRef?
    /// What the last poll found. Held so the popover can render instantly
    /// when it opens — asking the server first would mean a text box that
    /// arrives after the keystroke that asked for it.
    private var critical: [MCPClient.TaskSummary] = []
    private var criticalTimer: Timer?
    /// Unread notifications, for the badge. Held for the same reason
    /// `critical` is: the icon has to be right the moment it is drawn.
    private var unread = 0
    private var unreadTimer: Timer?
    /// What you are timing, if anything — for the pip on the icon and the
    /// row in the popover. Held for the third time for the third time's
    /// reason: the icon is drawn before anything can be asked.
    private var timing: MCPClient.RunningTimer?
    private var timingTimer: Timer?
    private let realtime = RealtimeClient()
    /// "Still working on this?" — see CheckIn.swift.
    private let checkIn = CheckIn()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Before any window or field exists: without it, ⌘V is dead app-wide.
        // See EditMenu.swift — this is not decoration, it is the paste key.
        EditMenu.install()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = AnchorIcon.image()
            button.imagePosition = .imageLeading
            button.action = #selector(statusItemClicked)
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        popover.behavior = .transient
        popover.contentSize = NSSize(width: 320, height: 84)
        let controller = NSViewController()
        controller.view = quickAdd
        popover.contentViewController = controller

        quickAdd.onEscape = { [weak self] in self?.popover.performClose(nil) }
        quickAdd.onOpenSettings = { [weak self] in self?.openSettings() }
        quickAdd.onSubmit = { [weak self] draft in await self?.create(draft) }
        quickAdd.onSubmitSpark = { [weak self] body in await self?.capture(body) }
        quickAdd.onPickOrganisation = { [weak self] anchor in self?.pickOrganisation(from: anchor) }
        quickAdd.onOpen = { [weak self] destination in
            guard let self = self else { return }
            switch destination {
            case let .task(id):
                self.openInWeb(taskID: id, organisationID: Settings.organisationID)
            case .timedTask:
                // The timer's own organisation, not the selected one. They
                // are usually the same and the whole point of the timer not
                // being org-scoped is the times they aren't — a link built
                // from the wrong one opens a page that says the task does
                // not exist.
                if let timing = self.timing {
                    self.openInWeb(
                        taskID: timing.taskID, organisationID: timing.organisationID)
                }
            case .sparks:
                self.openSparks()
            case .instance:
                self.openInstance()
            case let .link(path):
                self.openInWeb(path: path)
            }
        }
        quickAdd.onNeedsLists = { [weak self] in self?.loadLists() }
        quickAdd.onNeedsPlanner = { [weak self] in self?.loadPlanner() }
        quickAdd.onNeedsNotifications = { [weak self] in self?.loadNotifications() }
        quickAdd.onCloseNotification = { [weak self] id in self?.closeNotification(id) }
        quickAdd.onCloseAllNotifications = { [weak self] in self?.closeAllNotifications() }
        quickAdd.onResize = { [weak self] in self?.sizePopover() }
        quickAdd.onStopTimer = { [weak self] in self?.stopTiming() }

        registerHotKey()
        startCheckIns()
        startWatchingCritical()
        startWatchingUnread()
        startWatchingTimer()

        // The socket says *something moved*; what moved is refetched, the
        // same one-authorisation-path discipline the web app follows.
        realtime.onChange = { [weak self] in
            guard let self = self else { return }
            // The socket carries task events, not notification ones — but the
            // things that raise a notification for you (somebody asking you
            // to act, handing you a task) are task changes, so a nudge is a
            // good moment to recount. It is not a substitute for the timer:
            // a notification can arrive from a place this socket isn't
            // watching, since the badge counts every organisation and the
            // socket watches one.
            Task { await self.refreshCritical() }
            Task { await self.refreshUnread() }
            // Starting and stopping a timer announce themselves as task
            // changes on the server (time is task history), so a nudge is
            // exactly when to re-ask what is running. Not a substitute for
            // the timer below, for the same reason as the badge: one running
            // timer exists per person across every organisation, and this
            // socket watches one.
            Task { await self.refreshTiming() }
            // Only while somebody is looking at it. The planner is the one
            // thing here with no presence outside its own tab — no icon, no
            // badge — so refetching it when it isn't showing would be a call
            // whose answer nothing could display.
            if self.popover.isShown && self.quickAdd.isPlannerMode { self.loadPlanner() }
            // The same rule for the inbox, which does have a presence outside
            // its tab — the badge — but whose *list* nothing else can show.
            // `refreshUnread` above keeps the number right either way.
            if self.popover.isShown && self.quickAdd.isNotificationsMode {
                self.loadNotifications()
            }
        }
        // A slept-through laptop has a socket the OS killed and a backoff
        // timer minutes from firing. Waking is the moment to stop waiting.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            self.realtime.reconnectNow()
            Task { await self.refreshCritical() }
            Task { await self.refreshUnread() }
            Task { await self.refreshTiming() }
        }
        connectRealtime()

        // Nothing configured yet means nothing this app can do, so it opens
        // the one screen that fixes that rather than leaving a new user
        // clicking an icon that shows a disabled text box.
        if !Settings.isConfigured { openSettings() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref) }
        criticalTimer?.invalidate()
        unreadTimer?.invalidate()
        timingTimer?.invalidate()
        realtime.disconnect()
    }

    /// Opened once configured, and reopened whenever the organisation or the
    /// credential changes — the watch is scoped to one organisation, so
    /// switching is a different subscription, not a filter.
    private func connectRealtime() {
        guard Settings.isConfigured, let org = Settings.organisationID else {
            realtime.disconnect()
            return
        }
        realtime.connect(organisationID: org)
    }

    // MARK: - The menu bar item

    @objc private func statusItemClicked() {
        // Right-click is the menu, left-click is the box. A menu bar app
        // with only a popover has nowhere to put Settings or Quit; a menu
        // bar app with only a menu makes you pick "New task…" from a list
        // every time, which is a click more than the app is worth.
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu()
        } else {
            togglePopover()
        }
    }

    private func showMenu() {
        let menu = NSMenu()
        // Both by name. The popover remembers which mode it was last in, so
        // the hotkey opens whichever you used last — and this is the place
        // that says the other one exists, and opens straight into it.
        menu.addItem(withTitle: "New task…", action: #selector(newTask), keyEquivalent: "")
        menu.addItem(withTitle: "New spark…", action: #selector(newSpark), keyEquivalent: "")
        menu.addItem(withTitle: "Planner", action: #selector(showPlanner), keyEquivalent: "")
        // Named with its count, because the menu is the one place with room
        // to say it and because a bare "Notifications" is a thing you have to
        // open to find out whether it was worth opening.
        menu.addItem(
            withTitle: unread > 0 ? "Notifications (\(unread))" : "Notifications",
            action: #selector(showNotifications), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for item in menu.items where item.action != #selector(NSApplication.terminate(_:)) {
            item.target = self
        }
        // Attaching the menu to the status item and popping it up is what
        // makes it appear under the icon; it is detached again immediately
        // so the next left-click still opens the popover rather than the
        // menu, which is what `statusItem.menu` being set would cause.
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func newTask() { showPopover(sparkMode: false) }
    @objc private func newSpark() { showPopover(sparkMode: true) }

    /// The third tab, from the menu that names it. Same never-a-toggle rule
    /// as the two above: asking for the planner and having the box shut
    /// because it was already open would be a strange answer.
    @objc private func showPlanner() {
        quickAdd.setPlannerMode()
        if popover.isShown {
            sizePopover()
            return
        }
        // `togglePopover` refreshes, and refreshing deliberately puts the box
        // back on a capture tab — so the mode is asked for again once it is
        // on screen, rather than before.
        togglePopover()
        quickAdd.setPlannerMode()
        sizePopover()
    }

    /// The fourth tab, from the menu that names it — and the same
    /// never-a-toggle rule as the three above.
    @objc private func showNotifications() {
        quickAdd.setNotificationsMode()
        if popover.isShown {
            sizePopover()
            return
        }
        // `togglePopover` refreshes, and refreshing puts the box back on a
        // capture tab — so the mode is asked for again once it is on screen.
        togglePopover()
        quickAdd.setNotificationsMode()
        sizePopover()
    }

    /// Open the box in a named mode, from the menu that named it. Never a
    /// toggle: picking "New spark…" from a menu and having the box shut
    /// because it happened to be open already would be a strange answer.
    private func showPopover(sparkMode: Bool) {
        // Before the popover is shown, so `refresh()` lays it out in the
        // right mode first time rather than in one and then the other. On an
        // already-open box it changes the mode and leaves what you typed
        // alone — the words are the same words whichever of the two this
        // turns out to be.
        quickAdd.setSparkMode(sparkMode)
        if popover.isShown {
            sizePopover()
            return
        }
        togglePopover()
    }

    @objc func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        quickAdd.refresh()
        quickAdd.showCritical(critical)
        quickAdd.showTiming(timing)
        // Sized to whatever the content now needs — the critical list makes
        // this view a different height on different days, and a popover with
        // a fixed contentSize would clip it.
        popover.contentSize = quickAdd.fittingSize
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // An accessory app doesn't come forward on its own, and a popover
        // that can't take focus is a text field you can't type into.
        NSApp.activate(ignoringOtherApps: true)
        quickAdd.refresh()
        // Opening the box is the one moment somebody is definitely looking,
        // so it is worth a fresh look at what's critical even though the
        // timer will come round anyway.
        Task { await refreshCritical() }
        Task { await refreshUnread() }
        Task { await refreshTiming() }
        // Only for somebody who left the panel open, and only if this
        // organisation's lists aren't already in hand.
        if quickAdd.detailsAreVisible && listsLoadedFor != Settings.organisationID { loadLists() }
    }

    @objc func openSettings() {
        popover.performClose(nil)
        if settingsWindow == nil {
            let window = SettingsWindow()
            window.onSaved = { [weak self] in
                guard let self = self else { return }
                self.quickAdd.refresh()
                self.connectRealtime()
                Task { await self.refreshCritical() }
            }
            settingsWindow = window
        }
        settingsWindow?.show()
    }

    // MARK: - Creating

    @MainActor
    private func create(_ draft: MCPClient.Draft) async {
        guard let org = Settings.organisationID else {
            quickAdd.report("No organisation set.", isError: true)
            return
        }
        do {
            let client = try MCPClient.fromSettings()
            let id = try await client.createTask(draft, organisationID: org)
            var saying = "Task created"
            // The timer is a second call, and it is made here rather than
            // inside `createTask` because it can fail on its own: the task
            // exists either way, and a create that reported failure because
            // the clock didn't start would be lying about the important half.
            //
            // **It needs the id**, which is parsed out of the server's prose
            // answer — so if that ever changes shape this says so rather than
            // silently not starting anything. The same parse already decides
            // whether the confirmation gets an Open button; this is the one
            // place it not working actually costs something.
            var problem: String?
            if draft.startTimer {
                if let id = id {
                    do {
                        let displaced = try await client.startTimer(
                            taskID: id, organisationID: org)
                        // The server stops whatever was already running and
                        // says so. Worth repeating: somebody who forgot a
                        // timer was going has just lost the end of it, and
                        // finding that out from a timesheet next week is
                        // worse than reading it here.
                        saying = displaced == nil
                            ? "Timer started" : "Timer moved to the new task"
                    } catch {
                        problem = "Created, but the timer didn't start: "
                            + error.localizedDescription
                    }
                } else {
                    problem = "Created, but couldn't tell which task to time."
                }
            }
            // **The confirmation goes up either way, before any complaint
            // about the timer.** The task exists, and the confirmation is
            // what takes the typed text out of the field — reporting the
            // timer's failure instead would leave the title sitting there
            // under an error, which reads as "that didn't work, try again"
            // and files the same task twice.
            quickAdd.confirm(title: draft.title, opens: id.map { .task($0) })
            flashCreated(saying: saying)
            if let problem = problem {
                // After `confirm`, which owns the status line and would
                // otherwise paint "Created" in green over the top of this.
                quickAdd.report(problem, isError: true)
                // And left open, rather than closed after the usual second
                // and a half: this is the one outcome here somebody has to
                // read, and possibly act on.
                await refreshTiming()
                return
            }
            // Long enough to read the title back and be sure it was the one
            // you meant, short enough not to be in the way of the next
            // thought. The menu bar tick outlasts it deliberately, so the
            // confirmation survives the popover closing.
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            popover.performClose(nil)
            // After the popover, not before: the indicator's job starts the
            // moment the box is gone, and asking the server what is running
            // is the same one authorisation path everything else here uses
            // rather than assuming the call that just succeeded did what it
            // said. It also picks up the elapsed time and the title, which
            // `start_timer`'s own answer doesn't carry.
            if draft.startTimer { await refreshTiming() }
        } catch {
            quickAdd.report(error.localizedDescription, isError: true)
        }
    }

    /// The other half of `create`: one field, and nowhere for it to be
    /// filed wrong.
    ///
    /// No organisation is read here at all — a spark carries none, so this
    /// works on an account that has not been invited anywhere yet, which is
    /// the one case where the task path can't work.
    @MainActor
    private func capture(_ body: String) async {
        do {
            let client = try MCPClient.fromSettings()
            _ = try await client.createSpark(body: body)
            // Open goes to the Sparks screen: a spark has no page of its
            // own, and the list is where you review what has piled up.
            quickAdd.confirm(title: body, opens: .sparks)
            flashCreated(saying: "Spark saved")
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            popover.performClose(nil)
        } catch {
            quickAdd.report(error.localizedDescription, isError: true)
        }
    }

    /// Turn the menu bar icon into a green tick for a moment.
    ///
    /// The popover is gone a second and a half after a task is filed, and
    /// quick capture is by definition something you do while looking at
    /// something else — so the confirmation has to outlive the thing that
    /// showed it. The icon is the one part of this app that is always on
    /// screen, which makes it the right place for "that worked".
    ///
    /// `flashToken` is what stops two creates in quick succession from
    /// fighting: the second flash takes ownership, and the first one's
    /// timer finds a token that is no longer its own and leaves the icon
    /// alone rather than restoring it out from under the second.
    private var flashToken = 0
    private var flashing = false

    private func flashCreated(saying what: String) {
        guard let button = statusItem.button else { return }
        flashToken += 1
        flashing = true
        let mine = flashToken
        button.image = NSImage(
            systemSymbolName: "checkmark.circle.fill", accessibilityDescription: what)
        button.contentTintColor = .systemGreen
        button.title = ""
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self = self, self.flashToken == mine else { return }
            // Back to whichever state is current, not to the plain anchor:
            // between the tick appearing and this running, a poll may have
            // found something critical, and restoring the calm icon over it
            // would hide exactly the thing the red is for.
            self.flashing = false
            self.updateIcon()
        }
    }

    /// The menu bar icon, in whichever of its three states applies.
    ///
    /// Ordinary: the web app's anchor, as a template image, so it takes the
    /// menu bar's own colour in light mode, dark mode and while its menu is
    /// open. Critical: the same anchor, red — the same shape deliberately,
    /// because the icon is how this app is found in a crowded menu bar and
    /// swapping it for a bell means hunting for something that isn't there.
    /// Just created: a green tick, briefly, which outranks both because it
    /// is answering something you did a second ago.
    ///
    /// **No count beside it.** It had one; red already says the only thing
    /// the menu bar needs to say, and a number there is a second thing to
    /// read in the one place on screen with the least room to read it. The
    /// count is in the popover, where it can be a sentence.
    private func updateIcon() {
        guard let button = statusItem.button, !flashing else { return }
        let running = timing != nil
        button.image = critical.isEmpty
            ? AnchorIcon.image(badge: unread, timing: running)
            : AnchorIcon.alert(badge: unread, timing: running)
        button.contentTintColor = nil
        button.title = ""
        // Both, when there are both — the icon now carries two marks and a
        // tooltip that mentioned one of them would be the wrong half of the
        // answer as often as not.
        var lines: [String] = []
        if let timing = timing { lines.append("Timing: \(timing.title)") }
        if unread == 1 { lines.append("1 unread notification") }
        if unread > 1 { lines.append("\(unread) unread notifications") }
        button.toolTip = lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    // MARK: - The Details panel's two menus

    /// Fetched once per organisation, then reused.
    ///
    /// Not fetched on launch, and not on every open: this is two requests
    /// that only matter to somebody who has opened the Details panel, and a
    /// quick-capture box should not spend anything at all on a panel most
    /// uses of it never see. The first expansion pays for both, and a
    /// changed organisation throws them away — see `chooseOrganisation`.
    private var listsLoadedFor: String?

    private func loadLists() {
        guard Settings.isConfigured, let org = Settings.organisationID else { return }
        Task { @MainActor in
            let client = try? MCPClient.fromSettings()
            // Concurrently, because they are two independent reads and this
            // is happening under somebody's pointer.
            async let projects = client?.projects(organisationID: org)
            async let members = client?.members(organisationID: org)
            let (loadedProjects, loadedMembers) = (try? await projects, try? await members)
            // The organisation can be switched while these are in flight,
            // and filling one organisation's menus with another's projects
            // is worse than an empty menu.
            guard Settings.organisationID == org else { return }
            quickAdd.showLists(projects: loadedProjects, members: loadedMembers)
            // Only a complete answer is worth keeping. A failed fetch that
            // marked itself loaded would leave "Couldn't load projects" in
            // the menu until the app restarted.
            if loadedProjects != nil && loadedMembers != nil { listsLoadedFor = org }
            sizePopover()
        }
    }

    /// The popover is sized from the content's `fittingSize`, and the content
    /// is a different height with the Details panel open, with a longer
    /// project name in a menu, or with critical tasks listed.
    private func sizePopover() {
        guard popover.isShown else { return }
        popover.contentSize = quickAdd.fittingSize
    }

    // MARK: - Switching organisation

    /// The organisation name in the popover is a button, and this is what it
    /// opens: the list, fetched fresh, with the current one ticked.
    ///
    /// Fetched on each click rather than cached, because the cost is one
    /// request at the moment somebody has asked a question — and a stale
    /// list here means an organisation you joined this morning is missing
    /// from the only place you could pick it.
    private func pickOrganisation(from anchor: NSView) {
        Task { @MainActor in
            let menu = NSMenu()
            do {
                let orgs = try await MCPClient.fromSettings().organisations()
                for org in orgs {
                    let item = menu.addItem(
                        withTitle: org.name, action: #selector(chooseOrganisation(_:)),
                        keyEquivalent: "")
                    item.target = self
                    item.representedObject = org.id
                    item.state = org.id == Settings.organisationID ? .on : .off
                }
                if orgs.isEmpty {
                    menu.addItem(withTitle: "No organisations", action: nil, keyEquivalent: "")
                }
            } catch {
                menu.addItem(withTitle: error.localizedDescription, action: nil, keyEquivalent: "")
            }
            menu.addItem(.separator())
            let settings = menu.addItem(
                withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: "")
            settings.target = self
            // Anchored under the button rather than at the mouse, so it
            // reads as that control's menu — and inside the popover, which
            // stays open because a menu does not steal its key window.
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.height + 4), in: anchor)
        }
    }

    @objc private func chooseOrganisation(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        Settings.organisationID = id
        Settings.organisationName = sender.title
        quickAdd.refresh()
        // Another organisation's projects and people, which is not a list to
        // leave in a menu that files work somewhere.
        listsLoadedFor = nil
        quickAdd.forgetLists()
        if quickAdd.detailsAreVisible { loadLists() }
        // The badge is deliberately not cleared here: unread notifications
        // are counted across every organisation, so switching doesn't change
        // the number.
        //
        // The old organisation's critical tasks are not this one's. Cleared
        // rather than left on screen while the new answer is in flight —
        // showing one organisation's work under another's name is worse
        // than showing nothing for a moment.
        critical = []
        quickAdd.showCritical(nil)
        // Another organisation's planner, for the same reason as its projects
        // and its critical list: the one on screen is about somewhere else
        // now, and leaving it up under the new name would be the quietest
        // possible lie.
        if quickAdd.isPlannerMode { loadPlanner() }
        updateIcon()
        connectRealtime()
        Task { await refreshCritical() }
    }

    // MARK: - The planner

    /// Today and tomorrow, for the tab showing them.
    ///
    /// Fetched every time the tab is opened rather than cached: unlike the
    /// project and people menus — which are a fixed list this app holds for
    /// as long as the organisation doesn't change — a planner is the thing
    /// you rearranged five minutes ago in the web app, and a stale one is
    /// worse than a moment's spinner.
    private func loadPlanner() {
        guard Settings.isConfigured, let org = Settings.organisationID else {
            quickAdd.showPlanner(nil, reason: "Open Settings…")
            return
        }
        Task { @MainActor in
            do {
                let buckets = try await MCPClient.fromSettings().planner(
                    organisationID: org, buckets: QuickAddView.plannerBucketNames)
                // Still the tab on screen? Switching to Task while this was
                // in flight and then having a list appear under the text box
                // is the race worth spending two lines on.
                guard quickAdd.isPlannerMode else { return }
                quickAdd.showPlanner(buckets)
            } catch {
                guard quickAdd.isPlannerMode else { return }
                // The server's own sentence, which for the likeliest failure
                // — an installation older than `my_planner` — names the tool
                // it hasn't got.
                quickAdd.showPlanner(nil, reason: error.localizedDescription)
            }
        }
    }

    // MARK: - The inbox

    /// What you haven't read, for the tab showing it.
    ///
    /// Fetched on every open, like the planner and for the same reason: it is
    /// a list that changes without you, and a stale one is worse than a
    /// moment's "Loading…". **No organisation goes into this call** — the
    /// inbox is the one list here that belongs to a person rather than to a
    /// place, which is also why switching organisation doesn't reload it.
    private func loadNotifications() {
        Task { @MainActor in await reloadNotifications() }
    }

    /// The same, awaited — so a failed tick can put its complaint in the
    /// status line *after* the reload that would otherwise paint over it.
    @MainActor
    private func reloadNotifications() async {
        guard Settings.isConnected else {
            quickAdd.showNotifications(nil, reason: "Open Settings…")
            return
        }
        do {
            let inbox = try await MCPClient.fromSettings().notifications()
            guard quickAdd.isNotificationsMode else { return }
            quickAdd.showNotifications(inbox.items, unread: inbox.unread)
            // The badge and the list come out of the same answer, so this is
            // free and keeps the two from disagreeing while somebody is
            // looking at both.
            unread = inbox.unread
            updateIcon()
        } catch {
            guard quickAdd.isNotificationsMode else { return }
            // The server's own sentence — against an installation older than
            // the `notifications` tool it names the tool it hasn't got, which
            // is the likeliest reason this tab is empty.
            quickAdd.showNotifications(nil, reason: error.localizedDescription)
        }
    }

    /// Mark one read, from its tick or from opening it.
    ///
    /// Optimistic about nothing, the same as stopping a timer: the row goes
    /// when the reload says it has gone. The badge is the point of this tab,
    /// and a list that tidied itself up on the click would disagree with the
    /// number on the icon every time a call failed.
    private func closeNotification(_ id: String) {
        Task { @MainActor in
            var problem: String?
            do {
                try await MCPClient.fromSettings().markNotificationRead(id: id)
            } catch {
                problem = error.localizedDescription
            }
            await refreshUnread()
            // Reloaded even when it failed: the row is now of unknown state,
            // and the tick it was clicked with is disabled until something
            // redraws it. The complaint goes on afterwards, or the reload
            // would paint the count straight over it.
            if popover.isShown && quickAdd.isNotificationsMode {
                await reloadNotifications()
                if let problem = problem { quickAdd.reportInbox(problem) }
            }
        }
    }

    /// The whole inbox, from the button under the list.
    private func closeAllNotifications() {
        Task { @MainActor in
            var problem: String?
            do {
                try await MCPClient.fromSettings().markAllNotificationsRead()
            } catch {
                problem = error.localizedDescription
            }
            quickAdd.markAllFinished()
            await refreshUnread()
            if popover.isShown && quickAdd.isNotificationsMode {
                await reloadNotifications()
                if let problem = problem { quickAdd.reportInbox(problem) }
            }
        }
    }

    // MARK: - Opening things in the browser

    private func openInWeb(taskID: String, organisationID: String?) {
        guard let base = Settings.baseURL, let org = organisationID,
              let url = MCPClient.webURL(base: base, organisationID: org, taskID: taskID)
        else { return }
        NSWorkspace.shared.open(url)
        popover.performClose(nil)
    }

    /// Wherever a notification points, as the server stored it: a path
    /// relative to the installation, joined to whatever address Settings
    /// names. **Not rebuilt from the selected organisation** — a
    /// notification can be about another one entirely, and the whole reason
    /// the row carries a link is that this app should not be guessing.
    private func openInWeb(path: String) {
        guard let base = Settings.baseURL,
              let url = MCPClient.linkURL(base: base, path: path)
        else { return }
        NSWorkspace.shared.open(url)
        popover.performClose(nil)
    }

    /// The Sparks screen, which is not under an organisation — see
    /// `MCPClient.sparksURL`.
    private func openSparks() {
        guard let base = Settings.baseURL, let url = MCPClient.sparksURL(base: base) else { return }
        NSWorkspace.shared.open(url)
        popover.performClose(nil)
    }

    /// The installation itself, from the globe in the footer. Closes the
    /// popover like every other link out of it — you asked to be somewhere
    /// else, and a box still sitting over the browser you just opened is
    /// one Escape you should not have to press.
    private func openInstance() {
        guard let base = Settings.baseURL, let url = MCPClient.homeURL(base: base) else { return }
        NSWorkspace.shared.open(url)
        popover.performClose(nil)
    }

    // MARK: - Critical tasks

    /// The backstop, every twenty minutes, plus whenever the popover opens.
    ///
    /// **The socket is the mechanism now** (see RealtimeClient) — this used
    /// to be it, at five minutes. It stays, longer, because a dropped socket
    /// fails silently by its nature: nothing arrives, which is exactly what
    /// nothing happening looks like. Reconnect logic covers the cases it can
    /// see; a poll covers the ones it can't.
    private func startWatchingCritical() {
        criticalTimer = Timer.scheduledTimer(withTimeInterval: 1200, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            Task { await self.refreshCritical() }
        }
        Task { await refreshCritical() }
    }

    @MainActor
    private func refreshCritical() async {
        guard Settings.isConfigured, let org = Settings.organisationID else {
            critical = []
            updateIcon()
            return
        }
        do {
            critical = try await MCPClient.fromSettings().criticalTasks(organisationID: org)
        } catch {
            // Left as it was, deliberately. A dropped wifi connection must
            // not clear a red icon — "we could not check" and "nothing is
            // critical" are different answers, and only one of them is
            // safe to show as calm.
            return
        }
        updateIcon()
        if popover.isShown {
            quickAdd.showCritical(critical)
            // The section appearing or emptying makes this view a different
            // height, and only the popover can resize — without this, a
            // critical task that arrives while the box is open is drawn
            // outside it.
            sizePopover()
        }
    }

    // MARK: - Unread notifications

    /// Every two minutes.
    ///
    /// Polled rather than pushed, and that is the web app's own decision
    /// rather than a shortcut — its note reads "it's a counter. A second
    /// realtime channel just to keep a number current isn't worth the
    /// reconnect handling." The web polls it every minute while a tab is
    /// open; this runs all day in a menu bar, so it is slower, and it also
    /// recounts whenever the socket nudges, the machine wakes, or the
    /// popover opens — the three moments somebody is about to look.
    private func startWatchingUnread() {
        unreadTimer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            Task { await self.refreshUnread() }
        }
        Task { await refreshUnread() }
    }

    @MainActor
    private func refreshUnread() async {
        guard Settings.isConfigured else {
            unread = 0
            updateIcon()
            return
        }
        do {
            unread = try await MCPClient.fromSettings().unreadNotifications()
        } catch {
            // Left as it was, the same rule the critical poll follows: "we
            // couldn't check" and "nothing is waiting" are different answers
            // and only one of them is safe to draw as a clear icon.
            //
            // This is also the path an installation older than the
            // `notifications` tool takes — it answers "unknown tool", which
            // arrives here as an error, and the badge simply never appears
            // rather than the app looking broken.
            return
        }
        updateIcon()
    }

    // MARK: - The running timer

    /// Every five minutes, plus the socket, the wake, and the popover.
    ///
    /// Slower than the unread poll and faster than the critical one, which is
    /// roughly how often the answer changes: a timer is started and stopped a
    /// handful of times a day. The three event-driven moments above are what
    /// actually keep it current — and one of them, the socket, only sees the
    /// watched organisation, which is why this exists at all. There is one
    /// running timer per person across the whole installation, so a timer
    /// started in another organisation is still yours and still running.
    private func startWatchingTimer() {
        timingTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            Task { await self.refreshTiming() }
        }
        Task { await refreshTiming() }
    }

    @MainActor
    private func refreshTiming() async {
        guard Settings.isConnected else {
            timing = nil
            updateIcon()
            return
        }
        do {
            timing = try await MCPClient.fromSettings().runningTimer()
            // Only from an answer: "couldn't ask" must not cancel a question
            // already on screen, any more than it clears the pip.
            checkIn.track(timing)
        } catch {
            // Left as it was, the same rule the other two polls follow: "we
            // couldn't ask" is not "nothing is running", and only one of
            // those is safe to draw as a clear icon.
            //
            // This is also the path an installation older than the
            // `running_timer` tool takes — it answers "unknown tool", which
            // arrives here as an error, so the pip simply never appears
            // rather than the app looking broken. Starting a timer still
            // works there; only the indicator is missing.
            return
        }
        updateIcon()
        if popover.isShown {
            quickAdd.showTiming(timing)
            // Same reason as the critical section above: a timer that starts
            // while the box is open adds a row to it.
            sizePopover()
        }
    }

    /// Stop it, from the popover's row.
    ///
    /// Optimistic about nothing: the indicator is cleared from the answer,
    /// not from the click. A Stop that failed and left the icon clear would
    /// leave a clock running with nothing on screen admitting to it, which is
    /// the exact failure the indicator exists to prevent.
    private func stopTiming() {
        Task { @MainActor in
            do {
                try await MCPClient.fromSettings().stopTimer()
                timing = nil
                checkIn.track(nil)
                updateIcon()
                quickAdd.showTiming(nil)
                sizePopover()
            } catch {
                quickAdd.report(error.localizedDescription, isError: true)
            }
            quickAdd.timerStopFinished()
        }
    }

    // MARK: - Check-ins

    /// The calls behind the panel's buttons. The question itself comes from
    /// the server, through `refreshTiming` — see CheckIn.swift.
    private func startCheckIns() {
        checkIn.onAnswer = { [weak self] stillWorking in
            do {
                try await MCPClient.fromSettings().answerCheckIn(stillWorking: stillWorking)
            } catch {
                return error.localizedDescription
            }
            await self?.refreshTiming()
            return nil
        }
        checkIn.onResume = { [weak self] paused in
            do {
                try await MCPClient.fromSettings().startTimer(
                    taskID: paused.taskID, organisationID: paused.organisationID)
            } catch {
                return error.localizedDescription
            }
            await self?.refreshTiming()
            return nil
        }
    }

    // MARK: - The global hotkey

    /// ⌃⌥Space, via Carbon.
    ///
    /// Carbon because it is the only way to get a system-wide hotkey that
    /// needs **no permission prompt**: the modern-looking alternative,
    /// `NSEvent.addGlobalMonitorForEvents`, requires Accessibility access,
    /// which means sending someone to System Settings and granting an app
    /// the ability to watch every keystroke they type — an enormous
    /// permission for a text box. `RegisterEventHotKey` asks for nothing
    /// and has worked unchanged for twenty years.
    private func registerHotKey() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: OSType(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData = userData else { return noErr }
                let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async { delegate.togglePopover() }
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            nil
        )

        let id = EventHotKeyID(signature: OSType(0x41594541), id: 1)  // 'AYEA'
        RegisterEventHotKey(
            UInt32(kVK_Space),
            UInt32(controlKey | optionKey),
            id,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
    }
}
