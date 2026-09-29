import AVFoundation
import BitChordShared

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
    private static let sessionQueue = DispatchQueue(label: "com.example.bitchord.audio-session")
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
    static func activate(preferredSampleRate: Double? = nil) async -> Format? {
        await withCheckedContinuation { continuation in
            sessionQueue.async {
                continuation.resume(returning: activateSynchronously(preferredSampleRate: preferredSampleRate))
            }
        }
    }

    private static func activateSynchronously(preferredSampleRate: Double?) -> Format? {
#if os(iOS)
        let session = AVAudioSession.sharedInstance()
        do {
            // Playback is mixable by default so starting BitChord does not stop
            // another music app. Deactivation on pause is still necessary to
            // release the output session promptly. The setting permits an
            // exclusive session when the listener explicitly wants one.
            let mixing = PlatformSettings.shared.getBoolean(
                key: "mix_with_other_audio", default: true
            )
            // `.playback` already routes to AirPlay and Bluetooth A2DP, and
            // iOS 27 rejects the call (OSStatus -50) if those options are set
            // on it. `allowAirPlay` is only valid for play-and-record. A
            // rejected category is why Now Playing then answered
            // `internalFailure` to every claim.
            var options: AVAudioSession.CategoryOptions = []
            if mixing {
                options.insert(.mixWithOthers)
            }
            if session.category != .playback || session.mode != .default || session.categoryOptions != options {
                try session.setCategory(.playback, mode: .default, options: options)
            }
            if PlatformSettings.shared.getBoolean(
                key: "match_source_sample_rate", default: true
            ), let preferredSampleRate, preferredSampleRate > 0 {
                // A preference is a request, not a promise: read sampleRate
                // after activation and give that actual value to the engine.
                do {
                    try session.setPreferredSampleRate(preferredSampleRate)
                } catch {
                    NSLog("[BitChord] preferred output rate \(preferredSampleRate) Hz was not accepted: \(error.localizedDescription)")
                }
            }
            try session.setActive(true)
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
        //
        // Note: on iOS built-in speakers and standard headphones,
        // `portDescription.channels` is nil (it is only non-nil for
        // multi-channel USB devices). Use `session.outputNumberOfChannels`
        // first, falling back to 2 channels.
        let hardwareChannels = session.outputNumberOfChannels
        let routeChannels = session.currentRoute.outputs.first?.channels?.count ?? 0
        let channels = hardwareChannels > 0
            ? hardwareChannels
            : (routeChannels > 0 ? routeChannels : (session.currentRoute.outputs.isEmpty ? 0 : 2))

        // One line that separates "the mix was silent" from "the mix never
        // reached the speaker". `outputVolume` is the *system* volume for this
        // session: a zero here silences a perfectly healthy engine.
        //
        // The options and other-audio flags help diagnose interruptions that
        // happen outside the engine. An interruption is a gap the engine's
        // counters cannot show: the output ring can be full and the callback
        // punctual while the system takes the audio away underneath both.
        let output = session.currentRoute.outputs.first
        NSLog("[BitChord] audio session %@",
              "category=\(session.category.rawValue) mode=\(session.mode.rawValue) "
              + "options=\(session.categoryOptions.rawValue) volume=\(session.outputVolume) "
              + "route=\(output.map { "\($0.portType.rawValue)/\($0.portName)" } ?? "none") "
              + "rate=\(session.sampleRate) ch=\(channels) "
              + "otherAudio=\(session.isOtherAudioPlaying) "
              + "shouldSilenceSecondary=\(session.secondaryAudioShouldBeSilencedHint)")

        guard channels > 0, session.sampleRate > 0 else { return nil }
        return Format(rate: session.sampleRate, channels: UInt32(channels))
#else
        return nil
#endif
    }

    /// Deactivates the playback session and notifies other audio apps that
    /// they may resume or take back exclusive hardware access.
    static func deactivate() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            sessionQueue.async {
                deactivateSynchronously()
                continuation.resume()
            }
        }
    }

    private static func deactivateSynchronously() {
#if os(iOS)
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
            NSLog("[BitChord] audio session deactivated (.notifyOthersOnDeactivation)")
        } catch {
            NSLog("[BitChord] audio session deactivation failed: \(error.localizedDescription)")
        }
#endif
    }

    /// Watches the session for output-route changes and calls `handler` on each.
    ///
    /// Returns the observer tokens; the caller holds them for as long as it
    /// wants the callbacks, and the observers die with them.
    ///
    /// cpal already sees the *device* half of a route change and rebuilds the
    /// audio unit itself. What it cannot do is re-activate the session, because
    /// the session is the app's — and a unit built while the session is down is
    /// never pulled by the audio daemon, which is silent in exactly the way a
    /// working engine is not. So this is the half only the app can supply.
    ///
    /// `.oldDeviceUnavailable` is the one that matters most: it is what putting
    /// AirPods down looks like, and it leaves the previous unit pointing at a
    /// device that has gone.
    @discardableResult
    static func observeRouteChanges(
        _ handler: @escaping () -> Void,
        onOldDeviceUnavailable: (() -> Void)? = nil
    ) -> [NSObjectProtocol] {
#if os(iOS)
        let center = NotificationCenter.default
        let token = center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { note in
            guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: raw)
            else { return }
            switch reason {
            case .oldDeviceUnavailable:
                NSLog("[BitChord] audio route device unavailable (e.g. headphones unplugged)")
                onOldDeviceUnavailable?()
                handler()
            case .newDeviceAvailable,
                 .routeConfigurationChange, .categoryChange, .override:
                NSLog("[BitChord] audio route changed (reason %d)", raw)
                handler()
            default:
                break
            }
        }
        return [token]
#else
        _ = handler
        _ = onOldDeviceUnavailable
        return []
#endif
    }

    /// Observes audio session interruptions (phone calls, Siri, other apps).
    ///
    /// When an interruption begins, the audio hardware is reclaimed; the app
    /// pauses playback and deactivates its session. When the interruption ends,
    /// `shouldResume` dictates whether playback should automatically resume.
    @discardableResult
    static func observeInterruptions(
        began: @escaping () -> Void,
        ended: @escaping (_ shouldResume: Bool) -> Void
    ) -> [NSObjectProtocol] {
#if os(iOS)
        let center = NotificationCenter.default
        let token = center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw)
            else { return }
            switch type {
            case .began:
                began()
            case .ended:
                let optionRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                let shouldResume = AVAudioSession.InterruptionOptions(rawValue: optionRaw)
                    .contains(.shouldResume)
                ended(shouldResume)
            @unknown default:
                break
            }
        }
        return [token]
#else
        _ = began
        _ = ended
        return []
#endif
    }

    /// Watches the session for the events that take the audio away without the
    /// engine's own counters moving: interruptions, requests to silence
    /// secondary audio, and a media-services reset.
    ///
    /// This is the blind spot that makes "using a page stutters the music" hard
    /// to diagnose. Everything on our side can look healthy at the same moment —
    /// output ring full, callback punctual, no underruns, no rebuilds — because
    /// the sound was never ours to lose: the system ducked it, interrupted it, or
    /// asked us to stand down for something else. None of that reached the log,
    /// and cpal handles the interruption stop/resume pair internally without
    /// reporting it.
    ///
    /// A page-scoped stutter can come from keyboard or other system audio.
    /// iOS's advisory that another app wants the primary audio slot — Siri, a
    /// navigation prompt, an alert.
    ///
    /// The hint lets the caller lower volume under a primary audio prompt.
    ///
    /// Separate from [observeSessionEvents], which formats the same notification
    /// into a log line: this one carries the value a caller can act on.
    @discardableResult
    static func observeSecondaryAudioSilence(
        _ handler: @escaping (Bool) -> Void
    ) -> [NSObjectProtocol] {
#if os(iOS)
        let session = AVAudioSession.sharedInstance()
        return [NotificationCenter.default.addObserver(
            forName: AVAudioSession.silenceSecondaryAudioHintNotification,
            object: nil,
            queue: .main
        ) { _ in
            // Read from the session rather than the notification's userInfo:
            // the hint's payload has changed shape across releases, and the
            // session property is the same answer in one documented place.
            handler(session.secondaryAudioShouldBeSilencedHint)
        }]
#else
        return []
#endif
    }

    @discardableResult
    static func observeSessionEvents(_ handler: @escaping (String) -> Void) -> [NSObjectProtocol] {
#if os(iOS)
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        var tokens: [NSObjectProtocol] = []

        tokens.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt ?? 0
            let began = AVAudioSession.InterruptionType(rawValue: raw) == .began
            let optionRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let shouldResume = AVAudioSession.InterruptionOptions(rawValue: optionRaw)
                .contains(.shouldResume)
            handler("audio interruption \(began ? "began" : "ended") shouldResume=\(shouldResume)")
        })

        tokens.append(center.addObserver(
            forName: AVAudioSession.silenceSecondaryAudioHintNotification,
            object: nil,
            queue: .main
        ) { _ in
            handler("secondary-audio hint: otherAudio=\(session.isOtherAudioPlaying) "
                    + "shouldSilence=\(session.secondaryAudioShouldBeSilencedHint)")
        })

        tokens.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil,
            queue: .main
        ) { _ in
            handler("audio media services were reset")
        })

        return tokens
#else
        _ = handler
        return []
#endif
    }
}
