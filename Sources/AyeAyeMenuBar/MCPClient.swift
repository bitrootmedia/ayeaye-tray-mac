import Foundation

enum MCPError: LocalizedError {
    case notConfigured
    case http(Int, String)
    case rpc(String)
    case malformed(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Set your server, token and organisation first."
        case let .http(status, body):
            // 401 is worth naming, because it has exactly one cause and one
            // fix, and "HTTP 401" tells nobody what to do about it.
            if status == 401 { return "Your token was refused. Make a new one and paste it in Settings." }
            return "The server answered \(status). \(body.prefix(200))"
        case let .rpc(message):
            return message
        case let .malformed(what):
            return "Couldn't read the server's answer (\(what))."
        }
    }
}

/// A very small MCP client: one method, `call`, over the streamable-HTTP
/// transport, and a handful of calls built on it.
///
/// This talks to `/mcp` rather than to the REST API for a reason worth
/// keeping written down: the REST API authenticates with a SuperTokens
/// session cookie, which a native app has no way to obtain without
/// embedding a browser and a sign-in flow. `/mcp` accepts a personal access
/// token — the ones minted on the account screen, scoped read or write,
/// revocable from the same screen — so a menu bar app can exist against an
/// unmodified installation.
///
/// It is also **stateless** on purpose (see the server's own notes): there
/// is no `initialize` handshake to do and no session id to carry, so one
/// POST is a complete interaction. That is the whole reason this file is a
/// couple of hundred lines rather than a protocol implementation.
///
/// **Some of the calls below are newer than the server's first version of
/// this endpoint.** `list_projects` and `list_members` were added to ayeaye
/// for the Details panel: every write tool names a project by id and a
/// person by email, which is right for an assistant repeating back an id it
/// was handed and useless to a menu that has to offer the choice. Against an
/// installation predating them the two menus say "couldn't load" and
/// everything else still works. `create_spark` was added for the box's
/// second mode, and against an older server it is refused by name — which
/// is the right answer, because there is nowhere for a spark to go.
/// `running_timer` was added for the timer indicator on the icon: the
/// endpoint already had `start_timer` and `stop_timer`, and nothing that
/// could ask what was running. `my_planner` is the newest and the same
/// shape of gap: `create_task` could *put* a task in a planner bucket from
/// the first version of the Details panel, and nothing could read a board
/// back. The Planner tab says so plainly against a server that hasn't got
/// it — an empty list and "this server cannot tell me" must not look alike.
/// `mark_notification_read` and `mark_all_notifications_read` are the
/// newest, and the first *writes* added for this app rather than reads: the
/// badge could count unread notifications and do nothing about them, which
/// is a number that only ever goes up. The same tab made `notifications`
/// answer with a link and a timestamp per row, so an inbox you can act on
/// knows where a thing goes and how old it is.
struct MCPClient {
    let baseURL: String
    let token: String

    static func fromSettings() throws -> MCPClient {
        guard let base = Settings.baseURL, !base.isEmpty, let token = Settings.token else {
            throw MCPError.notConfigured
        }
        return MCPClient(baseURL: base, token: token)
    }

    /// Call one tool and return its text output.
    func call(tool: String, arguments: [String: Any]) async throws -> String {
        var trimmed = baseURL.trimmingCharacters(in: .whitespaces)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard let url = URL(string: trimmed + "/mcp") else {
            throw MCPError.malformed("that server address")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Both, and both are required: the streamable-HTTP transport refuses
        // a request that doesn't accept `text/event-stream`, and then answers
        // most calls with plain JSON anyway. Sending only one of the two is
        // a 406 that reads like a server fault.
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": ["name": tool, "arguments": arguments],
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        let body = String(data: data, encoding: .utf8) ?? ""
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw MCPError.http(http.statusCode, body)
        }
        return try Self.text(fromEnvelope: body)
    }

    /// Pull the tool's text out of a JSON-RPC envelope, which may or may not
    /// be wrapped in SSE framing depending on how the server chose to answer.
    static func text(fromEnvelope body: String) throws -> String {
        var json = body
        if let line = body.split(separator: "\n").first(where: { $0.hasPrefix("data: ") }) {
            json = String(line.dropFirst("data: ".count))
        }
        guard let data = json.data(using: .utf8),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw MCPError.malformed("not JSON") }

        if let error = root["error"] as? [String: Any],
           let message = error["message"] as? String {
            throw MCPError.rpc(message)
        }
        guard let result = root["result"] as? [String: Any],
              let content = result["content"] as? [[String: Any]]
        else { throw MCPError.malformed("no result") }

        let text = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
        // A refused call comes back as an ordinary result with this flag set,
        // not as a transport error — so a read-only token, or a task you
        // can't see, would otherwise look like a success with an apologetic
        // sentence in it.
        if result["isError"] as? Bool == true {
            throw MCPError.rpc(refusal(from: text))
        }
        return text
    }

    /// What to show somebody when the server turns a call down.
    ///
    /// A refusal arrives wrapped: the MCP SDK prefixes the tool's own message
    /// with `Error executing tool <name>: `. The message after the colon is
    /// the useful half — "no such organisation", "nobody@example.com is not a
    /// member of that organisation", "this credential is read-only" — so the
    /// wrapper is dropped and the sentence kept.
    ///
    /// **The fallback is for an older server.** The wrapper used to arrive
    /// with nothing after it at all, because the server raised refusals as
    /// plain exceptions and the SDK withholds a crash's text on purpose;
    /// that is fixed there now (`class Denied(ToolError)`), but an app on a
    /// laptop outlives the version of the server it was built against, and a
    /// bare "Error executing tool create_task" in front of somebody says
    /// nothing they can act on. So it is replaced with the thing actually
    /// worth checking.
    static func refusal(from text: String) -> String {
        let generic = "The server refused it. If your token is read-only, make a write one."
        guard text.hasPrefix("Error executing tool") else {
            return text.isEmpty ? generic : text
        }
        guard let colon = text.firstIndex(of: ":") else { return generic }
        let message = text[text.index(after: colon)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? generic : message
    }

    // MARK: - Creating a task

    /// Everything the box can say about a task. All of it optional except the
    /// title, which is the only thing quick capture actually requires — the
    /// rest is there for the times you already know where the thought
    /// belongs, and absent the rest of the time.
    struct Draft {
        var title: String
        var description: String?
        var projectID: String?
        /// `nil` means don't send it, and the server's own default (`normal`)
        /// applies. Deliberately not sending "normal" explicitly: the default
        /// belongs to the server, and duplicating it here is a second place
        /// for it to be wrong.
        var priority: String?
        var actionRequiredEmail: String?
        /// Your own planner board, not the owner's — see the server's note on
        /// `planner_bucket`.
        var plannerBucket: String?
        /// Whether to start timing it once it exists.
        ///
        /// **Not sent to `create_task`** — there is no such argument, and
        /// there shouldn't be: a timer is a record of what you did, not a
        /// property of the work. It is a second call, `start_timer`, made
        /// with the id the create answered with. This flag rides in the draft
        /// because the box collected it alongside everything else, and the
        /// alternative was a second parameter threaded through the same three
        /// callbacks.
        var startTimer: Bool = false
    }

    /// Returns the new task's id, so it can be opened afterwards.
    ///
    /// `create_task` answers `Created [<uuid>] <title>` — prose, because its
    /// real audience is a language model. Same parse-the-sentence bargain as
    /// `organisations` below: mildly ugly here, and much better than a
    /// second endpoint on the server existing only for this app.
    @discardableResult
    func createTask(_ draft: Draft, organisationID: String) async throws -> String? {
        var arguments: [String: Any] = [
            "organisation_id": organisationID,
            "title": draft.title,
        ]
        // Omitted, not sent empty. `update_task` reads an empty string as
        // "clear this field"; `create_task` has nothing to clear, but sending
        // one anyway would mean this app relies on the two agreeing forever.
        if let value = draft.description, !value.isEmpty { arguments["description"] = value }
        if let value = draft.projectID { arguments["project_id"] = value }
        if let value = draft.priority { arguments["priority"] = value }
        if let value = draft.actionRequiredEmail { arguments["action_required_email"] = value }
        if let value = draft.plannerBucket { arguments["planner_bucket"] = value }
        let answer = try await call(tool: "create_task", arguments: arguments)
        return Self.firstBracketedID(in: answer)
    }

    // MARK: - Capturing a spark

    /// The other thing this box can file: a stray thought that is not work
    /// yet. One field, and **no organisation** — a spark carries no
    /// `organisation_id` at all on the server, deliberately, because the
    /// point of catching a thought is that it arrives while you are looking
    /// at something else and possibly at some other organisation entirely.
    ///
    /// `create_spark` is newer than this app's first version of the Details
    /// panel and was added to ayeaye for it; against an installation that
    /// predates it the call is refused by name and the box says so.
    ///
    /// The id comes back for the same reason `createTask`'s does — the
    /// answer is prose, and parsing it is the only check that its shape is
    /// still what this app thinks it is — but nothing opens it: the web app
    /// has one Sparks screen and no route to a single spark.
    @discardableResult
    func createSpark(body: String) async throws -> String? {
        let answer = try await call(tool: "create_spark", arguments: ["body": body])
        return Self.firstBracketedID(in: answer)
    }

    /// The Sparks screen. Not under `orgs/:orgId` like a task, because a
    /// spark isn't in an organisation — it sits at the bare root next to
    /// the inbox, which is the SPA's own route for it.
    static func sparksURL(base: String) -> URL? {
        guard let home = homeURL(base: base) else { return nil }
        return URL(string: home.absoluteString + "/sparks")
    }

    /// The installation itself — whatever `Settings.baseURL` names, and no
    /// route past it.
    ///
    /// The one link here that asserts nothing about what you will find: a
    /// task link can 404 if the id is wrong or the organisation isn't the
    /// one it is in, and this cannot, because the address *is* the setting
    /// the whole app is pointed at. It is also the only way out of the box
    /// that doesn't require something to have happened first — no created
    /// task, no critical list, no running timer.
    static func homeURL(base: String) -> URL? {
        var trimmed = base.trimmingCharacters(in: .whitespaces)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard !trimmed.isEmpty else { return nil }
        return URL(string: trimmed)
    }

    // MARK: - The lists behind the pickers

    struct Project {
        let id: String
        let name: String
    }

    /// The projects you can file into. Yours, not the organisation's — a
    /// project is private to its owner until it is shared, and the server
    /// resolves that; this list is whatever it hands back.
    ///
    /// Archived ones are left out. They are still valid targets as far as the
    /// server is concerned, and a menu of finished work to file new work into
    /// is a longer menu that is wrong more often.
    func projects(organisationID: String) async throws -> [Project] {
        let text = try await call(tool: "list_projects", arguments: [
            "organisation_id": organisationID,
        ])
        return text.split(separator: "\n").compactMap { line in
            // `[id] | Name | access=owner`, with `| archived` when it is.
            guard line.hasPrefix("["), let id = Self.firstBracketedID(in: line) else { return nil }
            let fields = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.count > 1, !fields.contains("archived") else { return nil }
            return Project(id: id, name: fields[1])
        }
    }

    struct Member {
        let email: String
        let name: String
        let isYou: Bool
    }

    /// Who can be asked to act. Emails, because that is what `create_task`
    /// takes — it names people the way a person says them out loud rather
    /// than by id.
    func members(organisationID: String) async throws -> [Member] {
        let text = try await call(tool: "list_members", arguments: [
            "organisation_id": organisationID,
        ])
        return text.split(separator: "\n").compactMap { line in
            // `email | Display Name | role=member`, plus `| you` for yourself.
            let fields = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.count > 1, fields[0].contains("@") else { return nil }
            return Member(email: fields[0], name: fields[1], isYou: fields.contains("you"))
        }
    }

    static func firstBracketedID<S: StringProtocol>(in line: S) -> String? {
        guard let open = line.firstIndex(of: "["),
              let close = line[open...].firstIndex(of: "]")
        else { return nil }
        let id = String(line[line.index(after: open)..<close])
        return id.isEmpty ? nil : id
    }

    struct TaskSummary {
        let id: String
        let title: String
    }

    /// The critical tasks that are yours and still open.
    ///
    /// `mine_only` is the server's own filter, which resolves to "tasks you
    /// own" — so this is the same set the web dashboard's Critical card
    /// shows, not everything critical in the organisation. That distinction
    /// matters for something that turns the menu bar red: an admin can see
    /// every task in the company, and colouring the icon for all of them
    /// would make it permanently red and permanently ignored.
    func criticalTasks(organisationID: String) async throws -> [TaskSummary] {
        let text = try await call(tool: "list_tasks", arguments: [
            "organisation_id": organisationID,
            "priority": "critical",
            "mine_only": true,
            "limit": 20,
        ])
        return text.split(separator: "\n").compactMap { line in
            // The first line is a count header ("3 of 3 task(s):"), and rows
            // are `[id] | title | status=… | priority=…`.
            guard line.hasPrefix("["), let id = Self.firstBracketedID(in: line) else { return nil }
            let fields = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.count > 1 else { return nil }
            return TaskSummary(id: id, title: fields[1])
        }
    }

    // MARK: - The planner

    /// One bucket off your own planner board, and what is in it.
    struct PlannerBucket {
        /// The server's own name for it — `today`, `tomorrow`, and the three
        /// this app doesn't ask for.
        let name: String
        let tasks: [TaskSummary]
    }

    /// Your planner, narrowed to the buckets asked for and put in that order.
    ///
    /// `my_planner` is the newest of the reads this app leans on and the one
    /// most likely to be missing: against an installation that predates it
    /// the call is refused by name, and the tab says so rather than showing
    /// an empty board — "you have planned nothing today" and "this server
    /// cannot tell me" are different answers and only one of them is calm.
    ///
    /// **Yours, and only ever yours.** The tool takes no user argument at
    /// all — an admin arranges somebody else's board from the web app, and
    /// there is no way to read a colleague's from here.
    ///
    /// The answer is a board written for a language model:
    ///
    /// ```
    /// today (2):
    ///   [uuid] | Order the bearing housing | status=todo | priority=high
    /// tomorrow (1):
    ///   [uuid] | Ring the foundry | status=todo | priority=normal
    ///
    /// 7 open task(s) you have not planned. …
    /// ```
    ///
    /// A header is `<bucket> (<n>):` and a row is the same `[id] | title | …`
    /// every other list here speaks, indented under it. The trailing sentence
    /// about unplanned work is for a model deciding what to do next and is
    /// not a row, which is why rows are recognised by their bracket rather
    /// than by not being a header.
    func planner(organisationID: String, buckets wanted: [String]) async throws -> [PlannerBucket] {
        let text = try await call(
            tool: "my_planner", arguments: ["organisation_id": organisationID])
        return Self.plannerBoard(from: text, buckets: wanted)
    }

    /// The parse on its own, so `make check-create` can pin it without a
    /// server — which is the whole point of that file: prose written for a
    /// language model is a contract no compiler checks, and a reworded board
    /// would leave this tab permanently empty with no error anywhere.
    static func plannerBoard(from text: String, buckets wanted: [String]) -> [PlannerBucket] {
        var found: [String: [TaskSummary]] = [:]
        var bucket: String?
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                guard let id = Self.firstBracketedID(in: line) else { continue }
                let fields = line.split(separator: "|").map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
                guard fields.count > 1, let name = bucket else { continue }
                found[name, default: []].append(TaskSummary(id: id, title: fields[1]))
            } else if line.hasSuffix(":"), let paren = line.firstIndex(of: "(") {
                bucket = String(line[..<paren]).trimmingCharacters(in: .whitespaces)
            }
        }
        // Walked in the caller's order rather than the answer's, which is the
        // same discipline the server applies to its own BUCKETS constant: the
        // order of a planner is the whole meaning of a planner, and inheriting
        // it from however the rows happened to arrive is how it gets silently
        // re-spelled later.
        return wanted.compactMap { name in
            guard let tasks = found[name], !tasks.isEmpty else { return nil }
            return PlannerBucket(name: name, tasks: tasks)
        }
    }

    // MARK: - The inbox

    /// One unread notification, as the tab lists it.
    ///
    /// **Not organisation-scoped**, alone among the things this app lists: a
    /// notification is addressed to a person rather than filed in a place,
    /// so switching organisation neither adds to this list nor takes from
    /// it. That is the same rule the badge follows, and it has to be — the
    /// tab is the badge's own list, and a list that disagreed with the
    /// number on the icon would send you looking for the difference.
    struct Notification {
        let id: String
        let title: String
        /// The server's own `kind`, unprettified — `task_action_required`
        /// and the dozen others. Turned into words by `label(forKind:)`,
        /// here rather than on the server because it is a display decision
        /// and the tool's audience is mostly not a person.
        let kind: String
        /// Where the web app puts this notification's subject, relative to
        /// the installation — `/orgs/…/tasks/…`. The server's stored
        /// `link_path`, not a route this app reassembles out of ids in a
        /// title, so the two can never disagree. `nil` for the handful of
        /// notifications that are about nothing openable.
        let linkPath: String?
        /// When it arrived, so the row can say how old it is. The elapsed
        /// string is worked out here for the same reason the timer's is: a
        /// formatted age is right when it is written and wrong an hour later.
        let createdAt: Date?
    }

    /// The unread inbox, and how many there are.
    ///
    /// The count is not `items.count`: the tool answers with every unread
    /// notification up to `limit` and states the real total on its first
    /// line, so a person with forty unread sees ten rows and the honest
    /// number. That is also why the badge can ask for `limit: 1`.
    func notifications(limit: Int = 20) async throws -> (unread: Int, items: [Notification]) {
        let text = try await call(tool: "notifications", arguments: ["limit": limit])
        return try Self.inbox(from: text)
    }

    /// How many notifications you have not read, across every organisation.
    ///
    /// **Not scoped to the selected organisation, unlike everything else this
    /// app shows.** It is the same number as the bell in the web app, and a
    /// badge that disagreed with the bell would be a second, quieter answer
    /// to the same question — you would click through to find out which one
    /// was lying.
    ///
    /// The tool leads with the count on its own line (`3 unread:`) precisely
    /// so a caller that only wants the number doesn't have to count rows —
    /// which is why the badge asks for one row rather than for none: `limit`
    /// has a floor of 1 on the server, and the answer's first line is the
    /// whole of what this reads.
    func unreadNotifications() async throws -> Int {
        try await notifications(limit: 1).unread
    }

    /// The parse on its own, so `make check-create` can pin it without a
    /// server — the same bargain `plannerBoard` makes, and the same risk: a
    /// reworded row would leave the tab permanently empty and no error
    /// anywhere.
    ///
    /// ```
    /// 2 unread:
    /// [uuid] | Ada asked you to act | kind=task_action_required | at=2026-09-22T09:12:03+00:00 | link=/orgs/…/tasks/…
    /// ```
    ///
    /// The count leads on its own line and is there even when nothing is
    /// listed (`0 unread.`). Rows are recognised by their bracket, like
    /// every other list here, and their keyed fields are read by name rather
    /// than by position — a title containing a `|` shifts the columns, and
    /// the fields that decide where a row *goes* must not move with it.
    static func inbox(from text: String) throws -> (unread: Int, items: [Notification]) {
        guard let first = text.split(separator: "\n").first else { return (0, []) }
        let digits = first.prefix { $0.isNumber }
        guard let unread = Int(digits) else { throw MCPError.malformed("that unread count") }
        let items = text.split(separator: "\n").compactMap { line -> Notification? in
            guard line.hasPrefix("["), let id = firstBracketedID(in: line) else { return nil }
            let fields = line.split(separator: "|").map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard fields.count > 1 else { return nil }
            func value(_ key: String) -> String? {
                fields.first { $0.hasPrefix(key + "=") }
                    .map { String($0.dropFirst(key.count + 1)) }
            }
            // A read one can only arrive here if something asked for them —
            // the tab doesn't — and it would be a row that vanishes when the
            // list next reloads, which is worse than not showing it.
            guard !fields.contains("read") else { return nil }
            return Notification(
                id: id, title: fields[1], kind: value("kind") ?? "",
                linkPath: value("link"), createdAt: value("at").flatMap(date(from:)))
        }
        return (unread, items)
    }

    /// Mark one read. The tick on a row, and what takes the badge down.
    ///
    /// Nothing is deleted: the notification stays in the web app's inbox as
    /// history, which is the reason this tab's button is a tick rather than
    /// a bin. A read-only token is refused by name, the same as every other
    /// write here.
    func markNotificationRead(id: String) async throws {
        _ = try await call(tool: "mark_notification_read", arguments: ["notification_id": id])
    }

    /// Mark the lot read, across every organisation — the web app's own
    /// "Mark all read".
    func markAllNotificationsRead() async throws {
        _ = try await call(tool: "mark_all_notifications_read", arguments: [:])
    }

    /// Where a notification points, as an address. The server stores a path
    /// relative to the installation precisely so it survives being deployed
    /// on any hostname, and this is the one place it is joined to one.
    static func linkURL(base: String, path: String) -> URL? {
        guard let home = homeURL(base: base) else { return nil }
        let route = path.hasPrefix("/") ? path : "/" + path
        return URL(string: home.absoluteString + route)
    }

    /// The server's `kind` as something to read.
    ///
    /// A closed set on the server (a CHECK constraint, see
    /// `models/notification.py`), so this could be exhaustive — and is
    /// deliberately not: an installation newer than this app will raise
    /// kinds it has never heard of, and "book_shared" spelled out is a
    /// better answer than a row that refuses to say what it is.
    static func label(forKind kind: String) -> String {
        switch kind {
        case "task_action_required": return "Asked to act"
        case "task_action_required_cleared": return "Handed back"
        case "task_owner_changed": return "Owner changed"
        case "task_closed": return "Closed"
        case "task_shared": return "Shared with you"
        case "project_shared": return "Project shared"
        case "reminder_soon": return "Reminder coming"
        case "reminder_due": return "Reminder due"
        case "task_deadline_tomorrow": return "Due tomorrow"
        case "daily_summary": return "Daily summary"
        case "export_ready": return "Export"
        case "book_shared": return "Book shared"
        case "comment_mention": return "Mentioned you"
        default:
            let words = kind.replacingOccurrences(of: "_", with: " ")
            return words.isEmpty ? "Notification" : words.prefix(1).uppercased() + words.dropFirst()
        }
    }

    /// How long ago, in the fewest characters that are still true.
    ///
    /// Coarser than the timer's `elapsed`, on purpose: a running clock is
    /// something you are watching to the minute, and a notification is
    /// something that arrived at some point — "2h" is the whole of what a
    /// row three inches wide has room to say about when.
    static func age(since start: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(start)))
        let minutes = seconds / 60
        if minutes < 1 { return "now" }
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h" }
        let days = hours / 24
        if days < 7 { return "\(days)d" }
        return "\(days / 7)w"
    }

    // MARK: - The timer

    /// What you are timing, if anything.
    ///
    /// **Not scoped to the selected organisation**, for the same reason the
    /// unread count isn't: there is one running timer per person across the
    /// whole installation — a partial unique index on the server, not a
    /// convention — so a timer left going in another organisation is still
    /// yours and still running, and an icon that went quiet when you switched
    /// would be hiding exactly the thing it exists to show.
    ///
    /// `running_timer` was added to ayeaye for this, the same way
    /// `list_projects` and `create_spark` were. `start_timer` and
    /// `stop_timer` were already there; nothing could ask what was running.
    /// Against an installation predating it the call is refused by name,
    /// which arrives here as an error — and the caller leaves the indicator
    /// alone rather than showing a timer that isn't there.
    struct RunningTimer {
        let taskID: String
        let title: String
        let organisationID: String
        /// When it started, so elapsed time can be recomputed locally rather
        /// than asked for again. The server sends `elapsed=1h 30m` as well,
        /// and that is what this falls back to when the timestamp can't be
        /// read — a formatted string is a fine thing to show once and a
        /// useless thing to keep, since it is wrong a minute later.
        let startedAt: Date?
        let elapsed: String
    }

    /// `nil` for "nothing is running", which is an answer rather than a
    /// failure — a failure throws, and the difference matters upstream: one
    /// clears the indicator and the other must leave it alone.
    func runningTimer() async throws -> RunningTimer? {
        let text = try await call(tool: "running_timer", arguments: [:])
        // `[task-id] | Title | organisation_id=… | elapsed=… | started=…`,
        // or "Nothing is running." — which has no bracket, so the same test
        // every other parse here uses distinguishes them.
        guard let line = text.split(separator: "\n").first(where: { $0.hasPrefix("[") }),
              let id = Self.firstBracketedID(in: line)
        else { return nil }
        let fields = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        guard fields.count > 2 else { throw MCPError.malformed("that timer") }
        func value(_ key: String) -> String? {
            fields.first { $0.hasPrefix(key + "=") }
                .map { String($0.dropFirst(key.count + 1)) }
        }
        guard let org = value("organisation_id"), !org.isEmpty else {
            // A timer with no organisation is one this app cannot open or
            // place, which is worse than not knowing about it.
            throw MCPError.malformed("that timer's organisation")
        }
        return RunningTimer(
            taskID: id, title: fields[1], organisationID: org,
            startedAt: value("started").flatMap(Self.date(from:)),
            elapsed: value("elapsed") ?? "")
    }

    /// The server's `started=` is an ISO-8601 timestamp from Python's
    /// `datetime.isoformat()`, which writes fractional seconds when it has
    /// them and leaves them out when it doesn't — so both shapes have to
    /// parse, and `ISO8601DateFormatter` takes one set of options at a time.
    static func date(from iso: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        for options in [
            [.withInternetDateTime, .withFractionalSeconds] as ISO8601DateFormatter.Options,
            [.withInternetDateTime],
        ] {
            formatter.formatOptions = options
            if let date = formatter.date(from: iso) { return date }
        }
        return nil
    }

    /// Start timing a task. Returns the title of whatever it displaced, if it
    /// displaced anything.
    ///
    /// Starting stops whatever was already running — the server's own rule,
    /// not this app's, and the right one: switching tasks is the commonest
    /// thing anybody does with a tracker. It says so in its answer
    /// (`Timer started on [id] (stopped the one running on [id])`), and the
    /// id of the displaced task is worth passing back up so the box can
    /// mention it rather than swallowing it.
    @discardableResult
    func startTimer(taskID: String, organisationID: String) async throws -> String? {
        let answer = try await call(tool: "start_timer", arguments: [
            "organisation_id": organisationID,
            "task_id": taskID,
        ])
        // The second bracketed id, when there is one. Deliberately read off
        // the phrase rather than by counting brackets: an answer that only
        // ever has one id must not be misread as having displaced something.
        guard let phrase = answer.range(of: "stopped the one running on ") else { return nil }
        return Self.firstBracketedID(in: answer[phrase.upperBound...])
    }

    /// Stop whatever is running. Idempotent on the server — nothing running
    /// is not an error there, and so isn't one here.
    func stopTimer() async throws {
        _ = try await call(tool: "stop_timer", arguments: [:])
    }

    /// Where a task lives in the web app. The SPA's own route, which is the
    /// contract this relies on — `orgs/:orgId/tasks/:taskId`.
    static func webURL(base: String, organisationID: String, taskID: String) -> URL? {
        guard let home = homeURL(base: base) else { return nil }
        return URL(string: "\(home.absoluteString)/orgs/\(organisationID)/tasks/\(taskID)")
    }

    struct Organisation {
        let id: String
        let name: String
    }

    /// The `organisations` tool answers in prose — `[uuid] Name (you are owner)`
    /// — because its real audience is a language model. Parsing it here is a
    /// little ugly, and the alternative is worse: a second, JSON-shaped
    /// endpoint on the server existing solely for this app.
    func organisations() async throws -> [Organisation] {
        let text = try await call(tool: "organisations", arguments: [:])
        return text.split(separator: "\n").compactMap { line in
            guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { return nil }
            let id = String(line[line.index(after: line.startIndex)..<close])
            var name = String(line[line.index(after: close)...]).trimmingCharacters(in: .whitespaces)
            if let paren = name.range(of: " (you are ", options: .backwards) {
                name = String(name[..<paren.lowerBound])
            }
            return Organisation(id: id, name: name)
        }
    }
}
