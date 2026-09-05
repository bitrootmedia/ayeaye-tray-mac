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
/// transport.
///
/// This talks to `/mcp` rather than to the REST API for a reason worth
/// keeping written down: the REST API authenticates with a SuperTokens
/// session cookie, which a native app has no way to obtain without
/// embedding a browser and a sign-in flow. `/mcp` accepts a personal access
/// token — the ones minted on the account screen, scoped read or write,
/// revocable from the same screen — so this app needs no server-side change
/// at all to exist.
///
/// It is also **stateless** on purpose (see the server's own notes): there
/// is no `initialize` handshake to do and no session id to carry, so one
/// POST is a complete interaction. That is the whole reason this file is
/// eighty lines rather than a protocol implementation.
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
            // The server's own MCP SDK loses a refusal's message on the way
            // out and sends the bare wrapper "Error executing tool <name>",
            // with no reason attached — a known issue on that side, not
            // something this client can recover. Relaying it verbatim would
            // put a string in front of somebody that tells them nothing at
            // all, so it is replaced with the thing that is actually worth
            // checking. Any refusal that *does* carry a message keeps it.
            if text.isEmpty || text.hasPrefix("Error executing tool") {
                throw MCPError.rpc(
                    "The server refused it. If your token is read-only, make a write one.")
            }
            throw MCPError.rpc(text)
        }
        return text
    }

    // MARK: - The two calls this app actually makes

    /// Returns the new task's id, so it can be opened afterwards.
    ///
    /// `create_task` answers `Created [<uuid>] <title>` — prose, because its
    /// real audience is a language model. Same parse-the-sentence bargain as
    /// `organisations` below: mildly ugly here, and much better than a
    /// second endpoint on the server existing only for this app.
    @discardableResult
    func createTask(title: String, organisationID: String) async throws -> String? {
        let answer = try await call(tool: "create_task", arguments: [
            "organisation_id": organisationID,
            "title": title,
        ])
        return Self.firstBracketedID(in: answer)
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

    /// Where a task lives in the web app. The SPA's own route, which is the
    /// contract this relies on — `orgs/:orgId/tasks/:taskId`.
    static func webURL(base: String, organisationID: String, taskID: String) -> URL? {
        var trimmed = base.trimmingCharacters(in: .whitespaces)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        return URL(string: "\(trimmed)/orgs/\(organisationID)/tasks/\(taskID)")
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
