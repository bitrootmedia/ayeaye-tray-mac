import AppKit

/// Server, token, organisation. Opened from the menu bar item's own menu,
/// and once it has all three it never needs opening again.
///
/// A window rather than a second popover: a popover closes the moment focus
/// leaves it, and you will leave it — to open the account screen in a
/// browser and mint a token to paste back. That would be a form that
/// vanishes every time you go and fetch the one thing it is asking for.
final class SettingsWindow: NSWindowController, NSWindowDelegate {
    private let serverField = NSTextField()
    private let tokenField = NSSecureTextField()
    private let orgPopUp = NSPopUpButton()
    private let statusLabel = NSTextField(labelWithString: "")
    private var organisations: [MCPClient.Organisation] = []
    /// Server, token or organisation just changed — anything holding a
    /// connection based on the old ones needs to know. Without this, the
    /// first-run case (configure, save, then wait) left the socket
    /// unopened until the next launch.
    var onSaved: (() -> Void)?

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "ayeaye"
        self.init(window: window)
        window.delegate = self
        window.center()
        build()
    }

    private func build() {
        serverField.placeholderString = "https://ayeayecaptain.io"
        serverField.stringValue = Settings.baseURL ?? ""
        // A token is shown once, on the account screen, and never again —
        // so this box starts empty even when one is already stored, and
        // says so, rather than displaying a row of dots that implies it
        // could be read back.
        tokenField.placeholderString = Settings.token == nil ? "ayc_…" : "ayc_… (one is already saved)"

        orgPopUp.addItem(withTitle: "—")
        orgPopUp.isEnabled = false

        let connect = NSButton(title: "Connect", target: self, action: #selector(connect))
        connect.keyEquivalent = "\r"
        let save = NSButton(title: "Save", target: self, action: #selector(save))

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.stringValue = "Make a token on the account screen, under Access tokens."

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Server"), serverField],
            [NSTextField(labelWithString: "Token"), tokenField],
            [NSTextField(labelWithString: "Organisation"), orgPopUp],
            [NSView(), statusLabel],
            [NSView(), NSStackView(views: [connect, save])],
        ])
        grid.rowSpacing = 10
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.translatesAutoresizingMaskIntoConstraints = false
        window?.contentView?.addSubview(grid)
        if let content = window?.contentView {
            NSLayoutConstraint.activate([
                grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
                grid.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
                grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
                serverField.widthAnchor.constraint(greaterThanOrEqualToConstant: 300),
            ])
        }
    }

    /// Save what has been typed, then ask the server who you are. Connecting
    /// *is* the validation: a token that can list your organisations is a
    /// token that can create a task, and there is no cheaper way to find
    /// out than asking.
    @objc private func connect() {
        Settings.baseURL = serverField.stringValue.trimmingCharacters(in: .whitespaces)
        let typed = tokenField.stringValue.trimmingCharacters(in: .whitespaces)
        if !typed.isEmpty { Settings.token = typed }
        statusLabel.stringValue = "Connecting…"
        statusLabel.textColor = .secondaryLabelColor
        Task { @MainActor in
            do {
                let client = try MCPClient.fromSettings()
                organisations = try await client.organisations()
                orgPopUp.removeAllItems()
                orgPopUp.addItems(withTitles: organisations.map(\.name))
                orgPopUp.isEnabled = !organisations.isEmpty
                if let current = Settings.organisationID,
                   let index = organisations.firstIndex(where: { $0.id == current }) {
                    orgPopUp.selectItem(at: index)
                }
                statusLabel.stringValue = organisations.isEmpty
                    ? "Connected, but you're not in any organisation yet."
                    : "Connected. Pick an organisation and save."
            } catch {
                statusLabel.stringValue = error.localizedDescription
                statusLabel.textColor = .systemRed
            }
        }
    }

    @objc private func save() {
        let index = orgPopUp.indexOfSelectedItem
        guard index >= 0, index < organisations.count else {
            statusLabel.stringValue = "Connect first, then pick an organisation."
            statusLabel.textColor = .systemRed
            return
        }
        Settings.organisationID = organisations[index].id
        Settings.organisationName = organisations[index].name
        onSaved?()
        window?.close()
    }

    func show() {
        // Without this the window opens behind whatever you were using: a
        // menu bar app is an accessory and doesn't take focus on its own.
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
