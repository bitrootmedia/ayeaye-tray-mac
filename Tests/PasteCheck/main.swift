import AppKit

// Compiled against the app's real EditMenu.swift, not a copy of it.
//
// The first version of this ran the check with no event loop and reported
// the menu claiming ⌘V while the field stayed empty — which proved nothing
// either way: a window that has never run has no field editor, so there was
// nothing for `paste:` to reach. So this one starts the real loop, waits for
// the app to actually be running, and only then synthesises the keystroke —
// through `NSApp.sendEvent`, the same call the event loop itself makes,
// rather than reaching into the menu directly.

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
EditMenu.install()

let secret = "ayc_a_very_long_token_nobody_would_type_by_hand"
NSPasteboard.general.clearContents()
NSPasteboard.general.setString(secret, forType: .string)

final class Runner: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var field: NSSecureTextField!

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 60),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        field = NSSecureTextField(frame: NSRect(x: 10, y: 10, width: 280, height: 24))
        window.contentView?.addSubview(field)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeFirstResponder(field)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.check() }
    }

    func check() {
        guard let paste = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil,
            characters: "v", charactersIgnoringModifiers: "v",
            isARepeat: false, keyCode: 9
        ) else {
            print("FAIL: could not synthesise the event")
            exit(1)
        }

        let firstResponder = window.firstResponder?.className ?? "none"
        NSApp.sendEvent(paste)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            let got = self.field.stringValue
            print("first responder: \(firstResponder)")
            print("field now holds: \(got.isEmpty ? "(nothing)" : got)")
            if got == secret {
                print("PASS — ⌘V reached a secure field")
                exit(0)
            }
            print("FAIL")
            exit(1)
        }
    }
}

let runner = Runner()
app.delegate = runner
// A guard against hanging forever if the loop never gets to the check.
DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
    print("FAIL: timed out")
    exit(1)
}
app.run()
