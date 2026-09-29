#if os(iOS)
import ActivityKit

/// Migration only: dismiss cards left by the previous version. Playback uses
/// native Now Playing; this app never requests an ActivityKit activity.
enum NowPlayingActivityController {
    static func endLegacyActivities() {
        Task {
            for activity in Activity<NowPlayingActivityAttributes>.activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }
}
#endif
