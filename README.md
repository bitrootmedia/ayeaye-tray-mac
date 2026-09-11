# ayeaye menu bar

A menu bar text box that creates a task in [ayeaye](https://github.com/bitrootmedia/ayeaye).
One field, Enter, done — for the thought you have while doing something else.

⌃⌥Space from anywhere, or click the anchor.

**Task or spark.** A picker at the top of the box says which of the two
Return files. A task is work, in an organisation, with a project and a
priority if you want them. A spark is the thought that isn't work yet: one
field, no organisation, and nobody else ever sees it — the same thing ⌘J
captures in the web app, and ⌘J switches modes here. The box remembers
which one you were last in, so one you mostly use one way opens that way.

After it files a task you get a green tick, the title back, and **Open** to
jump to it in the web app (a spark's **Open** goes to the Sparks screen,
which is the only page a spark has). Click the organisation name to file into a
different one. And if any of your tasks are **critical**, the anchor turns red and the
popover lists them — click one to open it. That updates **live**: change
something on the web and the tray follows in well under a second.

Unread notifications show as a **count to the left of the anchor** — the same
number as the bell in the web app, across every organisation.

**Details** (⌘D, or click it) opens the rest: a description, menus for
project, priority, who is being asked to act and which day of your own
planner it lands on, and **Work on it now** — a checkbox that starts a timer
on the task the moment it exists. All optional — the box is still a title and
Return.

**While a timer runs there's a little clock on the anchor's bottom-left
corner**, and the popover says which task and for how long, with **Stop**.
It is whatever timer *you* have going, wherever it was started — the web app,
this box, or your assistant — because there is one per person across the
whole installation, so switching organisation doesn't hide it.

## Why it's its own repo

ayeaye is a deployment unit: one compose file, one hostname, `docker compose up -d`.
This is a signed `.app` on a laptop — a different artifact, a different release
cadence, and a toolchain (Xcode, signing, notarisation) that has no business in a
server repo. The two are coupled only by a documented HTTP contract.

**It speaks to ayeaye over MCP, not the REST API**, which is the part worth knowing.
ayeaye's REST API authenticates with a session cookie, which a native app can't get
without embedding a browser. Its MCP endpoint accepts a *personal access token*
instead — the ones on the account screen, scoped read or write, revocable there — and
MCP is stateless, so creating a task is a single `POST /mcp`. That's the whole client:
[`MCPClient.swift`](Sources/AyeAyeMenuBar/MCPClient.swift), a couple of hundred lines.

For its first two versions this needed **no server-side change at all**, which was
worth saying and is no longer quite true. The Details panel broke it: `create_task`
names a project by id and a person by email — right for an assistant, which is
repeating back an id it was handed, and useless to anything that has to *offer* the
choice. So ayeaye gained two read tools (`list_projects`, `list_members`) and a
`planner_bucket` argument, later a `notifications` tool for the badge, and now
`create_spark` — sparks had a REST route and no MCP one, so this box could file
a task and not the thought that isn't one yet. Five additions, no new access
path — they call the same services the web app calls, as the token's owner.

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

Tasks are created as you, in that organisation. With nothing in the Details panel
that is a loose task with no project, exactly like one made in the web app: visible
to you and your organisation's admins. Sparks are created as you and belong to no
organisation at all — switching organisation doesn't move them, and nobody else,
admin or not, can see one.

## From a script

Both modes take their settings from the environment first (`AYEAYE_SERVER`,
`AYEAYE_TOKEN`, `AYEAYE_ORG`), so a script never has to configure a machine or
leave a token on its disk:

```sh
AYEAYE_SERVER=https://ayeayecaptain.io AYEAYE_TOKEN=ayc_… AYEAYE_ORG=<uuid> \
  AyeAye.app/Contents/MacOS/AyeAyeMenuBar --create "Order the bearing housing"
```

`--spark "a thought"` is the other one, and it needs no `AYEAYE_ORG` at all:
a spark has no organisation to be filed in.

`--configure <server> [organisation-id]` reads the token from **stdin**, never from
an argument — every process on the machine can read another's command line out of
`ps`, and this is a bearer credential.

## Test

```sh
make check
```

One test, for the one thing that shipped broken: that ⌘V works. See the
`check` target for why it needs a real event loop and a logged-in session.

```sh
AYEAYE_SERVER=http://localhost AYEAYE_TOKEN=ayc_… AYEAYE_ORG=<uuid> make check-create
```

The other one, against a real installation: that a task with every optional field
filled in arrives with every optional field filled in, that a spark is accepted and
an empty one refused for a reason you can read, that the badge's count parses, that
a timer starts, reads back and stops, and that a refusal says why.
It skips loudly without those three variables — all but the pure parsing checks,
which run either way. What it actually pins is the **parsing**: most of this app's
calls read prose written for a language model (`[id] | Name | access=owner`,
`[id] | Title | organisation_id=… | elapsed=… | started=…`), and prose is a
contract no compiler checks.

## Choices worth knowing about

- **The icon is the web app's own anchor**, drawn from lucide's path data
  rather than shipped as an asset — there is no anchor in SF Symbols, and a
  PNG would need three sizes, two appearances, and would be a second place
  the brand's icon lives. As a template image it takes the menu bar's colour
  in light mode, dark mode and while its menu is open.
- **Critical turns the same anchor red rather than swapping in a bell.** The
  icon is how this app is found in a crowded menu bar; changing its shape
  means hunting for something that isn't there.
- **The one number in the menu bar is unread notifications, and it took the
  slot a count of critical tasks was once removed from.** That removal still
  stands on its own terms: red already says everything the menu bar needs to
  about critical work, so a number beside it was a second thing to read
  saying the same thing. Unread notifications are the opposite case — there
  is no other signal for them at all, and "some" versus "none" is the entire
  message. One number, not two, is still the rule.
- **The badge is a shape, not a colour.** The digits are cut *out* of a filled
  pill, so the ordinary icon stays a template image and the badge follows
  light mode, dark mode and the inverted state while a menu is open exactly
  as the anchor does. A red badge would need a second image per appearance
  and would spend the one colour this app has already given a meaning.
- **It counts every organisation, unlike everything else here.** It is the
  same number the web app's bell shows; a badge that disagreed with the bell
  would be a second, quieter answer to the same question. Which is also why
  switching organisation doesn't change it.
- **The badge overlaps the icon's top-right corner**, the way every other
  badged icon in the menu bar does it. It had a strip of its own to the
  left for one version, on the argument that a disc small enough to fit
  inside the icon would be a smudge — and a pill sitting *beside* the
  anchor read as a separate glyph that happened to be next to it, and
  shoved everything to its left along by thirteen points the moment
  anything arrived.
- **The badge is drawn outside the anchor's own square, which is where the
  room to read it comes from.** Fitted inside an 18-point icon the digit
  really is a speck; the menu bar is 22 points thick and an 18-point icon
  leaves four of them unused, so the image takes them and the badge
  overhangs the anchor up and to the right. The anchor itself stays 18.
  The image is that size whether or not a number is showing, so nothing
  moves when one arrives.
- **What separates the badge from the icon is a cleared gap, not a
  border.** The band around the pill is erased out of the anchor before the
  pill is filled in, so a template image — one colour, by definition — still
  reads as one thing on top of another. It is the same trick the rest of the
  menu bar uses.
- **Past nine it says 9+**, in a pill that grows to the right, so its left
  edge stays where a single digit's is and never lands on the anchor's ring.
  Three digits in a menu bar is a number nobody reads as a number anyway,
  and eleven unread versus forty is not a difference you act on differently.
- **The timer's mark hangs off the bottom-left corner rather than sitting
  in it, because that corner isn't empty.** The flukes' arc sweeps
  diagonally through it — a quarter of the way across it is already three
  quarters of the way down — so a clock drawn inside the square cuts the arc
  in two and leaves the left arm stranded beside it as a crumb. That version
  was drawn, rendered at 2× and thrown away; there is no position *inside*
  the square that avoids it, because the arm's tip is at the middle of the
  left edge. Hanging it off the corner puts it diagonally clear of the arc
  with about a third of a point to spare. The room is reserved whether or
  not a timer is running, exactly as the badge's is, so nothing moves.
- **It is a clock, not a number.** The badge is a count that goes up and
  down and gets read; this is a light that is on or off and gets glanced at.
  They sit in opposite corners so neither moves when the other appears, and
  the elapsed time is in the popover, where it can be a sentence rather than
  a figure changing every minute in the place on screen with the least room
  to read one. It is drawn with the badge's own three layers — a cleared
  gap, a filled disc, the hands cut back out — so it is still a shape and
  not a colour, and it comes out red with the rest of the icon when
  something is critical.
- **In the popover, the timer's dot is green where critical's is red.** It
  is the one indicator here that means things are going *well*, and
  borrowing red for it would spend the colour this app has already given to
  "look at this now".
- **"Work on it now" is never remembered, unlike whether the Details panel
  is open.** Whether you want to see the extra fields is a preference; "I am
  starting this one now" is a statement about one task. A box that quietly
  started a clock on everything you filed would be recording work you
  weren't doing.
- **Starting a timer is a second call, after the task exists**, because it
  can fail on its own — and if it does, the confirmation still goes up and
  the complaint goes in the status line under it. Reporting the failure
  instead would leave your typed title sitting in the field under an error,
  which reads as "try again" and files the task twice.
- **The running timer isn't scoped to the selected organisation** — there is
  one per person across the whole installation, a database constraint on the
  server rather than a convention. So the tool that reports it says which
  organisation it is in, and the popover's row opens the task in *that* one
  rather than in whichever is currently selected.
- **`running_timer` was added to ayeaye for this.** The endpoint already had
  `start_timer` and `stop_timer` and nothing that could ask what was
  running, which is fine for an assistant told to start one and useless to
  an icon that has to draw the state. `list_projects`, `list_members` and
  `create_spark` arrived the same way. Against a server that predates it the
  call is refused by name, the clock simply never appears, and starting a
  timer from the checkbox still works.
- **The count is polled, every two minutes.** The web app made this call
  first and wrote down why: "it's a counter. A second realtime channel just
  to keep a number current isn't worth the reconnect handling." It also
  recounts when the socket nudges, when the machine wakes, and when the
  popover opens — the three moments somebody is about to look.
- **In the popover, the red is a dot and the words are at full contrast.**
  The heading was red text and it was unreadable on the popover's grey. Same
  rule the web app settled on for status: colour lives in a dot, not in the
  words.
- **Critical means *yours*, not the organisation's.** The server's own
  `mine_only` filter, which resolves to tasks you own — the same set the web
  dashboard's Critical card shows. An admin can see every task in the
  company, and colouring the icon for all of them would make it permanently
  red and permanently ignored.
- **It's pushed, not polled.** ayeaye already runs a WebSocket that
  publishes every task change to an `org:<id>` channel — the web board
  watches exactly that — and the server now accepts a personal access token
  on the handshake alongside the browser's cookie, so this app can watch it
  too. Measured end to end: ~180ms from a change on the web to the icon
  here.
- **The token goes in a header, not the URL.** A browser can't set headers
  on a WebSocket handshake, which is why query-string tokens exist as a
  pattern — and why they end up in server logs. A native client has no such
  limit.
- **A 20-minute poll stays, as a backstop.** A dropped socket fails
  silently by its nature: nothing arrives, which is exactly what nothing
  happening looks like. Reconnect-with-backoff covers what it can see, plus
  a reconnect on wake — a slept laptop has a socket the OS killed — and the
  poll covers the rest.
- **The watch is re-sent on every reconnect.** It's server-side state
  belonging to a socket that just died; a client that forgets it comes back
  connected, healthy and deaf. `make check` doesn't cover this one, but
  there's a harness in the commit history that restarts the API underneath
  a live client and waits for the push to resume.
- **The timer is polled every five minutes**, which is slower than the
  badge and faster than the critical backstop — roughly how often the answer
  changes. What actually keeps it current is the socket (starting and
  stopping a timer announce themselves as task changes, since time is task
  history), waking, and opening the popover. The poll is there because the
  socket watches one organisation and the timer belongs to a person.
- **A failed poll leaves the icon as it was.** "We couldn't check" and
  "nothing is critical" are different answers, and only one of them is safe
  to show as calm.
- **The Task/Spark picker is at the top of the box and behind nothing.** It
  is the one control here that changes what Return does, and a control that
  changes what Return does cannot be one you have to go and find. ⌘J flips
  it, which is the key the web app already binds for capturing a spark.
- **The mode is remembered. The Details panel's answers still aren't.** They
  look like the same kind of thing and aren't: the panel's values are
  invisible the moment it closes, so reusing them would file work somewhere
  you can't see, while the mode is spelled out three times on a box you are
  looking at — the picker, the placeholder, and the hint beside it. Somebody
  who mostly captures sparks shouldn't have to say so every time.
- **In spark mode the organisation and the Details panel are gone, not
  greyed out.** A spark has no project, no priority, nobody else's name on
  it and no organisation — the server's record carries no organisation at
  all. A disabled Project menu would invite "why can't I", and the answer
  isn't that you lack something, it's that there is no such thing here. It
  also means a spark can be captured on an account that has not been invited
  anywhere yet, which is the one case the task side can't serve.
- **The description box is drawn to match the title field, because AppKit
  doesn't.** A text field's `roundedBezel` is a soft capsule and a scroll
  view's border is a hard grey rectangle, so the two boxes you type into
  read as two different kinds of control — which they are underneath, and
  shouldn't be to anybody using them. The scroll view's own border is off
  and the field's is drawn in its place, at the same corner radius, in the
  same 15pt text. The two colours it needs were **sampled off a real
  field's pixels** rather than guessed: in dark mode a rounded bezel is
  white at 5% over whatever is behind it with no border at all, which is
  nothing like the `textBackgroundColor` the obvious version reaches for.
- **Everything past the title is behind a disclosure, closed by default.**
  The point of this app is a keystroke, a sentence and Return; five controls
  on screen for the common case would make the box three times taller to
  serve the uncommon one. ⌘D opens it from inside the title field, which is
  where the cursor is when somebody decides this one needs a project after
  all — and ⌘⏎ creates from anywhere in the box, because Return inside a
  description has to mean a new paragraph and this popover has no Create
  button to reach for instead.
- **The panel remembers whether it is open. It does not remember what was
  in it.** Those are different kinds of thing: wanting to see the fields is
  a preference, and the answers are one task's. A quick-capture box that
  quietly applies the last thought's project to the next one files work in
  the wrong place without ever saying so.
- **Priority isn't sent when it's Normal.** That's the server's own default,
  and sending it explicitly would mean this app holds an opinion about what
  the default priority is — which is the server's to change.
- **The Planner menu is your own board, never the owner's**, even when you
  file the task for somebody else. A planner in ayeaye is one person's plan
  for their own week; putting work on a colleague's board because you filed
  a ticket for them is not a thing to do quietly.
- **A menu that couldn't load says so, disabled, and nothing else stops.**
  An empty Project menu would read as "you have no projects", which is a lie
  about your work told by a failed request. Every field in the panel is
  optional, so a failure there is not a reason you can't create the task.
- **The two menus are fetched once per organisation, on first opening the
  panel.** Not at launch and not on every open: it is two requests that
  matter only to somebody who uses the panel, and a box that has to appear
  under a keystroke should spend nothing on what most uses of it never show.

- **There is an Edit menu you can never see.** A menu bar app displays no
  menus, but AppKit implements ⌘X/⌘C/⌘V/⌘A as *main menu key equivalents*,
  not as text field behaviour — so without a main menu, every field in the
  app silently refuses to paste while accepting typing perfectly well. Which
  is no use at all when the thing you need to enter is a token.
- **Refusals used to arrive with the reason missing, and that was a server bug,
  not an SDK one.** Every refused call answered with the bare string `Error
  executing tool create_task` — no reason attached — so this app substituted a
  guess ("if your token is read-only, make a write one"): a plausible sentence
  in front of somebody, at the cost of never showing the real one. The cause
  was in ayeaye: the MCP SDK draws a line between a failure a tool anticipated
  (`ToolError`, message passed through) and a crash (text withheld on purpose),
  and its refusals were plain exceptions, so they all took the crash path.
  Fixed there — `class Denied(ToolError)`. This client now shows what the
  server actually said, and keeps the guess only as a fallback for an
  installation older than that fix.
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
- **SwiftUI's `MenuBarExtra` isn't used**, because it needs the macOS 13 SDK and
  this was built against 12.3 (Xcode 13.4.1). AppKit's `NSStatusItem` does the
  same job on any SDK.
- **Ad-hoc signed, not notarised.** Fine for your own machine. Handing the `.app`
  to somebody else means a Developer ID and `notarytool`.
