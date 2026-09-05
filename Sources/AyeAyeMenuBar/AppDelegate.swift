import AppKit
import Carbon.HIToolbox

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let quickAdd = QuickAddView(frame: NSRect(x: 0, y: 0, width: 320, height: 84))
    private var settingsWindow: SettingsWindow?
    private var hotKeyRef: EventHotKeyRef?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Before any window or field exists: without it, ⌘V is dead app-wide.
        // See EditMenu.swift — this is not decoration, it is the paste key.
        EditMenu.install()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            // A template image takes the menu bar's own colour, so it follows
            // light and dark without two assets. `checkmark.circle` is in the
            // system symbols on macOS 11+, and the text fallback is there
            // because a missing symbol would otherwise be an invisible,
            // unclickable status item — a bug with no visible symptom.
            if let image = NSImage(systemSymbolName: "checkmark.circle", accessibilityDescription: "ayeaye") {
                image.isTemplate = true
                button.image = image
            } else {
                button.title = "⌁"
            }
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

        registerHotKey()

        // Nothing configured yet means nothing this app can do, so it opens
        // the one screen that fixes that rather than leaving a new user
        // clicking an icon that shows a disabled text box.
        if !Settings.isConfigured { openSettings() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref) }
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
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // An accessory app doesn't come forward on its own, and a popover
        // that can't take focus is a text field you can't type into.
        NSApp.activate(ignoringOtherApps: true)
        quickAdd.refresh()
    }

    @objc func openSettings() {
        popover.performClose(nil)
        if settingsWindow == nil { settingsWindow = SettingsWindow() }
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
            _ = try await client.createTask(title: title, organisationID: org)
            quickAdd.report("Created", isError: false)
            // Long enough to read the confirmation, short enough that it
            // isn't in the way of the next thought.
            try? await Task.sleep(nanoseconds: 700_000_000)
            popover.performClose(nil)
        } catch {
            quickAdd.report(error.localizedDescription, isError: true)
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
