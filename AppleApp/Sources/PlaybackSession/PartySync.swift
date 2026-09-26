import Foundation
import BitChordShared

/// Binds a party to this device's player.
///
/// # The shape, and why
///
/// Upstream puts this in the playback service, below a line it draws deliberately:
/// everything *above* "where should this device be, right now, on its own clock" is
/// testable, and everything below it is not. Same split here — the clock, the drift
/// policy and the state machine are shared Kotlin with tests, and this file is the
/// part that cannot have any: it touches a player.
///
/// ## It is a reader, and that is the whole design
///
/// The port had this owning a `PartySession`, a socket and a clock of its own, while
/// `PartyCoordinator` owned a second set of all three. Only one socket can exist, so
/// whichever was started last silently won and the other one's state was fiction.
///
/// Now [PartyCoordinator] owns the only session, the only socket and the only clock,
/// and this reads it. There is no state here that is not either the party's or the
/// player's, which is what makes it safe for the screen and the player to both be
/// looking at the same thing at once.
///
/// ## What it does on each tick
///
/// Three things, in an order that matters:
///
///  1. **Follow the track.** If the party moved on, load what it moved to. This is
///     not a judgement call and happens first, because there is no position to align
///     until there is the right song.
///  2. **Follow the transport.** Playing or paused, with no strike count and no
///     cooldown — a pause is not audible the way a seek is.
///  3. **Follow the playhead.** Only when the gap is over the alignment tolerance,
///     for two consecutive ticks, and no more than once per cooldown. A seek is
///     audible; doing this well means mostly *not* doing it.
///
/// ## The two quiet rules
///
/// **A local press wins for a moment.** A listener who presses pause has said
/// something, and the next state frame — which still says *playing*, because the
/// control has not reached the server yet — must not undo it. Without this the press
/// appears not to work, which is worse than a momentary disagreement.
///
/// **A device that cannot control does not publish.** Otherwise a listener's own
/// playhead becomes the party's, and a party of five becomes whichever device's
/// network was worst.
@MainActor
final class PartySync {

    /// How often the party is reconciled with the player. Upstream's 700 ms: fast
    /// enough that a correction lands before it is noticed, slow enough that a
    /// correction is never the *cause* of the next one.
    private static let tickMs: UInt64 = 700

    /// How long this device's own press keeps it out of the party's way.
    ///
    /// Long enough to cover the round trip the control takes to reach the server and
    /// the state frame to come back, and not much longer — past that a press really
    /// has been overruled and continuing to hold out helps nobody.
    private static let intentQuietMs: Int64 = 4_500

    private let controller: PlaybackController
    private let judge = PartyDriftJudge()

    /// The video id this device is currently playing, so a track change is a
    /// comparison rather than a guess.
    private var loadedVideoId: String?

    /// When this device last pressed something, and until when the party is not told.
    private var localIntentAtMs: Int64?

    private var task: Task<Void, Never>?

    private(set) var isActive = false

    /// Where the party is right now, on this device's clock, or nil with no clock.
    ///
    /// The screen's "Now playing" position reads this rather than the last frame's,
    /// because *that is the feature*: between server updates each device advances the
    /// same anchored position on its own clock, and two devices side by side should
    /// show the same number. A value that only moved when a frame arrived would
    /// prove nothing.
    var partyPositionMs: Int64? {
        let playback = PartyCoordinator.shared.session.current.playback
        guard PartyCoordinator.shared.session.current.clockSynced else { return nil }
        return PartyCoordinator.shared.session.correctedPosition(
            playback: playback,
            localNowMs: PartySocket.localNowMs()
        )
    }

    init(controller: PlaybackController) {
        self.controller = controller
    }

    // MARK: - Lifecycle

    /// Follow the party, for as long as this device is in one.
    ///
    /// Idempotent, and driven by membership rather than by a screen appearing: a
    /// party's lifetime is the listener's, not a view's, so nothing here is tied to
    /// the Listen Together screen being open.
    func start() {
        guard !isActive else { return }
        isActive = true
        judge.reset()
        loadedVideoId = nil
        localIntentAtMs = nil
        reconcile()
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.tickMs * 1_000_000)
                guard let self else { return }
                self.reconcile()
            }
        }
    }

    func stop() {
        guard isActive else { return }
        isActive = false
        task?.cancel()
        task = nil
        judge.reset()
        loadedVideoId = nil
        localIntentAtMs = nil
    }

    /// Start or stop to match the party, which is what the app asks for when the
    /// screen appears and when a frame says the session ended.
    func syncWithMembership() {
        if PartyCoordinator.shared.membership != nil { start() } else { stop() }
    }

    // MARK: - A local press

    /// Called when this device's own controls are used.
    ///
    /// Records the press so the party is not told about it for a moment — the frame
    /// already in flight still describes the old transport, and acting on it would
    /// make the press look like it did nothing.
    func onLocalIntent() {
        localIntentAtMs = PartySocket.localNowMs()
    }

    // MARK: - The tick

    private func reconcile() {
        let state = PartyCoordinator.shared.session.current
        guard state.inParty else {
            // Out of a party, this device is on its own again. Anything it was
            // playing is its own business, not the party's.
            stop()
            return
        }
        let playback = state.playback

        // 1. The track. Nothing else means anything until the right song is loaded.
        if let track = playback.track, track.videoId != loadedVideoId {
            // Loading is following, not the listener asking for something.
            controller.withLocalIntentSuppressed { load(track) }
            return
        }
        // A party with no track at all, and something of ours playing, means the
        // party is empty rather than that we should carry on alone.
        if playback.track == nil, loadedVideoId != nil {
            controller.pauseForBackground()
            loadedVideoId = nil
            return
        }

        let now = PartySocket.localNowMs()

        // 2 and 3 together: the judge owns the transport and the playhead, and
        // answering it is the whole of "following".
        let partyPosition = partyPositionMs ?? playback.positionMs
        let decision = judge.onTick(
            partyPositionMs: partyPosition,
            localPositionMs: Int64(controller.position * 1000),
            localIsPlaying: controller.isPlaying,
            partyIsPlaying: playback.isPlaying,
            nowMs: now
        )
        // A Kotlin sealed interface is a Swift protocol, so this is a cast rather
        // than a switch over cases.
        //
        // Every correction is wrapped in the controller's own suppression, so that
        // moving this device towards the party is never mistaken for the listener
        // having pressed something. Without it the binding would hear itself and
        // conclude it had been overruled, and would stop correcting entirely.
        if let seek = decision as? PartyDriftJudgeDecisionSeek {
            controller.withLocalIntentSuppressed {
                controller.seek(to: Double(seek.seekToMs) / 1000)
            }
        } else if decision is PartyDriftJudgeDecisionPause, controller.isPlaying {
            controller.withLocalIntentSuppressed {
                controller.togglePlayPause()
            }
        }

        // Tell the party where this device is — but only if this device is allowed to
        // decide, and only if it has not just been overruled by a press of its own.
        if state.canControl, !isQuiet(nowMs: now) {
            publish(positionMs: Int64(controller.position * 1000), isPlaying: controller.isPlaying)
        }
    }

    /// Whether this device's own press still outranks the party.
    private func isQuiet(nowMs: Int64) -> Bool {
        guard let at = localIntentAtMs else { return false }
        if nowMs - at > Self.intentQuietMs {
            localIntentAtMs = nil
            return false
        }
        return true
    }

    // MARK: - Loading and publishing

    private func load(_ track: PartyTrack) {
        // A party shares *which* track and where the playhead is — not how this device
        // gets the audio. The entry goes through this device's own source resolution
        // like any other, so a listener on a different source hears the same song.
        let entry = QueueEntry(
            id: track.videoId,
            title: track.title,
            artist: track.artist,
            source: "yt:" + track.videoId,
            thumbnailUrl: track.thumbnailUrl,
            durationText: nil,
            albumName: nil,
            artworkData: nil,
            isLocal: false,
            fromAutoplay: track.fromAutoplay
        )
        loadedVideoId = track.videoId
        controller.play([entry], at: 0)
    }

    private var lastPublishedMs: Int64 = -1

    private func publish(positionMs: Int64, isPlaying: Bool) {
        // One report per second rather than one per tick. The server only logs drift
        // from it, so a finer resolution buys nothing and costs a frame on somebody's
        // metered connection every 700 ms.
        if lastPublishedMs >= 0, abs(positionMs - lastPublishedMs) < 1_000, isPlaying {
            return
        }
        lastPublishedMs = positionMs
        PartyCoordinator.shared.report(positionMs: positionMs, isPlaying: isPlaying)
    }
}
