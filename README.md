# ayeaye menu bar

A menu bar text box that creates a task in [ayeaye](https://github.com/bitrootmedia/ayeaye).
One field, Enter, done — for the thought you have while doing something else.

⌃⌥Space from anywhere, or click the anchor.

After it files a task you get a green tick, the title back, and **Open** to
jump to it in the web app. Click the organisation name to file into a
different one. And if any of your tasks are **critical**, the anchor turns red
with a count beside it and the popover lists them — click one to open it.

## Why it's its own repo

ayeaye is a deployment unit: one compose file, one hostname, `docker compose up -d`.
This is a signed `.app` on a laptop — a different artifact, a different release
cadence, and a toolchain (Xcode, signing, notarisation) that has no business in a
server repo. The two are coupled only by a documented HTTP contract.

**It needs no server-side change at all**, which is the part worth knowing. ayeaye's
REST API authenticates with a session cookie, which a native app can't get without
embedding a browser. Its MCP endpoint accepts a *personal access token* instead — the
ones on the account screen, scoped read or write, revocable there — and MCP is
stateless, so creating a task is a single `POST /mcp`. That's the whole client:
[`MCPClient.swift`](Sources/AyeAyeMenuBar/MCPClient.swift), about a hundred lines.

## Build

Needs Xcode's command line tools. No dependencies.

```sh
make install     # builds AyeAye.app and copies it to ~/Applications
open ~/Applications/AyeAye.app
```

To start it at login: System Settings › General › Login Items.

## Set it up

1. In ayeaye, open **Account** and make an access token under **Access tokens**,
   scoped **write**. It's shown once.
2. The app opens Settings on first run. Paste your server (`https://…`) and the
   token, press **Connect**, pick an organisation, **Save**.

Tasks are created as you, in that organisation, with no project — the same as a
loose task made in the web app, visible to you and your organisation's admins.

## From a script

Both modes take their settings from the environment first (`AYEAYE_SERVER`,
`AYEAYE_TOKEN`, `AYEAYE_ORG`), so a script never has to configure a machine or
leave a token on its disk:

```sh
AYEAYE_SERVER=https://ayeayecaptain.io AYEAYE_TOKEN=ayc_… AYEAYE_ORG=<uuid> \
  AyeAye.app/Contents/MacOS/AyeAyeMenuBar --create "Order the bearing housing"
```

`--configure <server> [organisation-id]` reads the token from **stdin**, never from
an argument — every process on the machine can read another's command line out of
`ps`, and this is a bearer credential.

## Test

```sh
make check
```

One test, for the one thing that shipped broken: that ⌘V works. See the
`check` target for why it needs a real event loop and a logged-in session.

## Choices worth knowing about

- **The icon is the web app's own anchor**, drawn from lucide's path data
  rather than shipped as an asset — there is no anchor in SF Symbols, and a
  PNG would need three sizes, two appearances, and would be a second place
  the brand's icon lives. As a template image it takes the menu bar's colour
  in light mode, dark mode and while its menu is open.
- **Critical turns the same anchor red rather than swapping in a bell.** The
  icon is how this app is found in a crowded menu bar; changing its shape
  means hunting for something that isn't there. Colour says "look", the
  count says "how much".
- **Critical means *yours*, not the organisation's.** The server's own
  `mine_only` filter, which resolves to tasks you own — the same set the web
  dashboard's Critical card shows. An admin can see every task in the
  company, and colouring the icon for all of them would make it permanently
  red and permanently ignored.
- **It polls every five minutes**, and whenever you open the box. There is
  nothing to subscribe to: the server's realtime channel authenticates with
  a session cookie this app deliberately doesn't have. Five minutes is
  chosen to be useless as a notification and useful as a status light.
- **A failed poll leaves the icon as it was.** "We couldn't check" and
  "nothing is critical" are different answers, and only one of them is safe
  to show as calm.

- **There is an Edit menu you can never see.** A menu bar app displays no
  menus, but AppKit implements ⌘X/⌘C/⌘V/⌘A as *main menu key equivalents*,
  not as text field behaviour — so without a main menu, every field in the
  app silently refuses to paste while accepting typing perfectly well. Which
  is no use at all when the thing you need to enter is a token.
- **The token lives in the Keychain**, not `UserDefaults` — a plist in your home
  directory that every process you run can read is the wrong place for a
  credential that can act as you.
- **The hotkey is Carbon's `RegisterEventHotKey`.** The modern-looking
  alternative, `NSEvent.addGlobalMonitorForEvents`, needs Accessibility
  permission — the right to watch every keystroke you type — which is an
  enormous thing to ask for a text box. Carbon asks for nothing.
- **The confirmation is the whole box, and the icon too.** After a create,
  the field is replaced by a green tick and the title that was filed, and the
  menu bar icon turns into a tick for two seconds. Quick capture is by
  definition something you do while looking at something else, so the
  confirmation has to outlive the popover that showed it.
- **The popover doesn't clear on failure.** What you typed is the only copy of
  it, and a box that empties itself when the network is down loses the thought
  it exists to catch.
- **No Create button.** Return submits, Escape dismisses.

## Rough edges

- **macOS asks about the Keychain again after every rebuild.** The item's ACL is
  tied to the code signature, and each build changes it. "Always Allow" is
  per-binary. Installed once and left alone, it asks once.
- **A refused write says "The server refused it. If your token is read-only, make
  a write one."** ayeaye's MCP SDK loses a refusal's actual message on the way
  out and sends a bare `Error executing tool create_task`, so the client can't
  tell you the real reason — it substitutes the thing worth checking rather than
  relaying a string that means nothing. Fixing that properly belongs on the
  server.
- **SwiftUI's `MenuBarExtra` isn't used**, because it needs the macOS 13 SDK and
  this was built against 12.3 (Xcode 13.4.1). AppKit's `NSStatusItem` does the
  same job on any SDK.
- **Ad-hoc signed, not notarised.** Fine for your own machine. Handing the `.app`
  to somebody else means a Developer ID and `notarytool`.
