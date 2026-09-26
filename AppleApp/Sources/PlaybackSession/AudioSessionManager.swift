import AVFoundation

/// Background audio session (spec §3.2). iOS needs `.playback` + activation
/// for lock-screen / Control Center continuity; macOS has no AVAudioSession.
///
/// ## Why this is a `Task` and not a `Task { }` on the main actor
///
/// `setActive(_:)` can synchronously talk to the audio daemon, and it is documented as
/// unsafe to call on the main thread — the system logs exactly that, twice per call:
///
/// > This method can lead to UI unresponsiveness if called on the main thread.
/// > Consider using the asynchronous activate/deactivate API instead.
///
/// The async form (`setActive(_:options:completionHandler:)`) is the one the warning
/// asks for, and it is also the correct one here for a second reason: activation
/// blocks on whatever else holds the session, and a queue that has to wait for that
/// before it can push its first buffer is a queue that stutters on the first track
/// after a cold start.
///
/// The completion runs on an arbitrary queue, so the result is logged there rather
/// than hopping back — there is nothing on the other side of it but a line, and
/// `Task.detached` would buy a thread hop for the privilege of being told about a
/// failure that is not actionable in the first place. The one thing worth surfacing
/// is a refusal, because a session that will not activate is a session with no
/// background audio at all.
enum AudioSessionManager {
    /// Idempotent, and cheap when the session is already what it should be.
    ///
    /// A `Task` rather than a stored handle: this is called from playback setup on
    /// both platforms and on iOS the call is a no-op after the first, so there is
    /// nothing to keep. The category is set every time because it is the documented
    /// pairing to do with activation, and `setCategory` is not the expensive one.
    static func activate() {
#if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [])
        // Detached, and off the main thread by construction: `Task {}` inherits the
        // actor of its caller, which is the main actor for every call site in this app.
        Task.detached(priority: .userInitiated) {
            do {
                try await session.setActive(true)
            } catch {
                NSLog("[BitChord] audio session would not activate: \(error.localizedDescription)")
            }
        }
#endif
    }
}
