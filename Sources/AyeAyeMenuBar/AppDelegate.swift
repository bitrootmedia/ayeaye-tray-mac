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
    private let realtime = RealtimeClient()

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
        quickAdd.onSubmit = { [weak self] title in await self?.create(title: title) }
        quickAdd.onPickOrganisation = { [weak self] anchor in self?.pickOrganisation(from: anchor) }
        quickAdd.onOpenTask = { [weak self] id in self?.openInWeb(taskID: id) }

        registerHotKey()
        startWatchingCritical()

        // The socket says *something moved*; what moved is refetched, the
        // same one-authorisation-path discipline the web app follows.
        realtime.onChange = { [weak self] in
            guard let self = self else { return }
            Task { await self.refreshCritical() }
        }
        // A slept-through laptop has a socket the OS killed and a backoff
        // timer minutes from firing. Waking is the moment to stop waiting.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            self.realtime.reconnectNow()
            Task { await self.refreshCritical() }
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
        menu.addItem(withTitle: "New task…", action: #selector(togglePopover), keyEquivalent: "")
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

    @objc func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        quickAdd.refresh()
        quickAdd.showCritical(critical)
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
    private func create(title: String) async {
        guard let org = Settings.organisationID else {
            quickAdd.report("No organisation set.", isError: true)
            return
        }
        do {
            let client = try MCPClient.fromSettings()
            let id = try await client.createTask(title: title, organisationID: org)
            quickAdd.confirm(title: title, taskID: id)
            flashCreated()
            // Long enough to read the title back and be sure it was the one
            // you meant, short enough not to be in the way of the next
            // thought. The menu bar tick outlasts it deliberately, so the
            // confirmation survives the popover closing.
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

    private func flashCreated() {
        guard let button = statusItem.button else { return }
        flashToken += 1
        flashing = true
        let mine = flashToken
        button.image = NSImage(
            systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "Task created")
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
        button.image = critical.isEmpty ? AnchorIcon.image() : AnchorIcon.alert()
        button.contentTintColor = nil
        button.title = ""
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
        // The old organisation's critical tasks are not this one's. Cleared
        // rather than left on screen while the new answer is in flight —
        // showing one organisation's work under another's name is worse
        // than showing nothing for a moment.
        critical = []
        quickAdd.showCritical(nil)
        updateIcon()
        connectRealtime()
        Task { await refreshCritical() }
    }

    // MARK: - Opening things in the browser

    private func openInWeb(taskID: String) {
        guard let base = Settings.baseURL, let org = Settings.organisationID,
              let url = MCPClient.webURL(base: base, organisationID: org, taskID: taskID)
        else { return }
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
        if popover.isShown { quickAdd.showCritical(critical) }
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
