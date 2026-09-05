import AppKit

/// Two ways in.
///
/// `--create "some title"` runs the whole network path — settings, keychain,
/// MCP call — with no window, no menu bar item and no event loop, and prints
/// what happened. That exists because everything that can actually be wrong
/// with this app (a bad address, a refused token, an organisation you were
/// removed from) is wrong in that path, and a menu bar popover is the single
/// worst place to debug it from. It is also the only way to test this
/// without a human clicking an icon.
///
/// Anything else launches the app.
let arguments = Array(CommandLine.arguments.dropFirst())

/// `--configure https://host [organisation-id]`, with the token on stdin.
///
/// The Settings window is the way anybody actually sets this up. This exists
/// so the setup path can be exercised without a human, and so a new machine
/// can be configured from a script. **The token is read from stdin, never
/// taken as an argument**: every process on the machine can read another's
/// command line out of `ps`, and a personal access token is a bearer
/// credential — putting it in argv would hand it to anything that happens to
/// be looking.
if arguments.first == "--configure" {
    guard arguments.count >= 2 else {
        FileHandle.standardError.write(Data(
            "usage: AyeAyeMenuBar --configure https://host [organisation-id] < token\n".utf8))
        exit(2)
    }
    Settings.baseURL = arguments[1]
    let piped = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let token = piped.trimmingCharacters(in: .whitespacesAndNewlines)
    if !token.isEmpty { Settings.token = token }

    final class Outcome { var status: Int32 = 0 }
    let outcome = Outcome()
    let semaphore = DispatchSemaphore(value: 0)
    Task {
        do {
            let client = try MCPClient.fromSettings()
            let orgs = try await client.organisations()
            let wanted = arguments.count >= 3 ? arguments[2] : nil
            // One organisation and no choice to make is the common case, so
            // it configures itself rather than making you paste a uuid you
            // would have to go and find.
            let chosen = wanted.flatMap { id in orgs.first { $0.id == id } }
                ?? (orgs.count == 1 ? orgs[0] : nil)
            guard let org = chosen else {
                print(orgs.isEmpty
                    ? "Connected, but you are not in any organisation."
                    : "Pick one and pass its id:\n" + orgs.map { "  \($0.id)  \($0.name)" }.joined(separator: "\n"))
                outcome.status = orgs.isEmpty ? 1 : 2
                semaphore.signal()
                return
            }
            Settings.organisationID = org.id
            Settings.organisationName = org.name
            print("Configured: \(org.name)")
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            outcome.status = 1
        }
        semaphore.signal()
    }
    semaphore.wait()
    exit(outcome.status)
}

if arguments.first == "--create" {
    let title = arguments.dropFirst().joined(separator: " ")
    guard !title.isEmpty else {
        FileHandle.standardError.write(Data("usage: AyeAyeMenuBar --create \"task title\"\n".utf8))
        exit(2)
    }
    // A reference box rather than a captured `var`: Swift refuses to let
    // concurrently-executing code mutate a local, and rightly — the exit
    // code is written on one thread and read on another.
    final class Outcome { var status: Int32 = 0 }
    let outcome = Outcome()
    let semaphore = DispatchSemaphore(value: 0)
    Task {
        do {
            let client = try MCPClient.fromSettings()
            guard let org = Settings.organisationID else { throw MCPError.notConfigured }
            let id = try await client.createTask(title: title, organisationID: org)
            print(id.map { "Created \($0): \(title)" } ?? "Created: \(title)")
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            outcome.status = 1
        }
        semaphore.signal()
    }
    semaphore.wait()
    exit(outcome.status)
}

let app = NSApplication.shared
// `.accessory`: a menu bar item and no Dock icon, no menu bar menus of its
// own. The Info.plist's LSUIElement says the same thing for a bundled
// build; this covers the unbundled binary, which is what a `swift run`
// during development actually produces.
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
