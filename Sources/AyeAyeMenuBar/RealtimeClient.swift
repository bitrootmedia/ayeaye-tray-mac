import Foundation

/// The push channel: ayeaye's own WebSocket, watched for one organisation.
///
/// **Desktop apps use the same WebSocket a browser does** — this is
/// `URLSessionWebSocketTask`, in the system since macOS 10.15 — and they have
/// one freedom a browser doesn't: a browser cannot set request headers on a
/// WebSocket handshake, which is the entire reason query-string tokens exist
/// as a pattern (and why the server's own docstring complains about the
/// project it came from doing exactly that, "where it lands in server logs
/// and browser history"). A native client sends `Authorization: Bearer ayc_…`
/// on the upgrade, and the token never touches a URL.
///
/// What arrives is a nudge, never content: `{"type": "task", "task_id": …}`.
/// So this reports *that something moved* and the caller refetches — one
/// authorisation path for the data, exactly as the web app does it.
///
/// **This does not replace the poll, it demotes it.** A socket can be dropped
/// by a sleeping laptop, a dead wifi router or a proxy with opinions about
/// idle connections, and the failure is silent by nature — nothing arrives,
/// which looks identical to nothing happening. The timer stays as a backstop
/// at a longer interval; between them, "instant" and "eventually correct" are
/// different promises and this keeps both.
final class RealtimeClient: NSObject, URLSessionWebSocketDelegate {
    /// Something changed in the watched organisation. Carries no detail —
    /// there is none to carry.
    var onChange: (() -> Void)?
    /// Connected or not, for anything that wants to show it.
    var onStateChange: ((Bool) -> Void)?

    private var session: URLSession!
    private var task: URLSessionWebSocketTask?
    private var organisationID: String?
    private var reconnectAttempt = 0
    private var reconnectWork: DispatchWorkItem?
    private var stopped = true

    override init() {
        super.init()
        session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
    }

    // MARK: - Lifecycle

    func connect(organisationID: String) {
        // Reconnecting to the same place while already up would drop a live
        // socket to build an identical one. Switching organisation is a
        // different matter and does need the reconnect.
        if !stopped, self.organisationID == organisationID, task != nil { return }
        disconnect()
        stopped = false
        self.organisationID = organisationID
        open()
    }

    func disconnect() {
        stopped = true
        reconnectWork?.cancel()
        reconnectWork = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        onStateChange?(false)
    }

    private func open() {
        guard let base = Settings.baseURL, let token = Settings.token, let org = organisationID,
              let url = Self.socketURL(base: base)
        else { return }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let socket = session.webSocketTask(with: request)
        task = socket
        socket.resume()

        // Sent immediately rather than from the delegate's didOpen: the task
        // queues frames until the handshake completes, so this is ordered
        // correctly either way, and one fewer callback to get wrong.
        //
        // **The watch has to be re-sent on every reconnect**, which is why it
        // lives here and not at the call site. It is server-side state
        // belonging to a socket that just died; a reconnected client that
        // forgets it is connected, healthy, and deaf.
        let watch = ["watch": ["kind": "org", "id": org]]
        if let data = try? JSONSerialization.data(withJSONObject: watch),
           let text = String(data: data, encoding: .utf8) {
            socket.send(.string(text)) { _ in }
        }
        receive(on: socket)
    }

    // MARK: - Receiving

    private func receive(on socket: URLSessionWebSocketTask) {
        socket.receive { [weak self] result in
            guard let self = self else { return }
            // A message for a socket that has since been replaced is not this
            // client's business — without this, an old socket's last gasp can
            // schedule a reconnect that fights the current one.
            guard socket === self.task else { return }
            switch result {
            case .success(let message):
                self.reconnectAttempt = 0
                self.onStateChange?(true)
                if case .string(let text) = message, Self.isChange(text) {
                    self.onChange?()
                }
                self.receive(on: socket)
            case .failure:
                self.onStateChange?(false)
                self.scheduleReconnect()
            }
        }
    }

    /// Only task events, and only well-formed ones.
    ///
    /// The socket also carries message and conversation events for anything
    /// else this account is party to, and those are none of a critical-task
    /// icon's business — refetching on every comment anybody posts would turn
    /// a status light into a busy one.
    static func isChange(_ text: String) -> Bool {
        guard let data = text.data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return event["type"] as? String == "task"
    }

    static func socketURL(base: String) -> URL? {
        var trimmed = base.trimmingCharacters(in: .whitespaces)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        // http→ws and https→wss. Same host, same port, same proxy — the
        // server mounts this under /api, which is already routed.
        if trimmed.hasPrefix("https://") {
            trimmed = "wss://" + trimmed.dropFirst("https://".count)
        } else if trimmed.hasPrefix("http://") {
            trimmed = "ws://" + trimmed.dropFirst("http://".count)
        }
        return URL(string: trimmed + "/api/ws")
    }

    // MARK: - Reconnecting

    /// Backoff, capped at a minute, with the attempt count reset by the first
    /// message that actually arrives rather than by the connection opening.
    ///
    /// Opening is not the same as working: a proxy that accepts the upgrade
    /// and then drops every frame would otherwise reset the backoff on each
    /// attempt and reconnect forever at full speed.
    private func scheduleReconnect() {
        guard !stopped else { return }
        reconnectWork?.cancel()
        reconnectAttempt += 1
        let delay = min(pow(2.0, Double(min(reconnectAttempt, 6))), 60)
        let work = DispatchWorkItem { [weak self] in self?.open() }
        reconnectWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Called when the machine wakes. A laptop that slept through the night
    /// has a socket the OS quietly killed and a backoff timer that may be
    /// minutes from firing — "the icon was stale all morning" is the failure
    /// this exists to prevent.
    func reconnectNow() {
        guard !stopped else { return }
        reconnectAttempt = 0
        reconnectWork?.cancel()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        open()
    }

    func urlSession(
        _ session: URLSession, webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        onStateChange?(true)
    }

    func urlSession(
        _ session: URLSession, webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?
    ) {
        // 4401 is the server refusing the credential. Retrying a rejected
        // token every minute forever is pointless noise in somebody's logs;
        // the poll still runs, and Settings is where this gets fixed.
        guard webSocketTask === task else { return }
        onStateChange?(false)
        if closeCode.rawValue == 4401 {
            stopped = true
            return
        }
        scheduleReconnect()
    }
}
