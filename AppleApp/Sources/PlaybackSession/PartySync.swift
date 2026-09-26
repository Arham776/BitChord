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
/// # What it does on each tick
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
/// # The two quiet rules
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
    private static let intentQuietMs: Int64 = 4_500

    private let controller: PlaybackController
    private let session = PartySession()
    private let judge = PartyDriftJudge()

    /// The offset from the party server's clock, measured from pongs.
    private let clock = ServerClock()

    /// The video id this device is currently playing, so a track change is a
    /// comparison rather than a guess.
    private var loadedVideoId: String?

    /// When this device last pressed something, and until when the party is not told.
    private var localIntentAtMs: Int64?

    private var task: Task<Void, Never>?
    private var socketTask: Task<Void, Never>?

    private(set) var isActive = false

    /// The party, for the screen to read.
    var state: PartyState { session.current }

    init(controller: PlaybackController) {
        self.controller = controller
    }

    // MARK: - Lifecycle

    func start(base: String, code: String, token: String) {
        guard !isActive else { return }
        isActive = true
        session.begin(serverBase: base, code: code)
        judge.reset()
        loadedVideoId = nil
        localIntentAtMs = nil

        socketTask = Task { [weak self] in
            try? await PartySocketBridge.shared.connect(base: base, code: code, token: token) { json in
                // Synchronous by contract: the socket already runs off the main
                // thread, so this is where the hop belongs rather than a `Task` per
                // frame in the bridge.
                guard let frame = PartyFrameCodec.shared.decode(text: json) else { return }
                Task { @MainActor in self?.ingest(frame) }
            }
        }

        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.tickMs * 1_000_000)
                guard let self else { return }
                await MainActor.run { self.reconcile() }
            }
        }
    }

    func stop() {
        guard isActive else { return }
        isActive = false
        task?.cancel()
        task = nil
        socketTask?.cancel()
        socketTask = nil
        PartySocketBridge.shared.stop()
        session.reset()
        judge.reset()
        loadedVideoId = nil
        localIntentAtMs = nil
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

    // MARK: - Frames

    private func ingest(_ frame: PartyFrame) {
        // A pong is the only frame that measures anything, and it is the only thing
        // that can turn the party server's clock into this device's. Without it the
        // offset is never known and every corrected position is a guess.
        if let pong = frame as? PartyFramePong {
            clock.record(
                sentAtLocalMs: pong.clientMs,
                serverMs: pong.serverMs,
                receivedAtLocalMs: PartySocket.localNowMs()
            )
        }
        let applied = session.apply(frame: frame)

        // The state machine noticed a queue it does not hold. Asking for it is the
        // only refetch trigger, and it is deliberately not fired on every state.
        if applied is PartySessionAppliedQueue {
            session.queueRefetchSent()
        }
        if applied is PartySessionAppliedLeft {
            stop()
        }
        reconcile()
    }

    // MARK: - The tick

    private func reconcile() {
        let state = session.current
        guard state.inParty else { return }
        let playback = state.playback

        // 1. The track. Nothing else means anything until the right song is loaded.
        if let track = playback.track, track.videoId != loadedVideoId {
            load(track)
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
        let partyPosition = correctedPosition(of: playback, nowMs: now)
        let decision = judge.onTick(
            partyPositionMs: partyPosition,
            localPositionMs: Int64(controller.position * 1000),
            localIsPlaying: controller.isPlaying,
            partyIsPlaying: playback.isPlaying,
            nowMs: now
        )
        // A Kotlin sealed interface is a Swift protocol, so this is a cast rather
        // than a switch over cases.
        if let seek = decision as? PartyDriftJudgeDecisionSeek {
            controller.seek(to: Double(seek.seekToMs) / 1000)
        } else if decision is PartyDriftJudgeDecisionPause {
            if controller.isPlaying { controller.togglePlayPause() }
        }

        // Tell the party where this device is — but only if this device is allowed to
        // decide, and only if it has not just been overruled by a press of its own.
        if state.canControl, !isQuiet(nowMs: now) {
            publish(positionMs: Int64(controller.position * 1000), isPlaying: controller.isPlaying)
        }
    }

    /// Where the party is, on this device's clock.
    ///
    /// The state's position is *not* current — it is the position at the instant the
    /// server sent it, which may have been 300 ms ago. Correcting it by the elapsed
    /// time since is the entire sync mechanism, and it is why a frame delayed by a
    /// slow network still lands in the right place instead of a beat behind.
    private func correctedPosition(of playback: PartyPlayback, nowMs: Int64) -> Int64 {
        guard playback.isPlaying else { return playback.positionMs }
        // No pong has landed yet means no offset and no honest answer, and the
        // position is held at zero rather than played: a party that is briefly wrong
        // is better than one that is confidently wrong.
        return clock.positionFor(
            positionMs: playback.positionMs,
            trueAtServerMs: playback.anchorMs,
            localNowMs: nowMs
        )
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
        let json = PartyOutgoingJson.shared.report(positionMs: positionMs, isPlaying: isPlaying)
        PartySocketBridge.shared.sendRaw(json: json)
    }
}
