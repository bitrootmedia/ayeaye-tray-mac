import Foundation

/// The other thing worth a test: that a task with every optional field filled
/// in arrives with every optional field filled in — and that the box's other
/// mode, a spark, is accepted and refused in the ways this app expects.
///
/// It runs against a real installation, taking `AYEAYE_SERVER`, `AYEAYE_TOKEN`
/// and `AYEAYE_ORG` from the environment (`Settings` reads those first for
/// exactly this reason), and it is a `make check-create` rather than part of
/// `make check` because it needs a server and a write token to say anything
/// at all. Without them it skips loudly rather than passing quietly.
///
/// What it is really testing is the **parsing**. Several of this app's calls
/// read prose written for a language model — `[id] | Name | access=owner`,
/// `email | Name | role=owner | you`, `Created [id] Title`, `Saved [id] …`,
/// `[id] | Title | organisation_id=… | elapsed=… | started=…` — and prose is
/// a contract that a compiler cannot check. A server that reworded one of
/// them would leave this app with an empty Project menu, or an icon that
/// never shows a timer, and no error anywhere.

var passed = 0
var failed = 0

func ok(_ what: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
    if condition {
        print("  ok   \(what)")
        passed += 1
    } else {
        print("  FAIL \(what)\(detail().isEmpty ? "" : ": " + detail())")
        failed += 1
    }
}

// Pure, so these run whether or not there is a server to talk to — and the
// second of them is the shape Python's `datetime.isoformat()` writes when the
// timestamp happens to land on a whole second, which is roughly one call in a
// million and would otherwise be the one that silently lost the elapsed time.
ok("a timestamp with fractional seconds parses",
   MCPClient.date(from: "2026-09-11T09:12:03.481920+00:00") != nil)
ok("…and one without them", MCPClient.date(from: "2026-09-11T09:12:03+00:00") != nil)
ok("…and nonsense doesn't", MCPClient.date(from: "some time yesterday") == nil)

let environment = ProcessInfo.processInfo.environment
guard let org = environment["AYEAYE_ORG"], environment["AYEAYE_SERVER"] != nil,
      environment["AYEAYE_TOKEN"] != nil
else {
    print("skipped: set AYEAYE_SERVER, AYEAYE_TOKEN (write) and AYEAYE_ORG to run this.")
    exit(0)
}

let semaphore = DispatchSemaphore(value: 0)
Task {
    do {
        let client = try MCPClient.fromSettings()

        let projects = try await client.projects(organisationID: org)
        ok("projects come back with ids", projects.allSatisfy { !$0.id.isEmpty })
        ok("…and names", projects.allSatisfy { !$0.name.isEmpty && !$0.name.contains("access=") })

        let members = try await client.members(organisationID: org)
        ok("members come back as emails", members.allSatisfy { $0.email.contains("@") })
        ok("…and exactly one of them is you", members.filter { $0.isYou }.count == 1)
        ok("…with no role= leaking into a name", members.allSatisfy { !$0.name.contains("role=") })

        let stamp = Int(Date().timeIntervalSince1970)
        let draft = MCPClient.Draft(
            title: "Everything filled in \(stamp)",
            description: "A **description**, in markdown.",
            projectID: projects.first?.id,
            priority: "high",
            actionRequiredEmail: members.first(where: { $0.isYou })?.email,
            plannerBucket: "today")
        let id = try await client.createTask(draft, organisationID: org)
        ok("creating returns the new task's id", id != nil)

        // Read it back through the server's own `task` tool rather than
        // trusting the create call's one-line answer: the point is that the
        // arguments *landed*, not that they were accepted.
        let readBack = try await client.call(
            tool: "task", arguments: ["organisation_id": org, "task_id": id ?? ""])
        ok("the title is there", readBack.contains("Everything filled in \(stamp)"))
        ok("the priority is there", readBack.lowercased().contains("high"))
        ok("the description is there", readBack.contains("description"))
        // The project is checked through `list_tasks`, not the read-back
        // above: `task` reports status, priority, tags and history but not
        // which project the task is in — `list_tasks`'s one-line form is the
        // only place the server says so.
        if let project = projects.first, let id = id {
            let listed = try await client.call(
                tool: "list_tasks", arguments: ["organisation_id": org, "limit": 50])
            let row = listed.split(separator: "\n").first { $0.contains(id) }
            ok("the project is there", row?.contains("project=\(project.name)") == true,
               String(row ?? "no row for \(id)"))
        }
        // The planner bucket has no read tool to check it with — a planner is
        // one person's own board and MCP exposes no view of it. It is pinned
        // on the server instead, through the REST API, in
        // `scripts/e2e-mcp.sh`'s "filing something straight onto your own
        // planner" block.

        // The badge's number. Parsed off the front of a prose line, so it is
        // the same kind of contract as the two lists above and breaks the
        // same silent way — a badge that never appears looks identical to
        // having nothing unread.
        let before = try await client.unreadNotifications()
        ok("the unread count reads as a number", before >= 0, "\(before)")
        // That the number *moves* is not checked here, and can't be: this
        // harness has one account, and `should_notify_action_required` never
        // notifies you about yourself — "putting it on yourself, which you
        // already know about" is one of the three cases it exists to
        // suppress. `scripts/e2e-mcp.sh`'s "notification inbox" block has two
        // accounts and pins the moving part there.

        // The other thing the box files. One field, no organisation — and
        // no MCP tool that reads sparks back, deliberately, so this checks
        // what it can: that the call is accepted and that its answer is
        // still the `Saved [id] body` shape the id is parsed out of. That
        // the row is private to its author is pinned on the server, where
        // there are two accounts to prove it with, in `scripts/e2e-mcp.sh`.
        let sparkID = try await client.createSpark(body: "Spark from check-create \(stamp)")
        ok("capturing a spark returns its id", sparkID != nil)

        // An empty one is refused by the server as an anticipated refusal
        // (`Denied`), not as a crash — which is the difference between this
        // box showing a reason and showing nothing at all.
        do {
            _ = try await client.createSpark(body: "   ")
            ok("an empty spark is refused", false, "it succeeded")
        } catch {
            let message = error.localizedDescription
            ok("an empty spark says why", message.lowercased().contains("needs something"), message)
        }

        // The timer the icon draws its pip from, and the box's "Work on it
        // now" checkbox. Three prose contracts in one round trip: what
        // `start_timer` says it displaced, the five fields `running_timer`
        // answers with, and that stopping clears it.
        if let id = id {
            let displaced = try await client.startTimer(taskID: id, organisationID: org)
            // Whatever this harness's account had running before, if
            // anything — this is the field, not the fact, that is being
            // checked, since a fresh account has nothing to displace.
            ok("starting reports a displacement or none", displaced != id)
            guard let running = try await client.runningTimer() else {
                ok("the started timer is the running one", false, "nothing running")
                throw MCPError.malformed("that timer")
            }
            ok("the running timer is the task just started", running.taskID == id)
            ok("…and carries the title, not just the id",
               running.title.contains("Everything filled in \(stamp)"), running.title)
            ok("…and the organisation it is in", running.organisationID == org,
               running.organisationID)
            // Both of these come off the same line and are the reason the
            // tool answers with two shapes of the same number: the string is
            // right when it is written and stale a minute later, so the
            // popover recomputes from the timestamp and only falls back to
            // the string when it cannot be read.
            ok("…and a readable elapsed time", !running.elapsed.isEmpty, running.elapsed)
            ok("…and a start time that parses", running.startedAt != nil)
            ok("…that is in the past, not the future",
               (running.startedAt ?? .distantFuture) <= Date())
            try await client.stopTimer()
            ok("stopping leaves nothing running", try await client.runningTimer() == nil)
            // The server is idempotent about this and so is the popover's
            // Stop, which can be clicked twice before the first answer lands.
            try await client.stopTimer()
            ok("…and stopping twice is not an error", true)
        }

        // A refusal has to arrive as a sentence somebody can act on, not as
        // the SDK's bare wrapper — this is the whole reason `Denied`
        // subclasses `ToolError` on the server.
        do {
            _ = try await client.createTask(
                MCPClient.Draft(title: "no", actionRequiredEmail: "nobody@example.invalid"),
                organisationID: org)
            ok("a refusal is refused", false, "it succeeded")
        } catch {
            let message = error.localizedDescription
            ok("a refusal says why", message.contains("not a member"), message)
            ok("…without the SDK's wrapper", !message.hasPrefix("Error executing tool"), message)
        }
    } catch {
        print("  FAIL \(error.localizedDescription)")
        failed += 1
    }
    semaphore.signal()
}
semaphore.wait()

print("\npassed \(passed), failed \(failed)")
exit(failed == 0 ? 0 : 1)
