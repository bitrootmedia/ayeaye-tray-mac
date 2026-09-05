import AppKit

/// The Edit menu nobody ever sees, and without which ⌘V does nothing.
///
/// A menu bar app sets its activation policy to `.accessory` and its
/// `LSUIElement` to true, which means it never displays menu bar menus of
/// its own. The trap is that AppKit does not implement ⌘X/⌘C/⌘V/⌘A in the
/// text field — it implements them as **key equivalents on the main menu**,
/// which it walks on every key event before the responder chain gets a look
/// in. No main menu, no key equivalents, and every text field in the app
/// silently refuses to paste while still accepting typing perfectly well.
///
/// Reported as "I cannot paste into that password field and I won't type
/// this very long token", which is the whole failure in one sentence: a
/// token is exactly the kind of thing nobody types.
///
/// So the menu is built and assigned even though it is never drawn. The
/// items have no target, deliberately — a nil target sends the action down
/// the responder chain to whatever is focused, which is how `paste:` reaches
/// the field editor of whichever field happens to be first responder,
/// popover or Settings window alike.
enum EditMenu {
    static func install(into app: NSApplication = .shared) {
        app.mainMenu = build()
    }

    static func build() -> NSMenu {
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        // The main menu's own items are containers: a menu bar menu is an
        // item with a submenu, not a menu added directly.
        let editItem = NSMenuItem()
        editItem.submenu = edit
        let main = NSMenu()
        main.addItem(editItem)
        return main
    }
}
