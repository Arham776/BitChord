import Foundation

/// In-memory ring of recent resolve / upgrade / source decisions, for the
/// song-menu "Debug log" action. Not a port of Android `TrackLog` — last N
/// lines only, no persistence.
final class PlaybackDebugLog: @unchecked Sendable {
    /// The one log.
    ///
    /// Shared rather than one per controller because two places need to write to it
    /// and only one of them has the controller: a resolution failure is reported by
    /// `resolveYouTube`, which is static, and the per-client reasons it carries are
    /// the most useful thing this log ever holds. Two logs would mean the reasons
    /// somewhere nobody looks.
    static let shared = PlaybackDebugLog()

    private let lock = NSLock()
    private var lines: [String] = []
    private let capacity: Int

    init(capacity: Int = 80) {
        self.capacity = capacity
    }

    func record(_ message: String, about mediaId: String? = nil) {
        let stamp = Self.clock.string(from: Date())
        let line = if let mediaId {
            "\(stamp)  \(mediaId)  \(message)"
        } else {
            "\(stamp)  \(message)"
        }
        lock.lock()
        lines.append(line)
        if lines.count > capacity {
            lines.removeFirst(lines.count - capacity)
        }
        lock.unlock()
    }

    func dump() -> String {
        lock.lock(); defer { lock.unlock() }
        return lines.joined(separator: "\n")
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
}
