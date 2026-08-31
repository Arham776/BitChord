import Foundation
import BitChordShared

/// Discord user gateway — IDENTIFY + OP 3 presence, heartbeat from HELLO.
final class DiscordGateway: NSObject, URLSessionWebSocketDelegate {
    static let shared = DiscordGateway()
    private var task: URLSessionWebSocketTask?
    private var heartbeat: Timer?
    private var seq: Int64 = 0
    private var token: String?

    func connect(token: String) {
        disconnect()
        self.token = token
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        let url = URL(string: "wss://gateway.discord.gg/?v=9&encoding=json")!
        let t = session.webSocketTask(with: url)
        task = t
        t.resume()
        listen()
    }

    func disconnect() {
        heartbeat?.invalidate()
        heartbeat = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    func updatePresence(title: String, artist: String, album: String?, positionMs: Int64, durationMs: Int64, speed: Float, videoId: String?) {
        guard token != nil, task != nil else { return }
        let payload = DiscordBridge.shared.presencePayload(
            title: title, artist: artist, album: album,
            positionMs: positionMs, durationMs: durationMs, speed: speed, videoId: videoId
        )
        send(payload)
    }

    private func listen() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure:
                break
            case .success(let message):
                if case .string(let text) = message {
                    self.handle(text)
                }
                self.listen()
            }
        }
    }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let s = obj["s"] as? Int { seq = Swift.Int64(s) }
        let op = obj["op"] as? Int
        if op == 10, let d = obj["d"] as? [String: Any], let interval = d["heartbeat_interval"] as? Double {
            startHeartbeat(interval / 1000)
            if let token {
                send(DiscordBridge.shared.identifyPayload(token: token))
            }
        } else if op == 1 {
            send(DiscordBridge.shared.heartbeatPayload(seq: seq))
        }
    }

    private func startHeartbeat(_ seconds: Double) {
        heartbeat?.invalidate()
        heartbeat = Timer.scheduledTimer(withTimeInterval: max(5, seconds), repeats: true) { [weak self] _ in
            guard let self else { return }
            self.send(DiscordBridge.shared.heartbeatPayload(seq: self.seq))
        }
    }

    private func send(_ text: String) {
        task?.send(.string(text)) { _ in }
    }
}
