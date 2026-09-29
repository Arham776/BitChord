#if os(iOS)
import Foundation
import ActivityKit

/// The small, Codable snapshot shared by the app and its widget extension.
/// Artwork itself lives in the shared App Group container to stay below
/// ActivityKit's content-state size limit.
struct NowPlayingActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var trackID: String
        var title: String
        var artist: String
        var isPlaying: Bool
        var position: Double
        var duration: Double
        var positionUpdatedAt: Date
        var playbackRate: Double
        var artworkPath: String?

        var progressInterval: ClosedRange<Date>? {
            guard isPlaying, duration.isFinite, duration > 0,
                  position.isFinite, playbackRate.isFinite, playbackRate > 0
            else { return nil }
            let boundedPosition = min(max(position, 0), duration)
            let start = positionUpdatedAt.addingTimeInterval(-boundedPosition / playbackRate)
            let end = start.addingTimeInterval(duration / playbackRate)
            guard end > start else { return nil }
            return start...end
        }

        var displayedPosition: Double {
            guard isPlaying, playbackRate.isFinite, playbackRate > 0 else {
                return min(max(position, 0), max(duration, 0))
            }
            return min(max(position + Date.now.timeIntervalSince(positionUpdatedAt) * playbackRate, 0), max(duration, 0))
        }
    }

    let playerID: String
}
#endif
