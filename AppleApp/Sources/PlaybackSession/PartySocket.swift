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
/// only here can: a `bye` frame means the server ended the session *on purpose*,
/// and that is the single fact that stops the reconnect loop.
///
/// # Why the loop is written with `async` rather than a callback chain
///
/// Because the previous version of it did not work, and the way it failed is worth
/// recording. Its read loop registered a `receive` callback and returned
/// immediately, and its caller — which assumed the read loop *blocked* until the
/// socket ended — therefore read that return as "the socket is finished". The
/// consequence was a reconnect every half second: the ping timer, scheduled five
/// seconds out, was cancelled before it could ever fire, so the party's clock was
/// never measured and the party never synchronised; and the backoff, which is
/// supposed to be the thing that stops a dead server being hammered, was slept
/// through on the way into the next attempt rather than before it. It compiled, it
/// linked, and it reconnected in a loop for as long as the app was open.
///
/// The shape here is the one that cannot have that bug: `await readLoop` is a
/// suspension that only returns when the socket really has ended, and the backoff
/// happens after it, before the next attempt, and is cancellable.
final class PartySocket: NSObject, PartySocketBridgeImpl, @unchecked Sendable {

    /// How often to measure the clock. Five seconds is a third of a sync tolerance.
    private static let pingIntervalSeconds: Double = 5

    /// Grows because a server that is down will stay down, and hammering it does not
    /// make it come back sooner; capped because a party somebody is waiting to join
    /// should not stay unreachable for minutes after the server comes back.
    private static let maxBackoffSeconds: Double = 30

    private static let shared = PartySocket()

    /// Guards the fields below.
    ///
    /// Not a hot path — a control, a report and a connect or two a second at most —
    /// so a lock is the honest answer, and it is the only thing that makes
    /// `@unchecked Sendable` true rather than aspirational. `sendRaw` and `stop` are
    /// called from whichever thread the caller happens to be on, including Kotlin's.
    private let lock = NSLock()

    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var onFrame: PartySocketBridgeFrameCallback?
    private var loop: Task<Void, Never>?
    private var attempt = 0
    private var stopped = false

    /// Registered at launch. See `BitChordApp`.
    static func register() {
        PartySocketBridge.shared.setImpl(value: shared)
    }

    // MARK: - PartySocketBridgeImpl

    func connect(base: String, code: String, token: String, onFrame callback: PartySocketBridgeFrameCallback) {
        lock.withLock {
            loop?.cancel()
            stopped = false
            attempt = 0
        }
        loop = Task.detached(priority: .userInitiated) { [weak self] in
            await self?.run(base: base, code: code, token: token, onFrame: callback)
        }
    }

    func sendRaw(json: String) {
        let live = lock.withLock { stopped ? nil : task }
        // Dropped when the socket is not up rather than queued: a playhead report
        // describes *now*, and one that arrives late describes a position this device
        // has already left.
        live?.send(.string(json)) { _ in }
    }

    func stop() {
        let (live, session, loop) = lock.withLock { () -> (URLSessionWebSocketTask?, URLSession?, Task<Void, Never>?) in
            stopped = true
            let taken = (task, self.session, self.loop)
            task = nil
            self.session = nil
            self.onFrame = nil
            self.loop = nil
            return taken
        }

        // Cancelling the loop is what actually unblocks the read: a cancelled
        // `receive` throws, and that is the only way out of an await that would
        // otherwise sit there until the server's idle timeout.
        loop?.cancel()
        live?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
    }

    // MARK: - The loop

    private func run(base: String, code: String, token: String, onFrame callback: PartySocketBridgeFrameCallback) async {
        while !isStopped {
            guard let url = Self.socketURL(base: base, code: code) else { return }
            // Tokens are intentionally not in the URL: the server takes them in the
            // handshake, and a token in a path lands in every log between here and there.
            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            let session = URLSession(configuration: .default)
            let task = session.webSocketTask(with: request)

            let abandoned = lock.withLock { () -> Bool in
                guard !stopped else { return true }
                self.session = session
                self.task = task
                self.onFrame = callback
                // A connection that was accepted resets the backoff. Carrying the count
                // across a successful connect is what turns one blip into a minute of
                // slow reconnects for a party that is otherwise fine.
                self.attempt = 0
                return false
            }
            if abandoned {
                session.invalidateAndCancel()
                return
            }

            task.resume()

            // Reading and pinging run together because each is a wait the other would
            // otherwise sit behind: the read only returns when the socket ends, and a
            // ping loop that only ran between reads would never run at all. Whichever
            // finishes first ends the pair.
            // `keepGoing` is "this is still a socket we want", which is the negation
            // of `isStopped` — and also false once `self` has gone, because a loop
            // with nobody to report to has nothing left to do.
            await withTaskGroup(of: Void.self) { group in
                let keepGoing: @Sendable () -> Bool = { [weak self] in self.map { !$0.isStopped } ?? false }
                group.addTask { await Self.read(task: task, onFrame: callback, keepGoing: keepGoing) }
                group.addTask { await Self.ping(task: task, keepGoing: keepGoing) }
                await group.next()
                group.cancelAll()
            }

            task.cancel(with: .goingAway, reason: nil)
            session.invalidateAndCancel()
            let wait = lock.withLock { () -> Duration in
                if self.task === task {
                    self.task = nil
                    self.session = nil
                }
                attempt += 1
                return backoff()
            }

            // A clean read is a disconnection and worth retrying; a `bye` has already
            // stopped us and is a decision, not a fault. A cancelled sleep means
            // `stop()` was called, and the loop condition ends it.
            if isStopped { return }
            try? await Task.sleep(for: wait)
        }
    }

    private var isStopped: Bool {
        lock.withLock { stopped }
    }

    /// Read until the socket ends, reporting each frame.
    ///
    /// A `bye` is a decision, not a disconnection, and stopping here is the whole
    /// point of noticing it: a removed listener watching a reconnect refused every
    /// time reads, to everyone in the party, as a network problem rather than as the
    /// decision it was.
    private static func read(
        task: URLSessionWebSocketTask,
        onFrame: PartySocketBridgeFrameCallback,
        keepGoing: @Sendable () -> Bool,
    ) async {
        while keepGoing() && !Task.isCancelled {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await task.receive()
            } catch {
                // The socket ended. Whether it ended politely does not change what to
                // do, which is reconnect; the one close that *does* change it arrived
                // as a `bye` frame first.
                return
            }
            let text: String?
            switch message {
            case .string(let value): text = value
            case .data(let value): text = String(data: value, encoding: .utf8)
            @unknown default: text = nil
            }
            guard let text, !text.isEmpty else { continue }
            onFrame.onFrame(json: text)
            if isBye(text) { return }
        }
    }

    /// Keep the connection measured at both layers.
    ///
    /// Two pings, deliberately, because they answer different questions. The platform
    /// one keeps the transport itself alive and is answered by `URLSession` without
    /// travelling through the party at all; the protocol one is the only thing that
    /// can turn the server's clock into this device's, because the server's reading
    /// has to come back attached to a local one.
    ///
    /// The first one goes out immediately rather than after an interval. The clock is
    /// the thing everything else waits on — until it is measured, every position is a
    /// guess — and a party that spends its first five seconds unsynchronised is five
    /// seconds of every member hearing the wrong bar.
    private static func ping(task: URLSessionWebSocketTask, keepGoing: @Sendable () -> Bool) async {
        while keepGoing() && !Task.isCancelled {
            task.sendPing { _ in }
            task.send(.string(PartyOutgoingJson.shared.ping(clientMs: localNowMs()))) { _ in }
            try? await Task.sleep(for: .seconds(pingIntervalSeconds))
        }
    }

    private func backoff() -> Duration {
        .milliseconds(Int(min(0.5 * pow(2.0, Double(attempt)), Self.maxBackoffSeconds) * 1000))
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
