#if os(iOS)
import ActivityKit
import UIKit

/// Publishes a compact, interactive companion card. Native media controls stay
/// on MediaSession; this Live Activity remains visible when another app owns
/// the system Now Playing slot.
@available(iOS 16.1, *)
@MainActor
final class NowPlayingActivityController {
    nonisolated private static let appGroup = "group.com.example.bitchord"
    nonisolated private static let playerID = "bitchord-player"

    private var activity: Activity<NowPlayingActivityAttributes>?
    private var latestState: NowPlayingActivityAttributes.ContentState?
    private var publicationTask: Task<Void, Never>?
    private var endingTask: Task<Void, Never>?
    private var currentArtworkPath: String?
    private var currentArtworkTrackID: String?
    private var revision: UInt64 = 0
    private var suppressedTrackID: String?
    private var lastPositionPublication = Date.distantPast
    private var reportedDisabled = false

    private enum ActivityStatus {
        case active
        case pending
        case dismissed
        case ended
        case other
    }

    func update(
        title: String,
        artist: String,
        duration: Double,
        artworkData: Data?,
        thumbnailURL: String?,
        isPlaying: Bool,
        position: Double?,
        rate: Double
    ) {
        let trackID = thumbnailURL ?? "\(title)|\(artist)"
        let previous = latestState
        let sameTrack = previous?.trackID == trackID
        let sampleTime = Date.now
        let resolvedPosition: Double
        if let position, position.isFinite {
            resolvedPosition = max(position, 0)
        } else if sameTrack, let previous {
            resolvedPosition = previous.displayedPosition
        } else {
            resolvedPosition = 0
        }
        let state = NowPlayingActivityAttributes.ContentState(
            trackID: trackID,
            title: title,
            artist: artist,
            isPlaying: isPlaying,
            position: resolvedPosition,
            duration: duration.isFinite ? max(duration, 0) : 0,
            positionUpdatedAt: sampleTime,
            playbackRate: isPlaying && rate.isFinite ? max(rate, 0.01) : 0,
            artworkPath: artworkData == nil && sameTrack ? previous?.artworkPath : nil
        )
        if trackID != suppressedTrackID { suppressedTrackID = nil }
        latestState = state
        lastPositionPublication = sampleTime
        publish(state, artworkData: artworkData, removePreviousArtwork: !sameTrack)
    }

    /// Position is sampled frequently for the legacy control surface. Publish
    /// to ActivityKit only after a seek or every 30 seconds; the Live Activity
    /// interpolates progress locally between those anchors.
    func updatePosition(_ position: Double) {
        guard position.isFinite, var state = latestState else { return }
        let now = Date.now
        let expected = state.displayedPosition
        let seek = abs(position - expected) > 1.5
        guard seek || now.timeIntervalSince(lastPositionPublication) >= 30 else { return }
        state.position = max(position, 0)
        state.positionUpdatedAt = now
        latestState = state
        lastPositionPublication = now
        publish(state)
    }

    func updateRate(_ rate: Double, position: Double?) {
        guard var state = latestState else { return }
        let now = Date.now
        if let position, position.isFinite {
            state.position = max(position, 0)
        } else if state.isPlaying {
            state.position = state.displayedPosition
        }
        state.isPlaying = rate > 0
        state.playbackRate = rate.isFinite ? max(rate, 0) : 0
        state.positionUpdatedAt = now
        latestState = state
        lastPositionPublication = now
        publish(state)
    }

    /// Starts a missing activity when a playing track returns to the
    /// foreground. ActivityKit doesn't allow the app to start one from the
    /// background through this API.
    func requestIfPossible() {
        guard let latestState else { return }
        publish(latestState)
    }

    func end() {
        revision &+= 1
        let pendingPublication = publicationTask
        pendingPublication?.cancel()
        publicationTask = nil
        let trackID = latestState?.trackID
        latestState = nil
        let activity = resolvedActivity(forTrackID: trackID)
        self.activity = nil
        let previousEnd = endingTask
        endingTask = Task { @MainActor in
            await previousEnd?.value
            await pendingPublication?.value
            if let activity, self.isInProgress(activity.activityState) {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
            let artworkPath = self.currentArtworkPath
            self.currentArtworkPath = nil
            self.currentArtworkTrackID = nil
            if let artworkPath { await Self.removeArtwork(at: artworkPath) }
        }
    }

    private func publish(
        _ state: NowPlayingActivityAttributes.ContentState,
        artworkData: Data? = nil,
        removePreviousArtwork: Bool = false
    ) {
        revision &+= 1
        let currentRevision = revision
        let previousPublication = publicationTask
        let previousEnd = endingTask
        publicationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await previousPublication?.value
            await previousEnd?.value
            guard !Task.isCancelled else { return }
            var publishState = state
            let oldArtworkPath = self.currentArtworkPath
            var createdArtworkPath: String?
            if let artworkData {
                createdArtworkPath = await Self.storeArtwork(artworkData)
                self.currentArtworkPath = createdArtworkPath
                self.currentArtworkTrackID = state.trackID
                publishState.artworkPath = self.currentArtworkPath
            } else if removePreviousArtwork {
                self.currentArtworkPath = nil
                self.currentArtworkTrackID = nil
                publishState.artworkPath = nil
            } else if self.currentArtworkTrackID == state.trackID {
                publishState.artworkPath = self.currentArtworkPath
            }
            guard !Task.isCancelled, self.revision == currentRevision else {
                if let createdArtworkPath, createdArtworkPath != self.currentArtworkPath {
                    await Self.removeArtwork(at: createdArtworkPath)
                }
                if let oldArtworkPath, oldArtworkPath != self.currentArtworkPath {
                    await Self.removeArtwork(at: oldArtworkPath)
                }
                return
            }
            self.latestState = publishState
            await self.apply(publishState)
            if let oldArtworkPath, oldArtworkPath != publishState.artworkPath {
                await Self.removeArtwork(at: oldArtworkPath)
            }
        }
    }

    private func apply(_ state: NowPlayingActivityAttributes.ContentState) async {
        if let activity = resolvedActivity() {
            switch activityStatus(activity.activityState) {
            case .active:
                self.activity = activity
                await activity.update(ActivityContent(state: state, staleDate: nil))
                return
            case .pending:
                self.activity = activity
                return
            case .dismissed:
                if activity.content.state.trackID == state.trackID {
                    suppressedTrackID = state.trackID
                }
                self.activity = nil
            case .ended:
                if activity.content.state.trackID == state.trackID {
                    suppressedTrackID = state.trackID
                }
                self.activity = nil
            case .other:
                self.activity = nil
            }
        }

        guard state.isPlaying,
              state.trackID != suppressedTrackID,
              UIApplication.shared.applicationState == .active,
              ActivityAuthorizationInfo().areActivitiesEnabled
        else {
            if !ActivityAuthorizationInfo().areActivitiesEnabled, !reportedDisabled {
                reportedDisabled = true
                NSLog("[BitChord] Live Activities are disabled for this app")
            }
            return
        }

        do {
            activity = try Activity.request(
                attributes: NowPlayingActivityAttributes(playerID: Self.playerID),
                content: ActivityContent(state: state, staleDate: nil),
                pushType: nil
            )
            reportedDisabled = false
        } catch {
            NSLog("[BitChord] Live Activity could not start: \(error.localizedDescription)")
        }
    }

    private func resolvedActivity(forTrackID trackID: String? = nil) -> Activity<NowPlayingActivityAttributes>? {
        if let activity { return activity }
        let matching = Activity<NowPlayingActivityAttributes>.activities.filter {
            $0.attributes.playerID == Self.playerID
        }
        let existing = matching.first {
            isInProgress($0.activityState)
        } ?? matching.first {
            guard let trackID else { return false }
            return $0.content.state.trackID == trackID
        }
        activity = existing
        return existing
    }

    private func isInProgress(_ state: ActivityState) -> Bool {
        let status = activityStatus(state)
        return status == .active || status == .pending
    }

    private func activityStatus(_ state: ActivityState) -> ActivityStatus {
        if state == .active || state == .stale { return .active }
        if #available(iOS 26.0, *), state == .pending { return .pending }
        if state == .dismissed { return .dismissed }
        if state == .ended { return .ended }
        return .other
    }

    private nonisolated static func storeArtwork(_ data: Data) async -> String? {
        await Task.detached(priority: .utility) {
            guard let container = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: appGroup
            ) else { return nil }
            let url = container.appendingPathComponent("live-activity-artwork-\(UUID().uuidString).jpg")
            do {
                try data.write(to: url, options: .atomic)
                return url.path
            } catch {
                NSLog("[BitChord] Live Activity artwork write failed: \(error.localizedDescription)")
                return nil
            }
        }.value
    }

    private nonisolated static func removeArtwork(at path: String) async {
        await Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(atPath: path)
        }.value
    }
}
#endif
