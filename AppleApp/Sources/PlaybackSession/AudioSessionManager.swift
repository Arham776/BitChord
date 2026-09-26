import AVFoundation

/// Background audio session (spec §3.2). iOS needs `.playback` + activation
/// for lock-screen / Control Center continuity; macOS has no AVAudioSession.
///
/// ## Why activation is awaited rather than fired and forgotten
///
/// It used to spawn a detached `setActive` and return. That raced the engine:
/// `PlaybackController.init` scheduled the activation, and
/// `startEngineIfNeeded` scheduled `engine.start()` as a *second* detached task,
/// with nothing ordering them. On iOS the engine's output is a RemoteIO audio
/// unit, and a unit that starts while the session is still inactive is never
/// pulled by the audio daemon. The ring then fills to capacity in about eight
/// seconds, `render_available` stops decoding, and the whole track downloads
/// in silence — until the deferred activation lands and the backlog bursts out.
/// That is the "shows as playing, no sound, then one stutter" report, and
/// because activation eventually won the race, the *next* track played fine.
///
/// The ordering is now explicit instead of probabilistic: no output stream is
/// built before the session is up.
///
/// ## Why the session's format is reported back
///
/// On iOS the session owns the hardware format. cpal's `default_output_config()`
/// reports the RemoteIO unit's opinion, and when the two disagree the unit can
/// fail to start without an error worth reading. Handing the engine the
/// session's own numbers makes the two agree by construction.
enum AudioSessionManager {
    /// The format the session settled on, or `nil` on macOS (where cpal's device
    /// choice stands) and on iOS when the session reported an unusable format.
    struct Format: Equatable {
        let rate: Double
        let channels: UInt32
    }

    /// Activates the playback session and reports the format it settled on.
    ///
    /// Idempotent, and cheap when the session is already what it should be. The
    /// category is set every time because it is the documented pairing to do with
    /// activation, and `setCategory` is not the expensive one.
    ///
    /// `setActive(_:)` can synchronously talk to the audio daemon, and it is
    /// documented as unsafe on the main thread — the system logs exactly that
    /// when it happens. The async form is the one that warning asks for, and it
    /// is also the correct one here for a second reason: activation blocks on
    /// whatever else holds the session, and a queue that must wait for that
    /// before it can push its first buffer is a queue that stutters on the first
    /// track after a cold start. Every caller reaches here from a detached task,
    /// so the work is never on the main thread in the first place.
    @discardableResult
    static func activate() async -> Format? {
#if os(iOS)
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [])
            try await session.setActive(true)
        } catch {
            // Worth surfacing: a session that will not activate is a session with
            // no background audio at all. Nothing actionable beyond the log.
            NSLog("[BitChord] audio session would not activate: \(error.localizedDescription)")
        }
        // `currentRoute` rather than the session: the session has no channel
        // count of its own, the output it is currently routed through does, and
        // that is the number the audio unit has to agree with. A route with no
        // outputs means nothing is plugged in — reported as "no format" so the
        // engine asks the device instead of guessing.
        let channels = session.currentRoute.outputs.first?.channels?.count ?? 0
        guard channels > 0, session.sampleRate > 0 else { return nil }
        return Format(rate: session.sampleRate, channels: UInt32(channels))
#else
        return nil
#endif
    }
}
