import Foundation
import BitChordShared

/// `URLSessionWebSocketTask` for a Listen Together party, registered as
/// `PartySocketBridge.Impl` at launch.
///
/// # Why the socket is here and not in Kotlin
///
/// Ktor's `ktor-client-websockets` is an empty shell on Darwin — the artifact
/// resolves, the dependency graph is correct, and the package contains nothing.
/// And `NSURLSessionWebSocketTask` through Kotlin/Native's ObjC interop is a losing
/// fight: `NSMutableURLRequest.setValue(_:forHTTPHeaderField:)` does not resolve
/// under any spelling, and a token has to travel in a header.
///
/// In Swift it is short, native, and gives the two things this protocol needs and
/// that the portable layer cannot have: a close code, and a platform ping answered
/// by `URLSession` without a round trip through the party.
///
/// # What this does not do
///
/// It does not parse frames, apply them, know what a party is, or decide when to
/// give up. All of that is policy and lives in `PartySession` above this line,
/// where it can be tested without a socket. The one thing decided here is the one
/// only here can be: a `bye` frame means the server ended the session *on purpose*,
/// and that is the single fact that stops the reconnect loop.
final class PartySocket: NSObject, PartySocketBridgeImpl {

    /// How often to measure the clock. Five seconds is a third of a sync tolerance.
    private static let pingInterval: TimeInterval = 5

    /// Grows because a server that is down will stay down, and hammering it does not
    /// make it come back sooner; capped because a party somebody is waiting to join
    /// should not stay unreachable for minutes after the server comes back.
    private static let maxBackoff: TimeInterval = 30

    private static let shared = PartySocket()

    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var onFrame: PartySocketBridgeFrameCallback?
    private var timer: DispatchSourceTimer?
    private var attempt = 0
    private var stopped = false

    /// Registered at launch. See `BitChordApp`.
    static func register() {
        PartySocketBridge.shared.setImpl(value: shared)
    }

    // MARK: - PartySocketBridgeImpl

    func connect(base: String, code: String, token: String, onFrame callback: PartySocketBridgeFrameCallback) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.run(base: base, code: code, token: token, onFrame: callback)
        }
    }

    func sendRaw(json: String) {
        // Dropped when the socket is not up rather than queued: a playhead report
        // describes *now*, and one that arrives late describes a position this device
        // has already left.
        guard let task, !stopped else { return }
        task.send(.string(json)) { _ in }
    }

    func stop() {
        stopped = true
        timer?.cancel()
        timer = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
        onFrame = nil
    }

    // MARK: - The loop

    private func run(base: String, code: String, token: String, onFrame callback: PartySocketBridgeFrameCallback) {
        guard let url = Self.socketURL(base: base, code: code) else { return }

        // Tokens are intentionally not in the URL: the server takes them in the
        // handshake, and a token in a path lands in every log between here and there.
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let session = URLSession(configuration: .default)
        let task = session.webSocketTask(with: request)
        self.session = session
        self.task = task
        self.onFrame = callback
        self.stopped = false
        task.resume()
        startPinging()

        let semaphore = DispatchSemaphore(value: 0)
        readLoop(task: task, semaphore: semaphore)

        // A clean read is a disconnection and worth retrying; a `bye` has already
        // stopped us and is a decision, not a fault.
        if !stopped {
            timer?.cancel()
            timer = nil
            Thread.sleep(forTimeInterval: backoff())
            attempt += 1
            if !stopped {
                run(base: base, code: code, token: token, onFrame: callback)
            }
        }
        semaphore.signal()
    }

    private func readLoop(task: URLSessionWebSocketTask, semaphore: DispatchSemaphore) {
        while !stopped {
            task.receive { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let message):
                    var text: String?
                    switch message {
                    case .string(let value): text = value
                    case .data(let value): text = String(data: value, encoding: .utf8)
                    @unknown default: text = nil
                    }
                    if let text, !text.isEmpty {
                        self.onFrame?.onFrame(json: text)
                        // A `bye` is a decision, not a disconnection. The reconnect
                        // loop stops on it: a removed listener watching a reconnect
                        // refused every time reads, to everyone in the party, as a
                        // network problem rather than as the decision it was.
                        if Self.isBye(text) {
                            self.stopped = true
                        }
                    }
                    self.readLoop(task: task, semaphore: semaphore)

                case .failure:
                    // The socket ended. Whether it ended politely or not does not
                    // change what to do, which is reconnect; the one close that *does*
                    // change it arrived as a `bye` frame first.
                    self.stopped = true
                }
            }
            return
        }
    }

    private func startPinging() {
        timer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + Self.pingInterval, repeating: Self.pingInterval)
        timer.setEventHandler { [weak self] in
            guard let self, let task = self.task, !self.stopped else { return }
            // A platform ping *and* the protocol ping, on the same interval. The
            // platform one keeps the connection measured at the transport even while
            // the socket is idle; the protocol one is what carries the clock, because
            // the server's reading has to come back attached to a local one.
            task.sendPing { _ in }
            let payload = PartyOutgoingJson.shared.ping(clientMs: Self.localNowMs())
            task.send(.string(payload)) { _ in }
        }
        timer.resume()
        self.timer = timer
    }

    private func backoff() -> TimeInterval {
        min(0.5 * pow(2, Double(min(attempt, 5))), Self.maxBackoff)
    }

    // MARK: - Clocks and addresses

    /// `ws`/`wss` from the configured `http`/`https` base, with the party's path.
    ///
    /// A party socket is a plain upgrade of the same host, so the scheme follows the
    /// server's rather than being chosen independently: a listener who pointed the
    /// app at `http://` for a LAN party server has already said they want no
    /// transport security, and silently upgrading them to `wss://` would fail to
    /// connect rather than protect them.
    static func socketURL(base: String, code: String) -> URL? {
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let ws: String
        if trimmed.hasPrefix("https://") {
            ws = "wss://" + trimmed.dropFirst("https://".count)
        } else if trimmed.hasPrefix("http://") {
            ws = "ws://" + trimmed.dropFirst("http://".count)
        } else {
            ws = "wss://" + trimmed
        }
        return URL(string: ws + "/ws/parties/" + code)
    }

    /// Whether a frame is the server ending the session on purpose.
    static func isBye(_ text: String) -> Bool {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return object["type"] as? String == "bye"
    }

    /// Monotonic, boot-relative, counts through deep sleep.
    ///
    /// `Date()` would be wrong here in a way that is not obvious: a wall clock steps
    /// when the network operator says so, when the user sets the time, and at DST —
    /// and every one of those steps lands directly in the measured offset and moves
    /// this device's playhead relative to everyone else's, mid-track.
    static func localNowMs() -> Int64 {
        Int64(ProcessInfo.processInfo.systemUptime * 1000)
    }
}
