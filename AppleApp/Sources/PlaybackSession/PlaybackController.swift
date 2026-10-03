import Foundation
import BitChordShared
#if os(iOS)
import UIKit
#if DEBUG
import AVFoundation
#endif
#else
import AppKit
#endif

extension QueueEntry {
    static func from(_ song: Song) -> QueueEntry {
        QueueEntry(
            id: song.videoId,
            title: song.title,
            artist: song.artist,
            source: song.localPath ?? "",
            thumbnailUrl: song.thumbnailUrl,
            durationText: song.durationText,
            albumName: song.albumName,
            artworkData: nil,
            isLocal: song.localPath != nil,
            // Carried through so the cross-source matcher can tell a clean edition
            // from an unstated one, and a video from catalogue audio.
            isExplicit: song.isExplicit?.boolValue,
            isVideo: song.isVideo
        )
    }

    static func from(_ track: LocalTrack) -> QueueEntry {
        QueueEntry(
            id: track.path,
            title: track.title.isEmpty ? URL(fileURLWithPath: track.path).deletingPathExtension().lastPathComponent : track.title,
            artist: track.artist,
            source: track.path,
            thumbnailUrl: nil,
            durationText: track.durationSeconds > 0 ? formatDuration(track.durationSeconds) : nil,
            albumName: track.album.isEmpty ? nil : track.album,
            artworkData: track.artwork,
            isLocal: true
        )
    }

    fileprivate func asSongJSON(videoIDOverride: String? = nil) -> SongJSON {
        SongJSON(
            videoId: videoIDOverride ?? videoId ?? id,
            title: title,
            artist: artist,
            thumbnailUrl: thumbnailUrl,
            durationText: durationText,
            albumName: albumName,
            artistId: artistId,
            albumId: albumId,
            isVideo: false,
            fromAutoplay: fromAutoplay
        )
    }
}

private struct SongJSON: Codable {
    let videoId: String
    let title: String
    let artist: String
    let thumbnailUrl: String?
    let durationText: String?
    let albumName: String?
    let artistId: String?
    let albumId: String?
    let isVideo: Bool
    let fromAutoplay: Bool
}

/// Where on the playing track the next Automix transition sits, as fractions
/// of duration (upstream `AppSettings.smartTransitionWindow`).
struct TransitionWindow: Equatable, Sendable {
    var start: Double
    var end: Double
}

/// The app-level playback controller: owns the Rust engine, the queue, and
/// the session-layer integration (now playing, widget state).
///
/// Engine semantics (spec §3): transitions are executed *inside* the engine —
/// queueNext arms the incoming track ~4 s before the current one ends and the
/// crossfade runs there; `onHandoff` fires as the incoming track becomes
/// audible, which is where the queue index and metadata flip (upstream's
/// `onHandoff` timing). A natural track-end reaching Swift means the queue
/// truly ran out.
@MainActor
@Observable
final class PlaybackController {
    let engine = PlayerEngine()

    private(set) var state: PlaybackState = .stopped
    private(set) var current: QueueEntry?
    /// Shelf or collection that started this queue, for the player caption.
    private(set) var playbackContext: String?
    /// Stable identity for the collection behind the queue, used by its hero control.
    private(set) var playbackContextID: String?
    private(set) var queue: [QueueEntry] = []
    private(set) var playingIndex: Int = 0
    private(set) var position: Double = 0
    private(set) var duration: Double = 0
    private(set) var lastError: String?

    var volume: Double = 0.9 {
        didSet { engine.setVolume(gain: Float(volume)); dolbyRenderer?.volume = Float(volume) }
    }

    var isPlaying: Bool { state == .playing }
    var isBuffering: Bool { state == .buffering }
#if os(iOS)
    private(set) var mixWithOtherAudio = PlatformSettings.shared.getBoolean(
        key: "mix_with_other_audio", default: true
    )
    private var mixingPreferenceGeneration: UInt64 = 0

    /// Explicit listener choice; app transitions never change this policy.
    func setMixWithOtherAudio(_ enabled: Bool) {
        guard mixWithOtherAudio != enabled else { return }
        mixWithOtherAudio = enabled
        PlatformSettings.shared.putBoolean(key: "mix_with_other_audio", value: enabled)
        mixingPreferenceGeneration &+= 1
        nowPlaying.audioSessionUnavailable()
        guard started, isPlaying || isBuffering || AudioSessionManager.isActive else { return }
        let preference = mixingPreferenceGeneration
        let selection = playGeneration
        let intent = resumeGeneration
        Task { [weak self] in
            guard let self, self.mixingPreferenceGeneration == preference,
                  self.playGeneration == selection, self.resumeGeneration == intent,
                  self.isPlaying || self.isBuffering || AudioSessionManager.isActive else { return }
            do {
                // AudioSessionManager owns the serial worker queue. Awaiting
                // here does not configure AVAudioSession on the main thread.
                _ = try await AudioSessionManager.activate()
                guard self.mixingPreferenceGeneration == preference,
                      self.playGeneration == selection, self.resumeGeneration == intent,
                      self.isPlaying else { return }
                self.nowPlaying.updateRate(self.playbackRate, position: self.playbackPosition)
                self.nowPlaying.requestPrimaryIfPossible(reason: "mixing preference changed")
            } catch {
                guard self.mixingPreferenceGeneration == preference,
                      self.playGeneration == selection, self.resumeGeneration == intent else { return }
                self.audioActivationFailed(error)
            }
        }
    }
#endif
    var canPlayPrevious: Bool {
        playingIndex > 0 || (repeatMode == .all && !queue.isEmpty)
    }
    var canPlayNext: Bool {
        playingIndex + 1 < queue.count
            || (repeatMode == .all && !queue.isEmpty)
            || (repeatMode == .one && automixEnabled && current != nil)
    }

    /// Upstream ExoPlayer `REPEAT_MODE_OFF / ALL / ONE`.
    enum RepeatMode: Int, CaseIterable {
        case off, all, one
    }

    private(set) var repeatMode: RepeatMode = .off
    private(set) var shuffleEnabled = false
    /// AutoPlay tail removed while repeat-all is on, put back when it ends —
    /// upstream `repeatAllStash`. Taken once per stretch of ALL so OFF→ALL→ONE
    /// does not overwrite a full stash with the empty tail the first step left.
    private var repeatAllStash: [QueueEntry] = []
    /// `id` of the track that was current when [repeatAllStash] was taken.
    private var repeatAllStashSeed: String?
    @ObservationIgnored private var autoplayRefresh = AutoplayRefreshState()
    @ObservationIgnored private var queueEditRevision: UInt64 = 0
    @ObservationIgnored private var sequencingTask: Task<Void, Never>?
    @ObservationIgnored private var sequencingGeneration: UInt64 = 0
    #if DEBUG
    @ObservationIgnored private var recommendationFetchOverride: ((String, @escaping (String?, String?) -> Void) -> Void)?
    #endif
    private(set) var lyrics: [LyricLineDto] = []
    /// Empty when lyrics came from the file itself (EmbeddedLyrics).
    private(set) var lyricsSourceLabel: String?
    private(set) var lyricsLoading = false

    /// Translation and romanisation, and the state the panel's controls read.
    let lyricsTranslator = LyricsTranslator()

    /// The lyric as it should be shown: the translation when there is one.
    ///
    /// Kept beside `lyrics` rather than replacing it, so "Show Original" is
    /// instant and so a track change cannot leave a translation on screen for
    /// whatever is playing now.
    var displayedLyrics: [LyricLineDto] {
        lyricsTranslator.translatedLines ?? lyrics
    }

    /// Whether a lyric was looked for and none was found, as opposed to one still
    /// being looked for.
    ///
    /// The deck's current-lyric strip shows something in both cases, and they are
    /// different messages: "no lyrics for this track" is a fact about the track
    /// and "looking" is a fact about the moment. Telling them apart needs a flag
    /// rather than `lyrics.isEmpty`, which is true during the search too.
    var lyricsUnavailable: Bool {
        attemptedLyrics && !lyricsLoading && lyrics.isEmpty
    }

    private(set) var attemptedLyrics = false
    /// True while local audio analysis is filling in word timings.
    private(set) var lyricsAligning = false
    /// Re-run a lookup that began before the decoder reported the real duration.
    @ObservationIgnored private var lyricsNeedsDurationRefresh = false
    /// A newer retry for the same track must win over an older provider race.
    @ObservationIgnored private var lyricsRequestGeneration: UInt64 = 0
    @ObservationIgnored private var lyricsAlignmentTask: Task<Void, Never>?
    private(set) var canvasURL: URL?
    private(set) var canvasFallbackURL: URL?
    /// Source returned with the active canvas payload (`SPOTIFY` or another
    /// provider). Kept with the clip so a version change does not lose it.
    private(set) var canvasSource: String?
    private var canvasLookupGeneration: UInt64 = 0
    private var canvasIdentity: String?
    private(set) var nerd: NerdStatsRec?
    /// True while a lossless/module lookup is still running for the playing track
    /// (upstream `NerdStats.racingLossless`).
    private(set) var racingLossless = false
    /// Automix analysis tier for stats-for-nerds: `beatmatched`, `dj`, or `plain`.
    private(set) var analysisTier: String?
    /// Analysis backends for the last planned pair: outgoing / incoming
    /// (`music_understanding`, `beat_this`, `dsp`, `disk_cache`).
    private(set) var analysisSources: String?
    /// Beat-grid confidence when native-core exposes it. Nil until then.
    private(set) var analysisConfidence: Double?
    /// Marker on the progress bar while a planned Automix window is known.
    private(set) var smartTransitionWindow: TransitionWindow?
    /// True during a real Automix (not a plain equal-power fallback).
    private(set) var smartMixInProgress = false
    /// Where in *this* track the last planned transition cued it, in seconds.
    ///
    /// Published so the mix-in point is visible while the track plays rather
    /// than only in a log line. A deep value is the symptom of a planning bug
    /// rather than a setting, and seeing it in the player is how it gets
    /// noticed; `0` means the track started at the top, which is the ordinary
    /// case now that the planner enters a record at the head of its own intro.
    private(set) var automixCueSeconds: Double?
    private var sleepDeadline: ContinuousClock.Instant?
    private var sleepTask: Task<Void, Never>?
    private var sleepSecondsRemaining: Int?
    private(set) var sleepAfterTrack = false
    private(set) var autoplayEnabled = PlatformSettings.shared.getBoolean(key: "autoplay", default: true)
    private(set) var automixEnabled = PlatformSettings.shared.getBoolean(key: "smart_fade_enabled", default: true)
    var hideVolumeBar = PlatformSettings.shared.getBoolean(key: "hide_volume_bar", default: false)
    /// Hides the "Playing from" / "Played by" caption on the main player.
    /// Read by the player UI; persisted here so the choice survives restarts.
    var hideSongStatus = PlatformSettings.shared.getBoolean(key: "hide_song_status", default: false)
    /// Requested PCM word length at the output boundary (`PCM_16` /
    /// `FLOAT_32`, upstream's two rungs). The engine opens the unit as int16
    /// or float to match; the Audio Pipeline readout reports what is actually
    /// in effect.
    var outputPcmMode = migrateOutputPcmMode()
    /// Opt-in exact integer output on macOS routes that grant CoreAudio hog
    /// mode. Unsupported tracks and routes stay on the normal audio path.
    var bitPerfectOutput = PlatformSettings.shared.getBoolean(key: "bit_perfect_output", default: false)
    /// Request the current source's sample rate from the DAC/audio session.
    var matchSourceSampleRate = PlatformSettings.shared.getBoolean(key: "match_source_sample_rate", default: true)
    /// Prefer an attached USB audio output over the system's normal route.
    /// The engine picks the USB device at (re)build; on iOS the session owns
    /// the route, so there it stays advisory and the readout says which route
    /// is in effect.
    var preferUsbDac = PlatformSettings.shared.getBoolean(key: "prefer_usb_dac", default: false)
    /// Level every track to the same loudness. The engine applies the
    /// catalogue figure per track (upstream's clamp); tracks without one play
    /// at unity and the readout says so.
    var soundMode = PlatformSettings.shared.getString(key: "sound_mode", default: "TRANSPARENT")
    var clarityPreset = PlatformSettings.shared.getString(key: "clarity_preset", default: "REFERENCE")
    var clarityWet = Double(PlatformSettings.shared.getFloat(key: "clarity_wet", default: 1))
    var loudnessMode = PlatformSettings.shared.getString(key: "loudness_mode", default: PlatformSettings.shared.getBoolean(key: "loudness_normalization", default: false) ? "TRACK" : "OFF")
    var loudnessNormalization = PlatformSettings.shared.getBoolean(key: "loudness_normalization", default: false)
    /// CPU budget for Automix's background analysis (EFFICIENT / BALANCED /
    /// PERFORMANCE). EFFICIENT skips the vocal model; the 1 / 2 / 4 thread
    /// counts are upstream's ORT numbers, reported for the analysis path.
    var automixPerformanceMode = PlatformSettings.shared.getString(key: "automix_performance", default: "BALANCED")
    /// Whether a manual version switch keeps the playback position.
    /// Upstream aligns the matching moment by waveform; this port has no
    /// analyser, so "aligned" means resuming where the listener was. Off
    /// restarts from the top, since no alignment is attempted at all.
    var smartVersionAlignment = PlatformSettings.shared.getBoolean(key: "smart_version_alignment", default: true)
    /// Prefer the catalogue audio release when the queued result is a music
    /// video. Applied in the resolve race: a video entry waits for the
    /// substitute lookup instead of taking YouTube's own upload first.
    var preferMusicOnly = PlatformSettings.shared.getBoolean(key: "prefer_music_only", default: false)
    /// Which artist a scrobble credits: the full track credit ("track") or the
    /// lead name alone ("album"). Applied to every scrobble payload below.
    var scrobblePrimaryArtist = PlatformSettings.shared.getString(key: "scrobble_primary_artist", default: "track")
    private var scrobbleArmed = false
    private var scrobbleSent = false
    /// Loudness figure of the track the engine has loaded. Kept so a
    /// mid-track quality upgrade (same recording, new file) can carry the
    /// correction across instead of dropping to unity mid-song.
    private var currentLoudnessDb: Double?
    /// Upstream `BACK_RESTARTS_AFTER_MS = 10_000`.
    static let backRestartsAfter: TimeInterval = 10

    /// Song-menu sleep-timer trailing string (`"3:21"` / `"After this song"`).
    var sleepTimerStatus: String? {
        if let sleepDeadline {
            let remaining = sleepRemaining(sleepDeadline)
            guard remaining > 0 else { return nil }
            let seconds = sleepSecondsRemaining ?? Int(remaining.rounded())
            return String(format: "%d:%02d", seconds / 60, seconds % 60)
        }
        return sleepAfterTrack ? "After this song" : nil
    }

    /// Last resolve/upgrade/source decisions, for a UI "Debug log" action.
    var debugLogText: String { debugLog.dump() }
    var diagnosticSnapshot: String { "engine=\(String(describing: engine.nerdStats()))\nroute=\(String(describing: engine.outputDevice()))\ntrim_edges=\(PlatformSettings.shared.getBoolean(key: "trim_edge_silence", default: false)) skip_non_music=\(PlatformSettings.shared.getBoolean(key: "skip_non_music", default: false))\noutput=\(String(describing: engine.outputHealth()))\nstate=\(state) automix=\(automixEnabled) volume=\(volume)" }

    private let debugLog = PlaybackDebugLog.shared
    private var pendingAutomixPlan: TransitionPlanRec?
    private var upgradeFor: String?
    private var mixFadeUntil: Date?

    /// Id the engine currently has loaded — nil after a cold restore until Play.
    fileprivate var dolbyRenderer: AppleDolbyRenderer?
    private var playbackPosition: Double { dolbyRenderer?.position ?? engine.positionSeconds() }
    @ObservationIgnored private var durationRepairTask: Task<Void, Never>?
    private var engineLoadedId: String?
    /// Cached once per selection; history polling does not scan download assets.
    private var historyVideoID: String?
    /// The file the engine actually opened for the loaded track, as it reports
    /// it back. Kept because `QueueEntry.source` is **not** a path for a
    /// YouTube track — it is `yt:<videoId>` (see `QueueEntry.youtube`) — and the
    /// planner needs something it can decode. Handing it the identifier made
    /// `duration_of` return 0, which skips the whole-track analysis, leaves
    /// `bpm` at 0, and drops every plan to `Tier::Plain`: a plain crossfade on
    /// essentially all normal streaming playback, with the smart path never
    /// reached. Skipping the plan (as the load path does when it cannot get a
    /// path) is also wrong — it forgoes the cue and the arm — so the path is
    /// remembered instead.
    private var regionTasks: [String: Task<Void, Never>] = [:]
    private var resolvedVideoIds: [String: String] = [:]
    private var preparedRegionSources: Set<String> = []
    private var loudnessMeasurementTask: Task<Void, Never>?
    private var loadedSourcePath: String? {
        didSet { if oldValue != loadedSourcePath {
            scheduleLoudnessMeasurement()
            if let source = loadedSourcePath {
                DownloadStore.shared.retainPlayback(paths: Set([source] + Array(sourceHeadersByPath.keys)))
                prepareRegions(source: source, videoId: resolvedVideoIds[source] ?? DownloadStore.shared.provenance(for: source))
            } else { DownloadStore.shared.retainPlayback(paths: Set(sourceHeadersByPath.keys)) }
        } }
    }
    /// Request credentials travel with a source for both playback and analysis.
    /// Prefetched headers are held by source until the mixer reports handoff.
    private var loadedSourceHeaders: [String: String] = [:]
    private var sourceHeadersByPath: [String: [String: String]] = [:]
    /// Invalidates an older source-resolution or analysis task when the queue
    /// changes without changing the currently playing track.
    private var queueNextRevision: UInt64 = 0
    /// Where a restored session left off, **and which track it was left on**.
    ///
    /// The id is the whole point. Held as a bare `Double?` the position was
    /// consumed by whichever track loaded next, so pressing Next during the
    /// window between `restoreSession` (which sets this and clears
    /// `engineLoadedId`) and the first play started a *different* song that far
    /// in — the log's `requested_start=13.013s` on a track the listener had just
    /// skipped to. A resume position belongs to a track, so it is stored with
    /// one.
    private var restoredStart: (entryId: String, position: Double)?
    private var lastPersistAt = Date.distantPast

    private var positionTimer: Timer?
    private var started = false
    /// The output stream must exist before a restored track is loaded into the
    /// engine. Keeping the startup task lets each load await that one boot
    /// instead of racing it on a second detached task.
    private var engineStartupTask: Task<Void, Error>?
    /// Incremented on every user-initiated load so in-flight resolves/downloads
    /// from a previous tap cannot `loadTrack`/`queueNext` into the new song.
    private var playGeneration: UInt64 = 0
    /// Serializes the last synchronous engine setup/load step and drops any
    /// request whose generation was superseded while it resolved or probed.
    @ObservationIgnored private let loadSubmissionGate = PlaybackLoadSubmissionGate()
    /// Invalidates an in-flight audio-session reactivation when another
    /// transport command arrives before it finishes.
    private var resumeGeneration: UInt64 = 0
#if os(iOS)
    @ObservationIgnored private var playbackStartTask: Task<Void, Never>?
#endif
    private let nowPlaying = NowPlayingController()
    private let widgetPublisher = WidgetStatePublisher()
    private let headTracker = HeadTracker()
    /// Session route-change observers. Held so they stay registered for the
    /// life of the controller; releasing them is what unsubscribes.
    private var routeObservers: [NSObjectProtocol] = []
    /// Tracks if playback was interrupted by phone calls, Siri, or other exclusive audio.
    private var wasInterrupted = false

    init() {
        _ = LoadingMonitor.shared
        _ = LaunchReadiness.shared
        let configuredSpeed = Double(PlatformSettings.shared.getFloat(key: "playback_speed", default: 1))
        playbackRate = configuredSpeed.isFinite ? min(max(configuredSpeed, 0.5), 2.0) : 1.0
        engine.registerCallback(callback: EngineCallbacks(controller: self))
        // The engine rebuilds the *device* on a route change; only the app can
        // re-activate the session it rebuilds against. See `outputRouteChanged`.
        // Also pause if the old device became unavailable (e.g. headphones unplugged).
        routeObservers = AudioSessionManager.observeRouteChanges(
            { [weak self] in
                Task { @MainActor in
                    AudioRouteState.shared.refresh()
                    self?.applySpatialPreference()
                    self?.outputRouteChanged()
                }
            },
            onOldDeviceUnavailable: { [weak self] in
                Task { @MainActor in
                    guard let self, self.isPlaying || self.isBuffering || self.wasInterrupted else { return }
                    self.pausePlayback()
                }
            }
        )
        #if os(iOS)
        routeObservers.append(NotificationCenter.default.addObserver(forName: UIAccessibility.monoAudioStatusDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in AudioRouteState.shared.refresh(); self?.applySpatialPreference() }
        })
        #endif
        AudioRouteState.shared.refresh()
        routeObservers += AudioSessionManager.observeSpatialCapabilities { [weak self] enabled in
            Task { @MainActor in
                AudioRouteState.shared.refresh(systemSpatialEnabled: enabled)
                self?.applySpatialPreference()
            }
        }
        // Handle interruptions cleanly: when an incoming call, Siri, navigation,
        // or another app begins, pause engine, notify nowPlaying, and deactivate
        // session so the other app has exclusive audio access. When interruption
        // ends with .shouldResume, automatically resume playback.
        routeObservers += AudioSessionManager.observeInterruptions(
            began: { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    NSLog("[BitChord] Audio interruption began")
                    if self.isPlaying || self.isBuffering {
                        self.pausePlayback(releaseAudioSession: true)
                        self.wasInterrupted = true
                    }
                }
            },
            ended: { [weak self] shouldResume in
                Task { @MainActor in
                    guard let self else { return }
                    NSLog("[BitChord] Audio interruption ended, shouldResume=\(shouldResume)")
                    if self.wasInterrupted {
                        self.wasInterrupted = false
                        if shouldResume {
                            self.togglePlayPause()
                        }
                    }
                }
            }
        )
        // Log secondary audio events and media reset notifications
        routeObservers += AudioSessionManager.observeSessionEvents { [weak self] event in
            PlaybackDebugLog.shared.record(event)
            NSLog("[BitChord] %@", event)
            if event == "audio media services were reset" {
                Task { @MainActor in
                    self?.nowPlaying.audioSessionUnavailable()
                    AudioRouteState.shared.refresh()
                    self?.applySpatialPreference()
                    self?.outputRouteChanged()
                }
            }
        }
        // And the one session signal that asks for an action rather than a line
        // in the log: another app wants the primary audio slot. Duck, don't
        // pause — the music is the thing this app promises not to take away, and
        // the prompt is the thing that has to be heard over it.
        routeObservers += AudioSessionManager.observeSecondaryAudioSilence { [weak self] shouldSilence in
            Task { @MainActor in
                self?.applyDuck(shouldSilence)
                if !shouldSilence {
                    self?.nowPlaying.requestPrimaryIfPossible(reason: "other audio ended")
                }
            }
        }
        nowPlaying.onToggle = { [weak self] in self?.togglePlayPause() }
        nowPlaying.onPlay = { [weak self] in
            guard let self, !self.isBuffering else { return }
            if self.isPlaying {
                // Selecting a secondary native card can send Play while the
                // engine is already playing. Re-anchor its actual snapshot and
                // honor that focus request without toggling playback off.
                self.nowPlaying.updateRate(self.playbackRate, position: self.playbackPosition)
                self.reactivateAudioSessionAfterForeground(reason: "native play")
                return
            }
            self.togglePlayPause()
        }
#if os(iOS)
        nowPlaying.onPlayAsync = { [weak self] in
            guard let self else { throw CancellationError() }
            self.nowPlaying.onPlay?()
            let intent = self.resumeGeneration
            let selection = self.playGeneration
            await self.playbackStartTask?.value
            guard self.resumeGeneration == intent, self.playGeneration == selection,
                  self.isPlaying else { throw CancellationError() }
        }
#endif
        nowPlaying.onPause = { [weak self] in
            guard let self else { return }
            // A physical/remote Pause during a Siri interruption still cancels
            // the pending resume, even though the engine is already paused.
            self.wasInterrupted = false
            self.resumeGeneration &+= 1
            guard self.isPlaying || self.isBuffering else { return }
            self.pausePlayback()
        }
        nowPlaying.onNext = { [weak self] in self?.next() }
        nowPlaying.onPrevious = { [weak self] in self?.previous() }
        nowPlaying.onSeek = { [weak self] seconds in self?.seek(to: seconds) }
        // The audio session is activated by `startEngineIfNeeded`, not here.
        // Activating from `init` raced the engine start — two detached tasks
        // with nothing ordering them — and a RemoteIO unit built before the
        // session was up never gets pulled, so the track played in silence.
        QualityUpgrade.forgetLastSession()
        restoreSession()
        let token = PlatformSettings.shared.getSecret(key: "discord_token") ?? ""
        if !token.isEmpty { DiscordGateway.shared.connect(token: token) }
    }

    func startEngineIfNeeded() {
        guard !started else { return }
        started = true
        // Engine start touches HAL / cpal which blocks (~1s) and triggers
        // Thread Performance Checker if done on main. Run on utility QoS
        // so it doesn't outrank the Default QoS cpal monitor thread
        // (upstream runs PlaybackService on its own thread).
        let eng = engine
        let crossfade = Double(PlatformSettings.shared.getInt(key: "crossfade_seconds", default: 0))
        let spatial = PlatformSettings.shared.getBoolean(key: "spatial_audio", default: false) && AudioRouteState.shared.permitsCustomSpatial
        let skip = PlatformSettings.shared.getBoolean(key: "skip_silence", default: false)
        let speed = PlatformSettings.shared.getFloat(key: "playback_speed", default: 1)
        playbackRate = Double(speed).isFinite ? min(max(Double(speed), 0.5), 2.0) : 1.0
        let eq = Self.currentEqTuning()
        engineStartupTask = Task.detached(priority: .utility) { [weak self] in
            do {
                // The session has to be up before the output stream exists, and
                // the iOS session owns the hardware format — so this is awaited,
                // and its answer is what the engine is told to open at.
                let format = try await AudioSessionManager.activate()
                // Configure device choice and sample format before opening the
                // stream. Applying them just after start caused a second output
                // build while the first track could already be playing.
                try eng.setOutputPcmMode(mode: Self.migrateOutputPcmMode())
                try eng.setBitPerfectEnabled(
                    enabled: PlatformSettings.shared.getBoolean(key: "bit_perfect_output", default: false)
                )
                try eng.setPreferUsbDac(
                    enabled: PlatformSettings.shared.getBoolean(key: "prefer_usb_dac", default: false)
                )
                eng.setAutomixPerformance(
                    mode: PlatformSettings.shared.getString(key: "automix_performance", default: "BALANCED")
                )
                try eng.start(
                    rate: format?.rate,
                    channels: format?.channels
                )
                try eng.setSoundMode(mode: PlatformSettings.shared.getString(key: "sound_mode", default: "TRANSPARENT") == "ENHANCED" ? .enhanced : .transparent)
                try eng.setClarityTuning(tuning: Self.storedClarityTuning())
                try eng.setLoudnessMode(mode: Self.storedLoudnessMode())
                try eng.setCrossfadeWindow(seconds: crossfade)
                try eng.setSpatialEnabled(enabled: spatial)
                try eng.setSkipSilence(enabled: skip)
                try eng.setPlaybackSpeed(speed: speed)
                try eng.setEqTuning(
                    enabled: eq.enabled,
                    gainsDb: eq.gains,
                    qs: eq.qs,
                    balance: eq.balance
                )

                if spatial && PlatformSettings.shared.getString(key: "sound_mode", default: "TRANSPARENT") == "ENHANCED" {
                    await MainActor.run { [weak self] in self?.headTracker.start(engine: eng) }
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.started = false
                    self.positionTimer?.invalidate()
                    self.positionTimer = nil
                    self.lastError = "Audio engine failed to start: \(error)"
                }
                throw error
            }
        }
        positionTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                for event in drainTechnicalEvents() { self.debugLog.record(event) }
                self.pollWidgetCommands()
                guard self.state == .playing else { return }
                self.position = self.playbackPosition
                self.positionSampledAt = Date()
                self.nowPlaying.update(position: self.position)
                // The periodic output-health NSLog that used to sit here is
                // gone: every figure it carried — buffered frames, silent
                // callbacks, rebuilds, xruns and the output peak — is on the
                // Audio Pipeline sheet, live and without a console. It was the
                // loudest thing in the log, five lines a second after every
                // load, and it answered its question.
                self.tickSleep()
                self.tickScrobble()
                self.tickHistory()
                self.tickListening()
                if Date().timeIntervalSince(self.lastPersistAt) >= 4 {
                    self.lastPersistAt = Date()
                    self.persistSession()
                }
            }
        }
    }

    /// A running output can survive in the background while iOS temporarily
    /// deactivates its audio session. Reassert playback activation on return
    /// only when actively playing; do not hijack audio when paused or idle.
    func reactivateAudioSessionAfterForeground(reason: String = "foreground") {
        guard started, state == .playing else { return }
        let selection = playGeneration
        let intent = resumeGeneration
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                _ = try await AudioSessionManager.activate()
                await MainActor.run { [weak self] in
                    guard let self, self.state == .playing,
                          self.playGeneration == selection, self.resumeGeneration == intent else { return }
                    self.nowPlaying.requestPrimaryIfPossible(reason: reason)
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self, self.playGeneration == selection,
                          self.resumeGeneration == intent else { return }
                    self.audioActivationFailed(error)
                }
            }
        }
    }

    private func audioActivationFailed(_ error: Error) {
        nowPlaying.audioSessionUnavailable()
        if isPlaying || isBuffering { pausePlayback(releaseAudioSession: true) }
        lastError = "Audio session could not activate: \(error)"
    }

    /// The output route moved under us — AirPods put down, a device connected,
    /// the route reconfigured.
    ///
    /// The engine hears about this directly from CoreAudio and rebuilds the
    /// audio unit. Two things still have to happen here, and they are the
    /// reason this handler exists at all:
    ///
    /// 1. The session is the app's, so only the app can re-activate it. A unit
    ///    built while the session is down is never pulled by the audio daemon —
    ///    silent, with the mixer cheerfully filling a ring that nothing drains.
    /// 2. That has to be ordered *before* the rebuild. Activation lands in
    ///    milliseconds and `requestOutputRebuild` is not dropped when a rebuild
    ///    is already running, so this second pass runs after the session is up
    ///    even if CoreAudio's own rebuild beat us to it.
    private var routeRecoveryGeneration: UInt64 = 0
    private func outputRouteChanged() {
        routeRecoveryGeneration &+= 1
        let recovery = routeRecoveryGeneration
        guard started, state == .playing else { return }
        let selection = playGeneration
        let intent = resumeGeneration
        let engine = self.engine
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                _ = try await AudioSessionManager.activate()
            } catch {
                await MainActor.run { [weak self] in
                    guard let self, self.playGeneration == selection,
                          self.resumeGeneration == intent, self.routeRecoveryGeneration == recovery else { return }
                    self.audioActivationFailed(error)
                }
                return
            }
            await MainActor.run { [weak self] in
                guard let self, self.isPlaying, self.playGeneration == selection,
                      self.resumeGeneration == intent, self.routeRecoveryGeneration == recovery else { return }
                do {
                    if self.dolbyRenderer == nil { try engine.requestOutputRebuild(force: true) }
                    self.nowPlaying.requestPrimaryIfPossible(reason: "route activation")
                } catch {
                    NSLog("[BitChord] output rebuild after route change failed: \(error)")
                }
            }
        }
    }

    /// How far down a duck goes: −16 dB.
    ///
    /// Audible as "quieter", not as "gone". A navigation prompt reads clearly
    /// over it and the listener's own music does not stop, which is the promise
    /// this app makes about coexisting with other audio.
    private static let duckGain: Double = 0.16

    /// The ramp in flight, if any.
    ///
    /// Held so a new instruction cancels the one it interrupts — two ramps
    /// writing the output gain at once is a fight the engine cannot arbitrate.
    @ObservationIgnored private var duckTask: Task<Void, Never>?
    /// Whether a duck is currently applied, so repeat notifications are free.
    @ObservationIgnored private var isDucked = false

    /// Quieter while iOS says another app wants the primary audio slot.
    ///
    /// Three deliberate choices:
    ///
    /// - **Duck, not pause.** The session is mixable, so the system will not
    ///   stop us; whether to get out of the way is ours to decide, and stopping
    ///   the music for a two-second prompt is not the trade this app makes.
    /// - **Ramp, not step.** The engine applies the gain per sample, so a jump
    ///   is a click. Twenty steps of ~10 ms is ~200 ms to −16 dB: fast enough to
    ///   be out of the way when a prompt starts, slow enough not to be heard as
    ///   a jump.
    /// - **The output, not `volume`.** This calls the engine directly instead of
    ///   going through the published `volume`, so the slider keeps showing what
    ///   the listener chose while the *output* is quieter. Ducking by writing
    ///   `volume` would have moved their control and then had to guess what to
    ///   put it back to.
    private func applyDuck(_ shouldDuck: Bool) {
        guard shouldDuck != isDucked else { return }
        isDucked = shouldDuck
        duckTask?.cancel()
        let from = Float(volume * (shouldDuck ? 1.0 : Self.duckGain))
        let to = Float(volume * (shouldDuck ? Self.duckGain : 1.0))
        let engine = self.engine
        duckTask = Task(priority: .userInitiated) { [weak self] in
            let steps = 20
            for step in 1...steps {
                if Task.isCancelled { return }
                let progress = Float(step) / Float(steps)
                engine.setVolume(gain: from + (to - from) * progress)
                self?.dolbyRenderer?.volume = from + (to - from) * progress
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
    }

    // ---- Queue operations ---------------------------------------------------

    /// Plays `entries`, starting at `index`. Replaces the queue.
    func play(
        _ entries: [QueueEntry],
        at index: Int = 0,
        context: String? = nil,
        contextID: String? = nil,
        shuffleRequested: Bool? = nil,
        shuffleStart: Bool = false
    ) {
        noteLocalIntent()
        guard entries.indices.contains(index) else { return }
        let entry = entries[index]
        // Same song already loading or playing: extra taps are from the
        // download delay, not a request to restart.
        if current?.id == entry.id,
           playbackContextID == contextID,
           !shuffleStart, shuffleRequested == nil || shuffleRequested == shuffleEnabled,
           queue.filter({ $0.contextOrder != nil }).sorted(by: { ($0.contextOrder ?? 0) < ($1.contextOrder ?? 0) }).map(\.id) == entries.map(\.id),
           state == .buffering || state == .playing {
            return
        }
        let useShuffle = shuffleRequested ?? shuffleEnabled
        var entries = entries.enumerated().map { offset, value in
            var value = value
            value.contextOrder = offset
            value.fromAutoplay = false
            return value
        }
        var index = index
        if shuffleStart, useShuffle, !automixSequencingEnabled {
            entries = PlaybackQueuePolicy.startingWith(entries, seed: Int.random(in: entries.indices))
            index = 0
        }
        let selected = entries[index]
        queue = PlaybackQueuePolicy.orderList(
            entries, after: index, automix: automixSequencingEnabled,
            shuffle: useShuffle, scores: tasteScores(entries)
        )
        playbackContext = context
        playbackContextID = contextID
        shuffleEnabled = useShuffle
        queueEditRevision &+= 1
        autoplayRefresh.invalidate()
        restoredStart = nil
        repeatAllStash = []
        repeatAllStashSeed = nil
        startEngineIfNeeded()
        if engineLoadedId == selected.id, current?.source == selected.source, state == .playing {
            playingIndex = index
            current = queue[index]
            persistSession()
            maybeAutoplay(force: true)
            syncEngineQueueNext()
            scheduleSequencing()
            return
        }
        loadCurrent(index)
    }

    private var automixSequencingEnabled: Bool {
        automixEnabled && PlatformSettings.shared.getBoolean(key: "automix_smart_sequence", default: true)
    }

    func isPlaybackContextActive(_ contextID: String) -> Bool {
        playbackContextState(contextID) != .inactive
    }

    func isPlaybackContextPlaying(_ contextID: String) -> Bool {
        playbackContextState(contextID) == .playing
    }

    private func playbackContextState(_ contextID: String) -> PlaybackQueuePolicy.HeroState {
        PlaybackQueuePolicy.heroState(
            origin: playbackContextID, listID: contextID, hasQueue: !queue.isEmpty,
            stopped: state == .stopped, playingOrBuffering: state == .playing || state == .buffering
        )
    }

    func togglePlaybackContext(
        _ entries: [QueueEntry],
        at index: Int = 0,
        title: String,
        contextID: String,
        shuffleRequested: Bool? = nil
    ) {
        if isPlaybackContextActive(contextID) {
            togglePlayPause()
        } else {
            play(entries, at: index, context: title, contextID: contextID, shuffleRequested: shuffleRequested, shuffleStart: true)
        }
    }

    // ---- Revert to original / upgrade quality --------------------------------

    /// A revert is only offered for a streamed YouTube track, because a track
    /// playing off a file the listener saved is not playing a stream anything
    /// chose. There is no "original" to go back to for a local file, JioSaavn or
    /// a remote-library row: those have no YouTube upload behind them at all.
    var canRevertToOriginal: Bool {
        guard let entry = current, let id = entry.videoId, entry.source.hasPrefix("yt:") else { return false }
        return !OriginalVersion.shared.isPinned(videoId: id) && !playingYouTubesOwn
    }

    /// The way back. A pinned track is held off the automatic search on purpose,
    /// so nothing but this row will ever offer it a better copy again.
    var canUpgradeQuality: Bool {
        guard let entry = current, let id = entry.videoId, entry.source.hasPrefix("yt:") else { return false }
        return OriginalVersion.shared.isPinned(videoId: id) || playingYouTubesOwn
    }

    /// Whether the currently playing source *is* YouTube's own stream for this
    /// track, whether the listener asked for that or an upgrade failed and was
    /// put back automatically.
    ///
    /// Kept as its own question because the two rows are offered on opposite
    /// sides of it: answering both from the pin alone would offer a revert for a
    /// track already on YouTube's upload, where the row would do nothing.
    private var playingYouTubesOwn: Bool {
        guard let entry = current, let origin = resolvedOrigin[entry.id] else { return false }
        return origin == .youtube || origin == .cache
    }

    /// Sends the playing track back to YouTube's own upload and holds it there.
    ///
    /// The position is kept: a listener who dislikes a substitute wants the song
    /// from where it was, not from the top. Upstream replaces the item with a
    /// direct-YouTube one, and the hold is what makes that stick past this queue
    /// entry — otherwise the next pass round the queue starts the whole
    /// substitution search again and lands them right back on the copy they
    /// rejected.
    func revertToOriginal() {
        guard let entry = current, let id = entry.videoId, entry.source.hasPrefix("yt:") else { return }
        OriginalVersion.shared.pin(videoId: id)
        // The cached file is whichever copy was downloaded, which for a track
        // being reverted is the one they just rejected. It has to go, or the
        // resolve hands it straight back and nothing appears to happen.
        Task { await StreamFileCache.shared.forget(videoId: id) }
        QualityUpgrade.forget(id)
        debugLog.record("reverted to YouTube's own upload", about: id)
        // Aligned only when version alignment is on: with it off no alignment
        // is attempted, so the reverted cut starts from the top.
        restartCurrent(keepingPosition: smartVersionAlignment)
    }

    /// Releases the hold and asks again, by hand, for a better copy.
    ///
    /// "By hand" is the load-bearing word: the automatic path may already have
    /// found this candidate and rejected it. This is also the only thing that
    /// clears a pin — an upgrade the app decided on by itself must never
    /// overturn a decision the listener made.
    func upgradeQuality() {
        guard let entry = current, let id = entry.videoId else { return }
        OriginalVersion.shared.unpin(videoId: id)
        QualityUpgrade.askByHand(id)
        debugLog.record("asked again for a better copy", about: id)
        restartCurrent(keepingPosition: smartVersionAlignment)
    }

    /// Reloads the playing entry so a new pin takes effect now rather than the
    /// next time the song comes round.
    private func restartCurrent(keepingPosition: Bool) {
        guard queue.indices.contains(playingIndex) else { return }
        let resumeAt = keepingPosition ? position : 0
        // A restart is a new load, so the in-flight guard has to move: a resolve
        // started by the old source must not be able to `loadTrack` into the new.
        playGeneration &+= 1
        dolbyRenderer?.stop()
        dolbyRenderer = nil
        engineLoadedId = nil
        loadedSourcePath = nil
        loadedSourceHeaders = [:]
        sourceHeadersByPath.removeAll(keepingCapacity: true)
        loadCurrent(playingIndex, startAt: resumeAt)
    }

    /// What the output is, for the audio pipeline panel. Read rather than
    /// observed: a panel that has to be told the device changed would be a
    /// panel nobody trusts.
    var outputDevice: OutputDeviceRec { engine.outputDevice() }
    var outputHealth: OutputHealthRec { engine.outputHealth() }

    func persistSession() {
        guard !queue.isEmpty, queue.indices.contains(playingIndex) else { return }
        PlatformSettings.shared.putString(key: "last_playback_context", value: playbackContext ?? "")
        var tracks = queue
        if duration > 0, tracks.indices.contains(playingIndex) {
            tracks[playingIndex].durationText = QueueEntry.formatDuration(duration)
        }
        LastPlayed.save(
            tracks: tracks,
            index: playingIndex,
            position: position,
            repeatMode: repeatMode,
            shuffleEnabled: shuffleEnabled,
            volume: volume,
            contextID: playbackContextID, contextTitle: playbackContext
        )
    }

    /// Remember where the track at `playingIndex` was left, so the resume can
    /// only ever be applied back to it. See `restoredStart`.
    private func rememberRestoredStart(_ position: Double, of entryId: String? = nil) {
        let id = entryId
            ?? (queue.indices.contains(playingIndex) ? queue[playingIndex].id : current?.id)
        restoredStart = id.map { (entryId: $0, position: position) }
    }

    func restoreSession() {
        guard let snap = LastPlayed.load() else { return }
        let savedContext = PlatformSettings.shared.getString(key: "last_playback_context", default: "")
        playbackContext = snap.contextTitle ?? (savedContext.isEmpty ? nil : savedContext)
        playbackContextID = snap.contextID
        queue = snap.tracks
        playingIndex = snap.index
        current = queue[snap.index]
        position = snap.position
        duration = current?.durationSeconds ?? 0
        repeatMode = snap.repeatMode
        shuffleEnabled = snap.shuffleEnabled
        volume = snap.volume
        repeatAllStash = []
        repeatAllStashSeed = nil
        rememberRestoredStart(snap.position, of: current?.id)
        dolbyRenderer?.stop()
        dolbyRenderer = nil
        engineLoadedId = nil
        loadedSourcePath = nil
        loadedSourceHeaders = [:]
        sourceHeadersByPath.removeAll(keepingCapacity: true)
        state = .paused
        if let entry = current {
            nowPlaying.update(
                id: entry.id, title: entry.title, artist: entry.artist,
                duration: duration, artworkData: entry.artworkData,
                thumbnailUrl: entry.thumbnailUrl, isPlaying: false, position: position
            )
            widgetPublisher.publish(entry: entry, isPlaying: false,
                                    canNext: playingIndex + 1 < queue.count,
                                    canPrevious: playingIndex > 0)
        }
    }

    func playNext(_ entry: QueueEntry) {
        noteLocalIntent()
        let wasEmpty = queue.isEmpty
        var entry = entry
        entry.contextOrder = nil
        entry.fromAutoplay = false
        removeAutoplayDuplicate(of: entry)
        let at = min(playingIndex + 1, queue.count)
        queue.insert(entry, at: at)
        queueEditRevision &+= 1
        persistSession()
        // As `addToQueue`: "play next" on an idle player is a request to play.
        if wasEmpty, isIdle {
            playingIndex = 0
            loadCurrent(0)
            return
        }
        syncEngineQueueNext()
    }

    /// Upstream `playRadio`: seed plus related mix via `next` + QueueBuilder.
    func playRadio(_ entry: QueueEntry, context: String? = nil) {
        play([entry], at: 0, context: context)
    }

    /// SwiftUI `onMove` entry: destination is the pre-remove insertion index.
    func moveQueue(from source: IndexSet, to destination: Int) {
        guard let from = source.first else { return }
        let media3 = destination > from ? destination - 1 : destination
        moveQueueItem(from: from, to: media3)
    }

    /// Media3 `moveMediaItem(from, to)`: the item at `from` lands at `to`.
    /// Upcoming tracks only; a drag never crosses the manual/autoplay boundary.
    func moveQueueItem(from: Int, to requested: Int) {
        guard queue.indices.contains(from), from != playingIndex else { return }
        let section = autoplaySectionStart
        let inMix = from >= section
        let lo = inMix ? section : playingIndex + 1
        let hi = inMix ? queue.count : section
        guard from >= lo, from < hi || (inMix && from < queue.count) else { return }
        let maxTo = inMix ? queue.count - 1 : max(lo, hi - 1)
        var to = min(max(requested, lo), maxTo)
        if !inMix { to = min(to, hi - 1) }
        if to == from || to < lo { return }
        var copy = queue
        var item = copy.remove(at: from)
        if !inMix { item.contextOrder = nil }
        let insertAt = min(max(to, 0), copy.count)
        copy.insert(item, at: insertAt)
        queue = copy
        queueEditRevision &+= 1
        persistSession()
        syncEngineQueueNext()
    }

    /// Where AutoPlay's section begins — heading index and play-next insertion point.
    var autoplaySectionStart: Int {
        Self.autoplaySectionStart(fromAutoplay: queue.map(\.fromAutoplay), currentIndex: playingIndex)
    }

    /// First upcoming index that may be dragged in the manual section.
    var firstMovableQueueIndex: Int {
        min(playingIndex + 1, autoplaySectionStart)
    }

    static func autoplaySectionStart(fromAutoplay: [Bool], currentIndex: Int) -> Int {
        let after = min(max(currentIndex + 1, 0), fromAutoplay.count)
        if after >= fromAutoplay.count { return fromAutoplay.count }
        return (after..<fromAutoplay.count).first { fromAutoplay[$0] } ?? fromAutoplay.count
    }

    /// Upstream `addToQueue`: the item joins the end of what the *listener*
    /// queued, which outranks whatever AutoPlay lined up behind it.
    ///
    /// Adding to an idle player is also how playback *starts*. Upstream inserts
    /// into the player's own playlist, and ExoPlayer takes an item added to an
    /// empty playlist as the thing to play; the port appended to its model and
    /// called `syncEngineQueueNext`, which looks at the item *after* the
    /// playing one — and with nothing playing there is no such item. The song
    /// then simply sat there until Next was pressed.
    func addToQueue(_ entry: QueueEntry) {
        noteLocalIntent()
        let wasEmpty = queue.isEmpty
        var entry = entry
        entry.contextOrder = nil
        entry.fromAutoplay = false
        removeAutoplayDuplicate(of: entry)
        let at = min(autoplaySectionStart, queue.count)
        queue.insert(entry, at: at)
        queueEditRevision &+= 1
        persistSession()
        if wasEmpty, isIdle {
            // Nothing was playing and nothing was queued: this is the queue.
            playingIndex = 0
            loadCurrent(0)
            return
        }
        syncEngineQueueNext()
    }

    private func removeAutoplayDuplicate(of entry: QueueEntry) {
        let duplicateIndices = queue.indices.filter {
            $0 > playingIndex && queue[$0].fromAutoplay && queue[$0].id == entry.id
        }
        guard !duplicateIndices.isEmpty else { return }
        queue.remove(atOffsets: IndexSet(duplicateIndices))
    }

    /// Nothing loaded into the engine and nothing on its way there.
    private var isIdle: Bool {
        engineLoadedId == nil && state != .playing && state != .buffering
    }

    /// Told when *the listener* uses this device's controls, so a party can stop
    /// trying to undo the press for a moment.
    ///
    /// The listener, specifically, and not "whenever the transport changes": a party
    /// binding moves this transport itself several times a minute, and telling it
    /// about its own corrections would leave it permanently convinced that the
    /// listener had just pressed something and it should therefore not correct
    /// anything at all. The binding wraps its own calls in
    /// [withLocalIntentSuppressed].
    ///
    /// A closure rather than a direct reference to the binding, because the controller
    /// is created before anything else exists and a party is not always there.
    @ObservationIgnored var onLocalIntent: (() -> Void)?

    /// How deep the party binding is in the middle of moving the transport itself.
    ///
    /// A counter rather than a flag because reconcile can be re-entered — a load that
    /// finishes can schedule work that seeks — and a boolean cleared by an inner call
    /// would leave the outer one reporting itself as the listener.
    @ObservationIgnored private var intentSuppression = 0

    /// Run `body` without its transport changes being reported as the listener's.
    func withLocalIntentSuppressed<T>(_ body: () -> T) -> T {
        intentSuppression += 1
        defer { intentSuppression -= 1 }
        return body()
    }

    private func noteLocalIntent() {
        guard intentSuppression == 0 else { return }
        onLocalIntent?()
    }

    func togglePlayPause() {
        noteLocalIntent()
        startEngineIfNeeded()
        if state == .buffering {
            pausePlayback()
            return
        }
        if current == nil {
            if !queue.isEmpty { loadCurrent(min(playingIndex, queue.count - 1), refreshAutoplay: false) }
            return
        }
        if engineLoadedId != current?.id {
            // Only when it is still the track the position was saved for.
            let start = restoredStart.flatMap { $0.entryId == current?.id ? $0.position : nil }
            restoredStart = nil
            loadCurrent(playingIndex, startAt: start, refreshAutoplay: false)
            return
        }
        if isPlaying {
            pausePlayback()
        } else {
            // The session may have been interrupted or deactivated while this
            // loaded track was paused. Reactivate it off the main thread before
            // releasing the output callback; a cold restored track takes the
            // load path above, which already waits for activation before open.
            resumeGeneration &+= 1
            let generation = resumeGeneration
            let selection = playGeneration
            let gate = loadSubmissionGate
            let usesDolby = dolbyRenderer != nil
            // Reflect intent immediately so a second tap cancels this resume.
            state = .playing
            let engine = self.engine
#if os(iOS)
            let retainedActiveSession = AudioSessionManager.isActive
#endif
            let task = Task.detached(priority: .userInitiated) { [weak self] in
                // The engine still owns the loaded source here. Its current
                // format snapshot is enough to prepare the output after the
                // audio session has been reactivated.
                let sourceFormat = engine.nerdStats()
                let matchRate = PlatformSettings.shared.getBoolean(
                    key: "match_source_sample_rate", default: true
                )
                let sessionFormat: AudioSessionManager.Format?
                do {
                    sessionFormat = try await AudioSessionManager.activate(
                        preferredSampleRate: matchRate
                            ? (sourceFormat.sampleRate > 0 ? Double(sourceFormat.sampleRate) : nil)
                            : nil,
                        restartRouting: true
                    )
                } catch {
                    await MainActor.run { [weak self] in
                        guard let self, self.resumeGeneration == generation,
                              self.playGeneration == selection else { return }
                        self.audioActivationFailed(error)
                    }
                    return
                }
                do {
                    _ = try gate.performIfCurrent(generation: selection) {
                        if usesDolby { return }
#if os(iOS)
                        // Keep RemoteIO's buffered audio and decoder history
                        // when the activated hardware format still agrees;
                        // rebuilding would discard that ring and re-seek AAC.
                        let output = engine.outputDevice()
                        if retainedActiveSession, AudioSessionManager.isActive,
                           let sessionFormat, output.started,
                           Double(output.sampleRate) == sessionFormat.rate,
                           output.channels == sessionFormat.channels {
                            let message = "resume retained output \(output.sampleRate) Hz / \(output.channels) ch"
                            PlaybackDebugLog.shared.record(message)
                            NSLog("[BitChord] %@", message)
                            return
                        }
#endif
                        try engine.prepareTrackOutput(
                            sourceRate: sourceFormat.sampleRate,
                            sourceChannels: sourceFormat.channels,
                            sourceBitDepth: sourceFormat.bitDepth,
                            codec: sourceFormat.codec,
                            losslessPcm: ["FLAC", "ALAC", "PCM", "PCM Float"].contains(sourceFormat.codec),
                            matchSourceRate: matchRate,
                            sessionRate: sessionFormat?.rate,
                            sessionChannels: sessionFormat?.channels
                        )
                    }
                } catch {
                    NSLog("[BitChord] resume output preparation failed; continuing with current output: \(error)")
                }
                await MainActor.run { [weak self] in
                    guard let self,
                          self.resumeGeneration == generation,
                          self.playGeneration == selection, self.isPlaying,
                          self.current?.id == self.engineLoadedId,
                          let entry = self.current
                    else { return }
                    do {
                        self.prepareNowPlayingForPlayback(entry: entry, duration: self.duration, position: self.position)
                        if let renderer = self.dolbyRenderer { renderer.play() } else { try engine.play() }
                        self.state = .playing
                        let speed = Double(PlatformSettings.shared.getFloat(key: "playback_speed", default: 1))
                        self.playbackRate = speed.isFinite ? min(max(speed, 0.5), 2.0) : 1.0
                        self.positionSampledAt = Date()
                        self.nowPlaying.updateRate(speed, position: self.position)
                        self.nowPlaying.playbackDidStart()
                    } catch {
                        self.nowPlaying.updateRate(0, position: self.position)
                        self.state = .paused
                        self.lastError = "Audio output could not resume: \(error)"
                    }
                }
            }
#if os(iOS)
            playbackStartTask = task
#else
            _ = task
#endif
        }
    }

    private func pausePlayback(releaseAudioSession: Bool = false) {
        resumeGeneration &+= 1
        wasInterrupted = false
        let loading = state == .buffering
        if !loading { position = playbackPosition }
        dolbyRenderer?.pause()
        positionSampledAt = Date()
        state = .paused
        #if os(macOS)
        Task { await HeadphoneRouting.shared.releaseWhenIdle() }
        #endif
        try? engine.pause()
        if loading {
            playGeneration &+= 1
            dolbyRenderer?.stop()
            dolbyRenderer = nil
            engineLoadedId = nil
            let engine = self.engine
            loadSubmissionGate.advance(to: playGeneration) { try? engine.stop() }
        }
        nowPlaying.updateRate(0, position: position)
        persistSession()
#if os(iOS)
        // Ordinary pause is a resumable media session. Deactivation drops
        // native eligibility and invalidates RemoteIO; retain activation until
        // playback is abandoned or another app interrupts this session.
        if releaseAudioSession || loading {
            deactivateAudioSessionIfIdle()
        } else {
            debugLog.record("paused playback retains audio session active=\(AudioSessionManager.isActive)")
        }
#else
        deactivateAudioSessionIfIdle()
#endif
    }

    private func deactivateAudioSessionIfIdle() {
        let intent = resumeGeneration
        Task { [weak self] in
            guard let self, self.resumeGeneration == intent,
                  !self.isPlaying, !self.isBuffering else { return }
            await AudioSessionManager.deactivate()
            // A play/pause/load that landed *during* the deactivation wins:
            // the guard above ran before the await, so without this the call
            // pulls the session out from under a playing engine and strands
            // it on a dead unit — "paused, never reengages". Come back up
            // whenever the intent moved on or anything is audible.
            if self.isPlaying || self.isBuffering {
                let recoveryIntent = self.resumeGeneration
                let selection = self.playGeneration
                do {
                    _ = try await AudioSessionManager.activate()
                    if self.resumeGeneration == recoveryIntent, self.playGeneration == selection, self.isPlaying {
                        self.nowPlaying.requestPrimaryIfPossible(reason: "deactivation recovery")
                    }
                } catch {
                    guard self.resumeGeneration == recoveryIntent, self.playGeneration == selection else { return }
                    self.audioActivationFailed(error)
                }
            }
        }
    }

    func next() {
        advanceToNext(userInitiated: true)
    }

    private func advanceToNext(userInitiated: Bool) {
        if userInitiated { noteLocalIntent() }
        guard !queue.isEmpty else { return }
        let target: Int
        if playingIndex + 1 < queue.count {
            target = playingIndex + 1
        } else if repeatMode == .all {
            target = 0
        } else {
            return
        }
        // The upcoming track is armed while its predecessor plays
        // (syncEngineQueueNext), so a skip promotes it instantly instead of
        // re-resolving it over the network. Falls through to a full load
        // when nothing is armed.
        if trySkipToArmed(target) {
            if userInitiated {
                maybeAutoplay(force: true)
            } else {
                maybeAutoplay(lowWaterRefill: true)
            }
            return
        }
        loadCurrent(target, refreshAutoplay: userInitiated)
    }

    /// Promotes the engine's armed successor when it is the requested queue
    /// entry, and adopts it like a completed load. Returns false when nothing
    /// suitable is armed — the caller loads normally.
    ///
    /// The peek comes first because promoting has the side effect of moving
    /// the engine: only the picked track may be promoted, never whatever
    /// happens to be armed (repeat-one arms the current track itself).
    private func trySkipToArmed(_ target: Int) -> Bool {
        // A paused/inactive output must take the load path, which awaits
        // activation. Instant promotion is reserved for an audible session.
        guard queue.indices.contains(target) else { return false }
        guard isPlaying else { return false }
        #if os(iOS)
        guard AudioSessionManager.isActive else { return false }
        #endif
        let entry = queue[target]
        guard let queued = engine.pendingTrack(),
              queued.title == entry.title, queued.artist == entry.artist
        else { return false }
        guard let info = try? engine.skipToPending() else {
            // Armed a moment ago but already consumed (a natural handoff may
            // have landed it meanwhile): if the queue is already there, the
            // work is done; otherwise load it properly.
            return current?.id == entry.id && engineLoadedId == entry.id
        }
        // The engine moved under a concurrent edit; converge on the target
        // with a full load rather than playing the wrong track.
        guard info.title == entry.title, info.artist == entry.artist else {
            loadCurrent(target, refreshAutoplay: false)
            return true
        }
        // Promoting an armed successor is a new selection too. Invalidate
        // outgoing loads/upgrades just as the full load path does.
        playGeneration &+= 1
        resumeGeneration &+= 1
        loadSubmissionGate.invalidate(to: playGeneration)
        // Ensure the promoted output is unmuted; this is idempotent for an
        // already playing session.
        do { try engine.play() } catch {
            loadCurrent(target, refreshAutoplay: false)
            return true
        }
        let headers = sourceHeadersByPath.removeValue(forKey: info.source) ?? [:]
        PlaybackTrackerBridge.shared.onTrackChanged(positionSeconds: Int64(position))
        loadDidSucceed(entry: entry, index: target, info: info, startAt: 0, headers: headers)
        return true
    }

    func previous() {
        noteLocalIntent()
        if position > Self.backRestartsAfter {
            seek(to: 0)
            return
        }
        if playingIndex > 0 {
            loadCurrent(playingIndex - 1)
        } else if repeatMode == .all, queue.count > 1 {
            loadCurrent(queue.count - 1)
        } else {
            seek(to: 0)
        }
    }

    func cycleRepeat() {
        let previous = repeatMode
        let next: RepeatMode
        switch previous {
        case .off: next = .all
        case .all: next = .one
        case .one: next = .off
        }
        // Repeat-all loops the queue as it stands; AutoPlay's endless supply of
        // new tracks is the opposite, so they come out first (upstream
        // onRepeatModeChanged / stashAutoplayTracks). Leaving ALL — including
        // the step ALL→ONE — puts them back when the seed track is still current.
        if next == .all {
            stashAutoplayTracks()
        } else if previous == .all {
            restoreAutoplayTracks()
        }
        repeatMode = next
        autoplayRefresh.invalidate()
        persistSession()
        syncEngineQueueNext()
        maybeAutoplay(force: true)
    }

    func toggleShuffle() {
        shuffleEnabled.toggle()
        applyListOrder()
    }

    /// Reorders only list slots. Played tracks, manual additions and the separate
    /// recommendation tail keep their places when playback mode changes.
    private func applyListOrder() {
        queue = PlaybackQueuePolicy.orderList(
            queue, after: playingIndex, automix: automixSequencingEnabled,
            shuffle: shuffleEnabled, scores: tasteScores(queue)
        )
        queueEditRevision &+= 1
        persistSession()
        syncEngineQueueNext()
        scheduleSequencing()
    }

    func smartSequencingPreferenceChanged() {
        applyListOrder()
    }

    func seek(to seconds: Double) {
        noteLocalIntent()
        // Queues and returns: the playhead is the engine's to move, and waiting
        // for it here would stall whatever thread asked — usually the main one.
        guard engineLoadedId == current?.id, engineLoadedId != nil else { return }
        if seconds <= 0.1, position > Self.backRestartsAfter, isPlaying,
           let id = historyVideoID {
            PlaybackTrackerBridge.shared.onTrackChanged(positionSeconds: Int64(position))
            PlaybackTrackerBridge.shared.onPlaying(videoId: id)
        }
        if let dolbyRenderer { dolbyRenderer.seek(seconds) } else { engine.seek(seconds: seconds) }
        nowPlaying.update(position: seconds)
        position = seconds
        positionSampledAt = Date()
    }

    func removeFromQueue(at offsets: IndexSet) {
        let adjusted = offsets.filter { $0 != playingIndex && queue.indices.contains($0) }
        guard !adjusted.isEmpty else { return }
        let removedIds = Set(adjusted.map { queue[$0].id })
        queue.remove(atOffsets: IndexSet(adjusted))
        removedIds.forEach { QualityUpgrade.forget($0) }
        playingIndex -= adjusted.filter { $0 < playingIndex }.count
        playingIndex = min(playingIndex, max(0, queue.count - 1))
        queueEditRevision &+= 1
        persistSession()
        syncEngineQueueNext()
    }

    func removeFromQueue(at index: Int) {
        removeFromQueue(at: IndexSet(integer: index))
    }

    func updateCrossfade(seconds: Int) {
        try? engine.setCrossfadeWindow(seconds: Double(seconds))
    }

    func updateSpatial(enabled: Bool) {
        applySpatialPreference(enabled: enabled)
    }

    private func applySpatialPreference(enabled: Bool? = nil) {
        let requested = enabled ?? PlatformSettings.shared.getBoolean(key: "spatial_audio", default: false)
        let effective = requested && dolbyRenderer == nil && AudioRouteState.shared.permitsCustomSpatial
        try? engine.setSpatialEnabled(enabled: effective)
        if effective && soundMode == "ENHANCED" { headTracker.start(engine: engine) }
        else { headTracker.stop() }
    }

    func updateSpeed(_ speed: Float) {
        let sampledPosition = isPlaying ? playbackPosition : position
        let sampledAt = Date()
        dolbyRenderer?.rate = speed
        if isPlaying { dolbyRenderer?.play() }
        try? engine.setPlaybackSpeed(speed: speed)
        let rate = Double(speed)
        playbackRate = rate.isFinite ? min(max(rate, 0.5), 2.0) : 1.0
        position = sampledPosition
        positionSampledAt = sampledAt
        nowPlaying.updateRate(isPlaying ? Double(speed) : 0, position: sampledPosition)
    }

    func updateSkipSilence(enabled: Bool) {
        try? engine.setSkipSilence(enabled: enabled)
    }

    /// Inference threads for the Automix analysis tier: 1 / 2 / 4, upstream's
    /// own numbers for EFFICIENT / BALANCED / PERFORMANCE.
    var automixInferenceThreads: Int {
        switch automixPerformanceMode {
        case "EFFICIENT": return 1
        case "PERFORMANCE": return 4
        default: return 2
        }
    }

    func refreshPlaybackRegions() {
        for task in regionTasks.values { task.cancel() }; regionTasks = [:]; preparedRegionSources = []
        if let source = loadedSourcePath { prepareRegions(source: source, videoId: resolvedVideoIds[source] ?? DownloadStore.shared.provenance(for: source)) }
        syncEngineQueueNext()
    }
    private func prepareRegions(source: String, videoId: String?) {
        guard !preparedRegionSources.contains(source), regionTasks[source] == nil else { return }
        let generation = playGeneration, revision = queueNextRevision
        let trim = automixEnabled || PlatformSettings.shared.getBoolean(key: "trim_edge_silence", default: false)
        let skip = automixEnabled || PlatformSettings.shared.getBoolean(key: "skip_non_music", default: false)
        let engine = self.engine
        regionTasks[source] = Task { [weak self] in
            for _ in 0..<300 {
                let regions = await PlaybackRegionStore.shared.regions(path: source, videoId: videoId, trimEdges: trim, skipSegments: skip)
                guard !Task.isCancelled, let self, self.playGeneration == generation,
                      self.loadedSourcePath == source || self.queueNextRevision == revision else { break }
                try? engine.setPlaybackRegions(source: source, regions: regions)
                let complete = !FileManager.default.fileExists(atPath: source + ".grow") || FileManager.default.fileExists(atPath: source + ".complete")
                if complete || !trim {
                    self.preparedRegionSources.insert(source); self.regionTasks[source] = nil
                    self.debugLog.record("playback regions start=\(regions.audibleStartSeconds) end=\(String(describing: regions.audibleEndSeconds)) excluded=\(regions.excluded.count)")
                    // The mixer updates waiting plans without discarding armed voices.
                    return
                }
                try? await Task.sleep(for: .seconds(1))
            }
            self?.regionTasks[source] = nil
        }
    }

    private func scheduleLoudnessMeasurement() {
        loudnessMeasurementTask?.cancel()
        guard soundMode == "ENHANCED", loudnessMode != "OFF", let path = loadedSourcePath,
              !path.hasPrefix("http:"), !path.hasPrefix("https:") else { return }
        let engine = self.engine
        loudnessMeasurementTask = Task {
            do {
                // Partial downloads cannot yield a whole-recording loudness.
                for _ in 0..<300 {
                    try Task.checkCancellation()
                    if !FileManager.default.fileExists(atPath: path + ".grow") || FileManager.default.fileExists(atPath: path + ".complete") { break }
                    try await Task.sleep(for: .seconds(1))
                }
                try Task.checkCancellation()
                let cached = await StreamFileCache.shared.measuredLoudness(at: path)
                let measurement: LoudnessMeasurement
                if let cached { measurement = cached }
                else {
                    measurement = try await Task.detached(priority: .utility) { try engine.measureLoudness(source: path) }.value
                    await StreamFileCache.shared.storeMeasurement(measurement, at: path)
                }
                try Task.checkCancellation()
                // The native command discards this result if the source changed.
                try engine.setLoudnessMeasurement(source: path, measurement: measurement)
            } catch is CancellationError { }
            catch { NSLog("[BitChord] loudness measurement unavailable: \(error)") }
        }
    }

    nonisolated private static func storedClarityTuning() -> ClarityTuning {
        let raw = PlatformSettings.shared.getString(key: "clarity_preset", default: "REFERENCE")
        let preset: ClarityPreset = raw == "SPEAKER" ? .speaker : raw == "HEADPHONE" ? .headphone : raw == "DAC" ? .dac : .reference
        let trims = PlatformSettings.shared.getString(key: "clarity_trims", default: "").split(separator: ",").compactMap { Float($0) }
        return ClarityTuning(preset: preset, wet: PlatformSettings.shared.getFloat(key: "clarity_wet", default: 1), trimsDb: trims.count == 8 ? trims : Array(repeating: 0, count: 8))
    }
    nonisolated private static func storedLoudnessMode() -> LoudnessMode {
        let legacy = PlatformSettings.shared.getBoolean(key: "loudness_normalization", default: false)
        let raw = PlatformSettings.shared.getString(key: "loudness_mode", default: legacy ? "TRACK" : "OFF")
        return raw == "ALBUM" ? .album : raw == "TRACK" ? .track : .off
    }
    func updateSoundMode(_ value: String) {
        soundMode = value == "ENHANCED" ? "ENHANCED" : "TRANSPARENT"
        PlatformSettings.shared.putString(key: "sound_mode", value: soundMode)
        try? engine.setSoundMode(mode: soundMode == "ENHANCED" ? .enhanced : .transparent)
        applySpatialPreference()
        scheduleLoudnessMeasurement()
    }
    func updateClarity(preset: String? = nil, wet: Double? = nil) {
        if let preset { clarityPreset = preset; PlatformSettings.shared.putString(key: "clarity_preset", value: preset) }
        if let wet { clarityWet = min(max(wet, 0), 1); PlatformSettings.shared.putFloat(key: "clarity_wet", value: Float(clarityWet)) }
        try? engine.setClarityTuning(tuning: Self.storedClarityTuning())
    }
    func updateLoudnessMode(_ value: String) {
        loudnessMode = ["TRACK", "ALBUM"].contains(value) ? value : "OFF"
        loudnessNormalization = loudnessMode != "OFF"
        PlatformSettings.shared.putString(key: "loudness_mode", value: loudnessMode)
        PlatformSettings.shared.putBoolean(key: "loudness_normalization", value: loudnessNormalization)
        try? engine.setLoudnessMode(mode: Self.storedLoudnessMode())
        scheduleLoudnessMeasurement()
    }

    func updateOutputPcmMode(_ mode: String) {
        let valid = Self.migrateOutputPcmMode(mode)
        outputPcmMode = valid
        // PlatformSettings directly: the typed shared setter only exists in
        // source until the shared framework is rebuilt (see AppSettings.kt).
        PlatformSettings.shared.putString(key: "output_pcm_mode", value: valid)
        try? engine.setOutputPcmMode(mode: valid)
    }

    func updateBitPerfectOutput(_ enabled: Bool) {
        bitPerfectOutput = enabled
        PlatformSettings.shared.putBoolean(key: "bit_perfect_output", value: enabled)
        try? engine.setBitPerfectEnabled(enabled: enabled)
        if enabled, isPlaying, current != nil {
            restartCurrent(keepingPosition: true)
        }
    }

    func updateMatchSourceSampleRate(_ enabled: Bool) {
        matchSourceSampleRate = enabled
        PlatformSettings.shared.putBoolean(key: "match_source_sample_rate", value: enabled)
        if isPlaying, current != nil {
            restartCurrent(keepingPosition: true)
        }
    }

    /// The stored PCM mode with the removed rung migrated away.
    ///
    /// Upstream's enum never had PCM_24 (Media3's sink has no packed-24 path);
    /// the three-way picker did. Anything stored from then maps to the
    /// lossless path rather than the lossy one.
    nonisolated static func migrateOutputPcmMode(_ mode: String? = nil) -> String {
        #if os(iOS)
        // iOS CoreAudio RemoteIO operates exclusively with 32-bit float streams.
        // Normalize any persisted legacy value so all layers agree.
        let currentStored = PlatformSettings.shared.getString(key: "output_pcm_mode", default: "FLOAT_32")
        if currentStored != "FLOAT_32" {
            PlatformSettings.shared.putString(key: "output_pcm_mode", value: "FLOAT_32")
        }
        return "FLOAT_32"
        #else
        let stored = mode ?? PlatformSettings.shared.getString(key: "output_pcm_mode", default: "FLOAT_32")
        let migrated: String
        switch stored {
        case "PCM_16": migrated = "PCM_16"
        case "FLOAT_32", "PCM_24": migrated = "FLOAT_32"
        default: migrated = "FLOAT_32"
        }
        // Keep the supported PCM16 selection; only the removed PCM24 rung is
        // migrated to float so the setting, engine and pipeline agree.
        if migrated != stored, mode == nil {
            PlatformSettings.shared.putString(key: "output_pcm_mode", value: migrated)
        }
        return migrated
        #endif
    }

    func updatePreferUsbDac(_ enabled: Bool) {
        preferUsbDac = enabled
        PlatformSettings.shared.putBoolean(key: "prefer_usb_dac", value: enabled)
        try? engine.setPreferUsbDac(enabled: enabled)
    }

    func updateLoudnessNormalization(_ enabled: Bool) {
        updateLoudnessMode(enabled ? "TRACK" : "OFF")
    }

    func setAutomixPerformanceMode(_ mode: String) {
        let valid = mode == "EFFICIENT" || mode == "PERFORMANCE" ? mode : "BALANCED"
        automixPerformanceMode = valid
        PlatformSettings.shared.putString(key: "automix_performance", value: valid)
        engine.setAutomixPerformance(mode: valid)
    }

    func setSmartVersionAlignment(_ enabled: Bool) {
        smartVersionAlignment = enabled
        PlatformSettings.shared.putBoolean(key: "smart_version_alignment", value: enabled)
    }

    func updateHideSongStatus(_ hidden: Bool) {
        hideSongStatus = hidden
        PlatformSettings.shared.putBoolean(key: "hide_song_status", value: hidden)
    }

    func updatePreferMusicOnly(_ enabled: Bool) {
        preferMusicOnly = enabled
        PlatformSettings.shared.putBoolean(key: "prefer_music_only", value: enabled)
    }

    func updateScrobblePrimaryArtist(_ mode: String) {
        let valid = mode == "album" ? "album" : "track"
        scrobblePrimaryArtist = valid
        PlatformSettings.shared.putString(key: "scrobble_primary_artist", value: valid)
    }

    /// The artist a scrobble credits for `entry`.
    ///
    /// "track" sends the full credit as the catalogue gave it. "album" sends
    /// the lead name alone — upstream `PrimaryArtist`, which splits on ",",
    /// "&" and "＆" and takes the first part, so "A, B & C" scrobbles as "A".
    func scrobbleArtist(for entry: QueueEntry) -> String {
        guard scrobblePrimaryArtist == "album" else { return entry.artist }
        let commaFirst = entry.artist.components(separatedBy: ",").first ?? entry.artist
        let ampSplit = commaFirst.components(separatedBy: " & ").first ?? commaFirst
        let fullWidthSplit = ampSplit.components(separatedBy: " ＆ ").first ?? ampSplit
        let lead = fullWidthSplit.trimmingCharacters(in: .whitespaces)
        return lead.isEmpty ? entry.artist : lead
    }

    /// Renders the equaliser settings into the ten-slot curve and hands it to
    /// the engine (upstream `PlaybackService.applyEqualizer`). The make-up
    /// preamp is computed inside the engine, never here.
    func applyEqualizer() {
        let tuning = Self.currentEqTuning()
        try? engine.setEqTuning(
            enabled: tuning.enabled,
            gainsDb: tuning.gains,
            qs: tuning.qs,
            balance: tuning.balance
        )
    }

    /// The equaliser settings as the engine's ten-slot tuning. Reads only
    /// `PlatformSettings`, so it is safe from the engine-startup task.
    nonisolated static func currentEqTuning() -> (enabled: Bool, gains: [Float], qs: [Float], balance: Float) {
        let enabled = PlatformSettings.shared.getBoolean(key: "equalizer_enabled", default: false)
        let dynamic = PlatformSettings.shared.getString(key: "equalizer_mode", default: "Dynamic") == "Dynamic"
        let bands = EqualizerTuning.loadBands()
        let toneX = Int(PlatformSettings.shared.getInt(key: "equalizer_tone_x", default: 0))
        let toneY = Int(PlatformSettings.shared.getInt(key: "equalizer_tone_y", default: 0))
        let focused = PlatformSettings.shared.getBoolean(key: "equalizer_focused", default: false)
        let balance = PlatformSettings.shared.getFloat(key: "equalizer_balance", default: 0)
        let curve = dynamic
            ? EqualizerTuning.toneCurve(x: toneX, y: toneY, focused: focused)
            : EqualizerTuning.manualCurve(bands)
        return (
            enabled: enabled,
            gains: curve.gains.map { Float($0) },
            qs: curve.qs.map { Float($0) },
            balance: balance
        )
    }

    private func sleepRemaining(_ deadline: ContinuousClock.Instant) -> Double {
        let parts = ContinuousClock.now.duration(to: deadline).components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
    func startSleep(minutes: Int) { armSleep(seconds: Double(max(0, minutes)) * 60) }
    private func armSleep(seconds: Double) {
        cancelSleep()
        let deadline = ContinuousClock.now.advanced(by: .seconds(max(0, seconds)))
        sleepDeadline = deadline; sleepSecondsRemaining = Int(seconds.rounded(.up))
        let engine = self.engine
        sleepTask = Task.detached(priority: .userInitiated) { [weak self, engine] in
            var displayedSeconds = -1
            while !Task.isCancelled {
                let parts = ContinuousClock.now.duration(to: deadline).components
                let remaining = Double(parts.seconds) + Double(parts.attoseconds) / 1e18
                guard !Task.isCancelled else { return }
                if remaining <= 0 {
                    // Output muting does not wait behind a busy UI actor.
                    try? engine.pause()
                    try? engine.setSleepGain(gain: 1)
                    await MainActor.run { [weak self] in
                        guard let self, self.sleepDeadline == deadline else { return }
                        self.sleepDeadline = nil; self.sleepSecondsRemaining = nil; self.sleepTask = nil
                        self.pausePlayback(releaseAudioSession: true)
                        self.debugLog.record("sleep deadline expired; output paused and gain restored")
                    }
                    return
                }
                try? engine.setSleepGain(gain: Float(min(1, remaining / 6)))
                await MainActor.run { [weak self] in
                    guard let self, self.sleepDeadline == deadline else { return }
                    self.dolbyRenderer?.volume = Float(self.volume * min(1, remaining / 6))
                }
                let whole = Int(remaining.rounded(.up))
                if whole != displayedSeconds {
                    displayedSeconds = whole
                    Task { @MainActor [weak self] in
                        guard let self, self.sleepDeadline == deadline else { return }
                        self.sleepSecondsRemaining = whole
                    }
                }
                try? await Task.sleep(for: .milliseconds(100), clock: .continuous)
            }
        }
    }
    func startSleepAfterTrack() {
        cancelSleep()
        sleepAfterTrack = true
        queueNextRevision &+= 1
        try? engine.holdTrackEnd(hold: true)
        debugLog.record("sleep armed after effective track end")
    }
    func cancelSleep() {
        sleepTask?.cancel(); sleepTask = nil
        sleepDeadline = nil; sleepSecondsRemaining = nil
        sleepAfterTrack = false
        try? engine.setSleepGain(gain: 1)
        dolbyRenderer?.volume = Float(volume * (isDucked ? Self.duckGain : 1))
        try? engine.holdTrackEnd(hold: false)
        syncEngineQueueNext()
    }

    func downloadCurrent() -> DownloadStore.RequestResult? {
        guard let current else { return nil }
        return DownloadStore.shared.download(current)
    }

    func playQueueItem(at index: Int) {
        loadCurrent(index)
    }

    func clearUpcoming() {
        guard playingIndex + 1 < queue.count else { return }
        let removed = queue[(playingIndex + 1)...]
        removed.forEach { QualityUpgrade.forget($0.id) }
        queue.removeSubrange((playingIndex + 1)...)
        queueEditRevision &+= 1
        persistSession()
        syncEngineQueueNext()
    }

    func toggleAutoplay() {
        autoplayEnabled.toggle()
        AppSettings.shared.setAutoplay(value: autoplayEnabled)
        if !autoplayEnabled {
            autoplayRefresh.invalidate()
            // Upstream clears the stash when AutoPlay is switched off mid-loop
            // so ending ALL later does not resurrect dropped suggestions.
            repeatAllStash = []
            repeatAllStashSeed = nil
        } else if repeatMode != .all {
            maybeAutoplay(force: true)
        }
    }

    func toggleAutomix() {
        setAutomixEnabled(!automixEnabled)
    }

    func setAutomixEnabled(_ enabled: Bool) {
        guard automixEnabled != enabled else { return }
        automixEnabled = enabled
        AppSettings.shared.setSmartFadeEnabled(value: enabled)
        refreshPlaybackRegions()
        syncEngineQueueNext()
        applyListOrder()
    }

    func authoriseLastFm() {
        ScrobbleBridge.shared.lastFmAuthUrl(callback: AuthAdapter { ok, message in
            guard ok, let message else { return }
            let parts = message.split(separator: "\n", maxSplits: 1).map(String.init)
            guard parts.count == 2, let url = URL(string: parts[0]) else { return }
            #if os(macOS)
            NSWorkspace.shared.open(url)
            #else
            UIApplication.shared.open(url)
            #endif
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                ScrobbleBridge.shared.lastFmComplete(token: parts[1], callback: AuthAdapter { _, _ in })
            }
        })
    }

    // ---- Engine bridge ------------------------------------------------------

    private func loadCurrent(_ index: Int, startAt: Double? = nil, refreshAutoplay: Bool = true) {
        guard queue.indices.contains(index) else { return }
        startEngineIfNeeded()
        let engineStartupTask = self.engineStartupTask
        let entry = queue[index]
        if current?.id == entry.id, playingIndex == index, engineLoadedId == entry.id,
           state == .buffering || state == .playing {
            return
        }
        durationRepairTask?.cancel()
        playGeneration += 1
        let generation = playGeneration
        resumeGeneration &+= 1
        // A manual selection stops the outgoing voice at once: the listener
        // asked for a different song, not a few more seconds of this one.
        // (Automatic advances never come through here — they ride the
        // engine's armed blend via handoff.) The replacement then loads on
        // the expedited path below: resolve, probe and open, but no Automix
        // analysis — planning a DJ blend for a tap would hold the cut for
        // seconds, and a tap means now.
        dolbyRenderer?.stop()
        dolbyRenderer = nil
        try? engine.pause()
        let stoppingEngine = engine
        loadSubmissionGate.advance(to: generation) { try? stoppingEngine.stop() }
        upgradeFor = nil
        racingLossless = false
        smartMixInProgress = false
        smartTransitionWindow = nil
        pendingAutomixPlan = nil
        mixFadeUntil = nil
        analysisTier = nil
        analysisConfidence = nil
        analysisSources = nil
        automixCueSeconds = nil
        let wasAudible = state == .playing || (state == .paused && engineLoadedId != nil)
        playingIndex = index
        current = entry
        historyVideoID = youtubeVideoID(for: entry)
        let outgoingPosition = position
        position = startAt ?? 0
        duration = 0
        lastError = nil
        state = .buffering
        if refreshAutoplay {
            maybeAutoplay(force: true)
        } else {
            maybeAutoplay(lowWaterRefill: true)
        }
        nowPlaying.updateCommands(canNext: playingIndex + 1 < queue.count || repeatMode == .all, canPrevious: true, canSeek: false)
        dolbyRenderer?.stop()
        dolbyRenderer = nil
        engineLoadedId = nil
        loadedSourcePath = nil
        loadedSourceHeaders = [:]
        sourceHeadersByPath.removeAll(keepingCapacity: true)
        nowPlaying.update(
            id: entry.id, title: entry.title, artist: entry.artist,
            duration: 0, artworkData: entry.artworkData,
            thumbnailUrl: entry.thumbnailUrl, isPlaying: false, position: position
        )
        widgetPublisher.publish(entry: entry, isPlaying: false,
                                canNext: index + 1 < queue.count,
                                canPrevious: index > 0)
        persistSession()
        // Start read-ahead after this selection has loaded (syncEngineQueueNext).
        // Rapid Next taps must not start four speculative resolver walks ahead
        // of the track the listener is actually waiting for.
        if wasAudible {
            PlaybackTrackerBridge.shared.onTrackChanged(positionSeconds: Int64(outgoingPosition))
        }
        let engine = self.engine
        let loadSubmissionGate = self.loadSubmissionGate
        let prefs = ResolvePrefs.current()
        let resume = startAt ?? 0
        let task = Task.detached(priority: .utility) {
            do {
                // In particular, after a cold restore the output task and the
                // track resolver used to race. A quick local/cache resolve
                // could send LoadTrack before the engine had an output stream;
                // the UI then had lyrics and a playing state without audio.
                try await engineStartupTask?.value
                let outcome = try await Self.resolveSource(entry, prefs: prefs)
                let stillCurrent = await MainActor.run { [weak self] in
                    self?.playGeneration == generation
                }
                guard stillCurrent else { return }
                await MainActor.run { [weak self] in
                    guard let self, self.playGeneration == generation else { return }
                    self.noteResolved(entry, outcome: outcome, prefs: prefs)
                }
                let resolved = outcome.source
                if PlaybackCodecCapabilities.shared.canRenderDolby(codec: resolved.codec, headers: resolved.headers) {
                    _ = try await AudioSessionManager.activate(preferredSampleRate: nil)
                    try await self.loadDolby(resolved, entry: entry, index: index, start: resume, generation: generation)
                    return
                }
                // Manual loads cut: no Automix planning on this path. The
                // blend machinery (safety overlap, analysis, re-plan) belongs
                // to the background prefetcher, whose armed track a manual
                // Next promotes directly via trySkipToArmed. Planning here as
                // well would hold an explicit tap for the seconds analysis
                // costs — and a tap means now.
                let start = resume
                // Inspect the resolved source before loading it so the output
                // can request its native clock family (44.1 or 48 kHz) and, on
                // eligible macOS routes, open an exact integer stream before
                // the first decoded samples reach the mixer. Probe failures do
                // not prevent ordinary playback.
                let sourceFormat = try? engine.probeAudioSource(
                    source: resolved.source,
                    headers: resolved.headers
                )
                let currentAfterProbe = await MainActor.run { [weak self] in
                    self?.playGeneration == generation
                }
                guard currentAfterProbe else { return }
                let matchRate = PlatformSettings.shared.getBoolean(
                    key: "match_source_sample_rate", default: true
                )
                let sessionFormat = try await AudioSessionManager.activate(
                    preferredSampleRate: matchRate
                        ? sourceFormat.map { Double($0.sampleRate) }
                        : nil
                )
                let currentAfterActivation = await MainActor.run { [weak self] in
                    self?.playGeneration == generation
                }
                guard currentAfterActivation else { return }
                let loadRequest = LoadRequest(
                    source: resolved.source,
                    title: entry.title,
                    artist: entry.artist,
                    startSeconds: start,
                    plan: nil,
                    headers: resolved.headers,
                    claimedKbps: Swift.UInt32(resolved.kbps),
                    loudnessDb: resolved.loudnessDb,
                    // Not bookkeeping: the mixer schedules a transition against
                    // the end of the outgoing track, and a container that
                    // declares no length gives it nothing to schedule against —
                    // the incoming is then never armed and the queue advances by
                    // a cut. We already know the length.
                    durationSeconds: entry.durationSeconds > 0 ? entry.durationSeconds : resolved.durationSec.map(Double.init)
                )
                // Engine setup and the command submission share one serial
                // lane. If another selection arrives after this request passes
                // the gate, its load is submitted after this one; if it arrives
                // first, this older generation is discarded here.
                guard let info = try loadSubmissionGate.performIfCurrent(generation: generation, {
                    do {
                        try engine.prepareTrackOutput(
                            sourceRate: sourceFormat?.sampleRate ?? 0,
                            sourceChannels: sourceFormat?.channels ?? 0,
                            sourceBitDepth: sourceFormat?.bitDepth ?? 0,
                            codec: sourceFormat?.codec ?? "",
                            losslessPcm: sourceFormat?.losslessPcm ?? false,
                            matchSourceRate: matchRate,
                            sessionRate: sessionFormat?.rate,
                            sessionChannels: sessionFormat?.channels
                        )
                    } catch {
                        NSLog("[BitChord] track output preparation failed; continuing with current output: \(error)")
                    }
                    guard loadSubmissionGate.isCurrent(generation) else { return nil as TrackInfoRec? }
                    return try engine.loadTrackPaused(request: loadRequest)
                }), let info else { return }
                await MainActor.run { [weak self] in
                    guard let self, self.playGeneration == generation else { return }
                    do {
                        self.prepareNowPlayingForPlayback(entry: entry, duration: info.durationSeconds, position: resume)
                        try engine.play()
                        self.currentLoudnessDb = resolved.loudnessDb
                        self.loadDidSucceed(
                            entry: entry, index: index, info: info,
                            startAt: resume, headers: resolved.headers
                        )
                    } catch {
                        self.loadDidFail(entry: entry, error: error)
                    }
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self, self.playGeneration == generation else { return }
                    self.loadDidFail(entry: entry, error: error)
                }
            }
        }
#if os(iOS)
        playbackStartTask = task
#else
        _ = task
#endif
    }

    private func loadDolby(_ source: ResolvedSource, entry: QueueEntry, index: Int, start: Double, generation: UInt64) async throws {
        guard playGeneration == generation else { return }
        let renderer = AppleDolbyRenderer()
        renderer.volume = Float(volume)
        renderer.rate = Float(playbackRate)
        dolbyRenderer = renderer
        applySpatialPreference()
        do {
            let info = try await renderer.prepare(source: source.source, title: entry.title, artist: entry.artist,
                codec: source.codec, headers: source.headers, startAt: start, claimedKbps: UInt32(max(0, source.kbps)))
            guard playGeneration == generation, dolbyRenderer === renderer else { renderer.stop(); return }
            renderer.onEnd = { [weak self, weak renderer] in
                guard let self, self.playGeneration == generation, self.dolbyRenderer === renderer else { return }
                self.handleTrackEnded(.natural, source: source.source)
            }
            renderer.onFailure = { [weak self, weak renderer] in
                guard let self, self.playGeneration == generation, self.dolbyRenderer === renderer else { return }
                self.pausePlayback()
                self.lastError = "The Dolby source stopped serving playable audio."
            }
            prepareNowPlayingForPlayback(entry: entry, duration: info.durationSeconds, position: start)
            renderer.play()
            loadDidSucceed(entry: entry, index: index, info: info, startAt: start, headers: [:])
        } catch {
            renderer.stop()
            if dolbyRenderer === renderer { dolbyRenderer = nil }
            throw error
        }
    }

    /// Resolves the entry's source to an engine-loadable string. Local paths
    /// pass through unchanged; `"yt:<videoId>"` sources go through the
    /// `StreamResolver` to get a real HTTP URL, which has already been probed
    /// and proven to serve audio.
    ///
    /// The fetch goes through the shared `Http` client, so it shares a connection
    /// context with both the `player` request that minted the URL and the probe
    /// that cleared it — upstream's rule about why that has to be one stack. An
    /// earlier version ran a separate fetch here "because URLSession has a
    /// different TLS fingerprint"; that was a symptom of the split, not a cause.
    ///
    /// Upstream's ExoPlayer starts on the first bounded range. So do we: the first
    /// chunk is written and we return that path while later chunks keep appending.
    /// The engine's GrowingFile waits at EOF until `.complete`.
    private struct ResolvedSource: Sendable {
        let source: String
        let headers: [String: String]
        let kbps: Int
        var lossless: Bool = false
        var codec: String? = nil
        var durationSec: Int? = nil
        /// Player-response loudness figure (YouTube only; substitutes, cache
        /// hits and local files carry none). Rides to the engine's
        /// normalization stage with the load.
        var loudnessDb: Double? = nil
        var origin: Origin = .other
        var youtubeVideoId: String? = nil

        enum Origin: Sendable { case local, cache, youtube, substitute, other }

        var format: QualityUpgrade.Format {
            QualityUpgrade.Format(
                codec: codec,
                kbps: kbps > 0 ? kbps : nil,
                lossless: lossless
            )
        }

        func asCandidate() -> QualityUpgrade.Candidate {
            QualityUpgrade.Candidate(
                url: source, headers: headers, format: format, durationSec: durationSec
            )
        }
    }

    private struct ResolveOutcome: Sendable {
        let source: ResolvedSource
        let leftover: Task<QualityUpgrade.Candidate?, Never>?
    }

    /// Completes as soon as either source yields a usable stream. A task group
    /// waits for every child when its scope exits, even after cancellation, so
    /// it must not own the two independent lookups in this first-audio race.
    private actor FirstUsableSourceRace {
        enum Winner: Sendable {
            case substitute(QualityUpgrade.Candidate)
            case youtube(ResolvedSource)
            case none
        }

        private var result: Winner?
        private var lookupFinished = false
        private var fallbackFinished = false
        private var continuation: CheckedContinuation<Winner, Never>?

        func wait() async -> Winner {
            await withCheckedContinuation { continuation in
                if let result {
                    continuation.resume(returning: result)
                } else {
                    self.continuation = continuation
                }
            }
        }

        func finishLookup(_ candidate: QualityUpgrade.Candidate?) {
            guard result == nil else { return }
            if let candidate {
                finish(.substitute(candidate))
            } else {
                lookupFinished = true
                if fallbackFinished { finish(.none) }
            }
        }

        func finishFallback(_ source: ResolvedSource?) {
            guard result == nil else { return }
            if let source {
                finish(.youtube(source))
            } else {
                fallbackFinished = true
                if lookupFinished { finish(.none) }
            }
        }

        private func finish(_ winner: Winner) {
            guard result == nil else { return }
            result = winner
            continuation?.resume(returning: winner)
            continuation = nil
        }
    }

    private struct ResolvePrefs: Sendable {
        let maxKbps: Int
        let wantLossless: Bool
        let jiosaavn: Bool
        let canSubstitute: Bool
        let preferMusicOnly: Bool

        @MainActor
        static func current() -> ResolvePrefs {
            let streamQuality = AppSettings.shared.effectiveAudioQuality(metered: NetworkQuality.shared.metered).name
            NSLog("[BitChord] playback quality requested=\(streamQuality) network=\(NetworkQuality.shared.metered ? "metered" : "unmetered")")
            return ResolvePrefs(
                maxKbps: Int(NetworkQuality.shared.maxKbps),
                wantLossless: streamQuality == "LOSSLESS",
                jiosaavn: PlatformSettings.shared.getBoolean(key: "jiosaavn_enabled", default: true),
                canSubstitute: QualityUpgrade.canSubstituteForYouTube(),
                preferMusicOnly: PlatformSettings.shared.getBoolean(key: "prefer_music_only", default: false)
            )
        }
    }

    private static func resolveSource(_ entry: QueueEntry, prefs: ResolvePrefs) async throws -> ResolveOutcome {
        await DownloadStore.shared.waitUntilReady()
        try Task.checkCancellation()
        if let asset = DownloadStore.shared.asset(for: entry) {
            return ResolveOutcome(source: ResolvedSource(source: asset.path, headers: [:], kbps: asset.kbps,
                lossless: asset.lossless, codec: asset.codec, origin: .local, youtubeVideoId: asset.youtubeVideoId), leftover: nil)
        }
        if entry.source.hasPrefix("saavn:") || entry.id.hasPrefix("saavn:") {
            let id = entry.source.hasPrefix("saavn:") ? String(entry.source.dropFirst(6)) : String(entry.id.dropFirst(6))
            if let hit = await JioSaavn.streamURL(for: id) {
                return ResolveOutcome(
                    source: ResolvedSource(
                        source: hit.url, headers: [:], kbps: hit.kbps,
                        lossless: false, origin: .substitute
                    ),
                    leftover: nil
                )
            }
            throw InnertubeStreamResolver.StreamError(message: "JioSaavn had no stream")
        }
        #if DEBUG
        if entry.source.hasPrefix("dolby-test:") {
            return ResolveOutcome(source: ResolvedSource(source: String(entry.source.dropFirst(11)), headers: [:], kbps: 0, codec: "eac3-joc"), leftover: nil)
        }
        #endif
        guard entry.source.hasPrefix("yt:") else {
            // A file on a remote library plays from its own address, and that address
            // needs the share's credential — the same header the cover fetch and the
            // listing used, asked of the one rule that decides which requests may carry
            // it. Empty for a local path and for a JioSaavn URL, which is why this is
            // safe on the path every non-YouTube row takes.
            return ResolveOutcome(
                source: ResolvedSource(
                    source: entry.source,
                    headers: WebDavBridge.shared.playbackHeaders(fileUrl: entry.source),
                    kbps: 0,
                    codec: ["ac3", "ec3", "eac3"].contains(URL(string: entry.source)?.pathExtension.lowercased() ?? "") ? URL(string: entry.source)?.pathExtension : nil,
                    origin: .local
                ),
                leftover: nil
            )
        }
        let videoId = String(entry.source.dropFirst(3))
        if let growing = streamGate.lock.withLock({ streamGate.growing[videoId] }),
           FileManager.default.fileExists(atPath: growing) {
            return ResolveOutcome(
                source: ResolvedSource(
                    source: growing, headers: [:], kbps: 0, durationSec: streamGate.lock.withLock { streamGate.durations[videoId] }, origin: .cache
                ),
                leftover: nil
            )
        }
        // A track the listener has reverted is held on YouTube's own upload, so
        // there is nothing to look for: a substitute found here would be the
        // exact thing they rejected. This has to be checked *before* the lookup
        // rather than after it, or a revert still costs a network round trip to
        // arrive at the answer it already knew.
        if OriginalVersion.shared.isPinned(videoId: videoId) {
            let source = try await Self.resolveYouTube(videoId: videoId, prefs: prefs)
            return ResolveOutcome(source: source, leftover: nil)
        }
        if let cached = await StreamFileCache.shared.path(for: videoId, maxKbps: prefs.maxKbps, requireLossless: prefs.wantLossless) {
            let metadata = await StreamFileCache.shared.metadata(at: cached)
            let cachedDuration = metadata?.durationSeconds
            return ResolveOutcome(
                source: ResolvedSource(
                    source: cached, headers: [:], kbps: metadata?.kbps ?? 0, lossless: QualityUpgrade.Format.isLosslessCodec(metadata?.codec), codec: metadata?.codec, durationSec: cachedDuration, loudnessDb: metadata?.relativeLoudnessDb, origin: .cache, youtubeVideoId: metadata?.youtubeVideoId ?? videoId
                ),
                leftover: nil
            )
        }
        return try await resolveWithModulePriority(entry, videoId: videoId, prefs: prefs)
    }

    /// Upstream `resolveWithModulePriority`: start YouTube and substitutes
    /// together. First usable URL wins so a slow lookup cannot hold the first
    /// note hostage. A lookup that loses is **not** cancelled — it is handed
    /// to QualityUpgrade as `inFlight`.
    private static func resolveWithModulePriority(
        _ entry: QueueEntry, videoId: String, prefs: ResolvePrefs
    ) async throws -> ResolveOutcome {
        let lookup = Task<QualityUpgrade.Candidate?, Never> {
            await Self.resolveSubstitute(entry, prefs: prefs)?.asCandidate()
        }
        let fallback = Task<ResolvedSource, Error> {
            try await Self.resolveYouTube(videoId: videoId, prefs: prefs)
        }

        // Prefer-music-only for a music video: the video's own upload is the
        // wrong answer when the catalogue audio was asked for, so the race is
        // not run at all — the substitute lookup is awaited, and YouTube's
        // upload is only the fallback when the lookup misses. Upstream does the
        // same switch after the fact (`switchToMusicOnly`); here the wait
        // happens before anything starts, so the video never plays first.
        if prefs.preferMusicOnly, entry.isVideo {
            if let stream = await lookup.value {
                fallback.cancel()
                return ResolveOutcome(
                    source: ResolvedSource(
                        source: stream.url, headers: stream.headers,
                        kbps: stream.format.kbps ?? 0,
                        lossless: stream.format.lossless, codec: stream.format.codec,
                        durationSec: stream.durationSec,
                        origin: .substitute
                    ),
                    leftover: nil
                )
            }
            return ResolveOutcome(source: try await fallback.value, leftover: nil)
        }

        let race = FirstUsableSourceRace()
        _ = Task { await race.finishLookup(await lookup.value) }
        _ = Task { await race.finishFallback(try? await fallback.value) }

        switch await race.wait() {
        case .substitute(let stream):
            fallback.cancel()
            let source = ResolvedSource(
                source: stream.url, headers: stream.headers,
                kbps: stream.format.kbps ?? 0,
                lossless: stream.format.lossless, codec: stream.format.codec,
                durationSec: stream.durationSec,
                origin: .substitute
            )
            return ResolveOutcome(source: source, leftover: nil)
        case .youtube(let source):
            // Preserve the slower substitute lookup for the in-playback quality
            // upgrade path instead of making it delay the first audible sample.
            return ResolveOutcome(source: source, leftover: lookup)
        case .none:
            // Preserve the resolver's actual failure instead of replacing
            // account/CDN errors with an uninformative "No stream".
            return ResolveOutcome(source: try await fallback.value, leftover: nil)
        }
    }

    /// Innertube URL + growing local file, the path that starts playback earliest.
    ///
    /// ## Why there is no retry loop, and what replaces it
    ///
    /// There used to be one: on a 403, ask for the same URL again. That is the
    /// worst available response, because the URL is not stale data — a googlevideo
    /// URL is *bound to the session that minted it*, and re-fetching the same one
    /// with the same headers is the single most reliable way to talk a session
    /// into being throttled. It also cannot succeed: the reason the first fetch
    /// was refused is the same reason the second will be.
    ///
    /// What replaces it is a *fresh player request*, which is a different thing:
    ///
    ///  - The bridge has already reported the refusal to the resolver, which forgot
    ///    the URL and stood the client that minted it down. So the second attempt
    ///    asks `player` again and gets a **new URL, usually from a different
    ///    client** — the variable that actually changed is the one that matters.
    ///  - It happens **once**. A second refusal means the problem is not this
    ///    track's URL, and a third attempt would be a session hammering itself.
    ///
    /// A *transport* failure is the opposite case and deliberately does not
    /// re-resolve: the URL was served once, so it is alive, and handing it to the
    /// engine — which has its own connection management and its own retries — is a
    /// better second chance than minting a new URL for a problem the new URL would
    /// not fix.
    private static func resolveYouTube(videoId: String, prefs: ResolvePrefs) async throws -> ResolvedSource {
        let stream: ResolvedYouTubeStream
        do {
            stream = try await InnertubeStreamResolver.shared.resolve(videoId: videoId, maxKbps: prefs.maxKbps)
        } catch {
            // The per-client reasons, which the shared module carries and the
            // sentence a listener sees does not. Recorded here because this is where
            // the debug log lives, and a report that says "playback failed" is worth
            // nothing next to one that says which client refused and why.
            if let streamError = error as? InnertubeStreamResolver.StreamError {
                PlaybackDebugLog.shared.record(streamError.raw, about: videoId)
            }
            throw error
        }
        if let seconds = stream.durationSeconds, seconds > 0 {
            streamGate.lock.withLock {
                streamGate.durations[videoId] = seconds
            }
        }
        do {
            let localPath = try await streamViaKtor(
                videoId: videoId, url: stream.url, headers: stream.headers, codec: stream.mimeType.lowercased().contains("opus") ? "Opus" : "AAC", kbps: stream.kbps, relativeLoudnessDb: stream.loudnessDb, youtubeVideoId: videoId, durationSeconds: stream.durationSeconds)
            return ResolvedSource(
                source: localPath, headers: [:], kbps: stream.kbps,
                durationSec: stream.durationSeconds, loudnessDb: stream.loudnessDb, origin: .youtube, youtubeVideoId: videoId
            )
        } catch {
            let reason = (error as? InnertubeStreamResolver.StreamError)?.message
            if StreamDownloadBridge.shared.isRefusal(message: reason),
               let code = StreamDownloadBridge.shared.refusalCode(message: reason) {
                DebugLog.shared.d(
                    message: "\(videoId): refused with \(code); the URL is dead, "
                        + "so asking for a new one"
                )
                // The stand-down above already happened inside the bridge.
                let fresh = try await InnertubeStreamResolver.shared.resolve(
                    videoId: videoId, maxKbps: prefs.maxKbps
                )
                do {
                    let localPath = try await streamViaKtor(
                        videoId: videoId, url: fresh.url, headers: fresh.headers, codec: fresh.mimeType.lowercased().contains("opus") ? "Opus" : "AAC", kbps: fresh.kbps, relativeLoudnessDb: fresh.loudnessDb, youtubeVideoId: videoId, durationSeconds: fresh.durationSeconds)
                    return ResolvedSource(
                        source: localPath, headers: [:], kbps: fresh.kbps,
                        durationSec: fresh.durationSeconds, loudnessDb: fresh.loudnessDb, origin: .youtube, youtubeVideoId: videoId
                    )
                } catch {
                    // Refused again, or never served. Say so rather than handing
                    // on a URL already known to be refused — the engine would
                    // retry it internally for as long as it liked.
                    throw InnertubeStreamResolver.StreamError(
                        message: "Refused (\(code)) and refused again on a fresh URL"
                    )
                }
            }
            DebugLog.shared.d(message: "\(videoId): stream failed: \(reason ?? "\(error)")")
            return ResolvedSource(
                source: stream.url, headers: stream.headers, kbps: stream.kbps,
                durationSec: stream.durationSeconds, loudnessDb: stream.loudnessDb, origin: .youtube, youtubeVideoId: videoId
            )
        }
    }

    /// Catalogues ranked above YouTube — first match that is the same recording.
    /// The cross-source race, delegated to the shared resolver.
    ///
    /// This used to be a hand-rolled `withTaskGroup` over the custom HTTP source,
    /// the JS module host and JioSaavn, with "JioSaavn must beat 256 kbps" as the
    /// only quality bar, no notion of the user's ranking, and no recording check at
    /// all beyond a runtime comparison the caller had to remember to apply. It could
    /// not be made correct without the parts that are judgement, which now live in
    /// the shared module's `SourceResolver`:
    ///
    ///  - The track is matched by `TrackMatcher` before anything is opened, so a
    ///    cover cannot be substituted for the recording the listener picked.
    ///  - Rank decides who is asked; the race decides who answers first. The two
    ///    are not the same thing, and only the first one is a list.
    ///  - `playingDurationSec` set routes this through the *upgrade* path, whose bar
    ///    is "beats what is actually playing" rather than "satisfies the request",
    ///    and which waits for every source so a slow one holding the FLAC still
    ///    gets to serve it mid-track rather than being dropped for a fast 320.
    private static func resolveSubstitute(
        _ entry: QueueEntry, prefs: ResolvePrefs, waitForAll: Bool = false,
        playingDurationSec: Int? = nil, playing: QualityUpgrade.Format? = nil
    ) async -> ResolvedSource? {
        // Nothing configured outranks YouTube, so the race cannot be won and asking
        // would be pure latency. Answerable from the source list alone, with no
        // search, which is why it is safe to call before the track is resolved.
        guard prefs.canSubstitute else { return nil }

        let stream = await SourceSubstitution.substitute(
            title: entry.title,
            artist: entry.artist,
            durationSec: playingDurationSec,
            album: entry.albumName,
            isExplicit: entry.isExplicit.map { KotlinBoolean(value: $0) },
            isVideo: entry.isVideo,
            playing: (playing ?? (waitForAll ? QualityUpgrade.Format(codec: nil, kbps: nil, lossless: false) : nil)).map { SourceSubstitution.Format(codec: $0.codec, kbps: $0.kbps, lossless: $0.lossless) }
        )
        guard let stream else { return nil }
        return ResolvedSource(
            source: stream.url,
            headers: stream.headers,
            kbps: stream.kbps ?? 0,
            lossless: stream.lossless, codec: stream.codec,
            durationSec: stream.durationSec,
            origin: .substitute
        )
    }

    private static func resolveCustom(title: String, artist: String) async -> ResolvedSource? {
        await withCheckedContinuation { cont in
            SourceBridge.shared.resolveCustom(title: title, artist: artist, quality: "LOSSLESS", callback: CustomStreamAdapter { json, _ in
                guard let json, let data = json.data(using: .utf8),
                      let hit = try? JSONDecoder().decode(CustomHit.self, from: data) else {
                    cont.resume(returning: nil)
                    return
                }
                cont.resume(returning: ResolvedSource(
                    source: hit.url, headers: [:], kbps: hit.kbps,
                    lossless: hit.lossless == true, origin: .substitute
                ))
            })
        }
    }

    private struct CustomHit: Codable {
        let url: String
        let kbps: Int
        let lossless: Bool?
    }

    /// Warm the immediate successor after foreground playback loads. Back
    /// reuses tracks already fetched into the stream cache. Keeping read-ahead
    /// bounded avoids a burst of obsolete player walks during rapid Next taps.
    private func warmUpcoming(around index: Int, generation: UInt64) {
        // Repeat-one never arms a different next track into the engine, but the
        // song after the loop still has to be measured while the loop runs —
        // otherwise turning repeat off starts a cold whole-track decode with
        // seconds left (upstream requestAnalysisAround). Automix self-mix only
        // needs the current file, which is already loaded.
        // Previously played tracks are already in the stream cache. Resolve
        // only the immediate successor, keeping rapid navigation from flooding
        // the provider with obsolete requests two tracks ahead and behind.
        let prefetch = queue.indices.contains(index + 1) ? [queue[index + 1]] : []
        guard !prefetch.isEmpty else { return }
        let prefs = ResolvePrefs.current()
        for entry in prefetch {
            let id = entry.id
            Task.detached(priority: .userInitiated) { [weak self] in
                let stillQueued = await MainActor.run { [weak self] in
                    guard let self else { return false }
                    return self.playGeneration == generation && self.queue.contains { $0.id == id }
                }
                guard stillQueued else { return }
                _ = try? await Self.resolveSource(entry, prefs: prefs)
            }
        }
    }

    private final class StreamGate: @unchecked Sendable {
        let lock = NSLock()
        var tasks: [String: Task<String, Error>] = [:]
        /// Path of a download that has its first bytes, set before the
        /// downloader's continuation resumes so a second resolve cannot miss it.
        var growing: [String: String] = [:]
        var growingQuality: [String: String] = [:]
        var growingKbps: [String: Int] = [:]
        var durations: [String: Int] = [:]
    }

    private static let streamGate = StreamGate()

    /// Starts playback as soon as the first range is on disk — up to a megabyte,
    /// or half that for a client that caps lower. Remaining ranges keep
    /// appending; [StreamFileCache] is filled when the last one lands so a
    /// re-tap does not fetch again.
    private static func streamViaKtor(
        videoId: String, url: String, headers: [String: String], codec: String = "unknown", kbps: Int = 0, relativeLoudnessDb: Double? = nil, youtubeVideoId: String? = nil, durationSeconds: Int? = nil
    ) async throws -> String {
        let taskKey = videoId + "|" + StreamFileCache.qualityIdentity + "|" + DiskCache.hashName(url)
        let task: Task<String, Error> = streamGate.lock.withLock {
            if let existing = streamGate.tasks[taskKey] { return existing }
            let created = Task { try await streamViaKtorOnce(videoId: videoId, url: url, headers: headers, codec: codec, kbps: kbps, relativeLoudnessDb: relativeLoudnessDb, youtubeVideoId: youtubeVideoId, durationSeconds: durationSeconds) }
            streamGate.tasks[taskKey] = created
            return created
        }
        do {
            let path = try await task.value
            streamGate.lock.withLock {
                if streamGate.tasks[taskKey] != nil { streamGate.tasks[taskKey] = nil }
            }
            return path
        } catch {
            streamGate.lock.withLock {
                if streamGate.tasks[taskKey] != nil { streamGate.tasks[taskKey] = nil }
            }
            throw error
        }
    }

    private static func streamViaKtorOnce(
        videoId: String, url: String, headers: [String: String], codec: String = "unknown", kbps: Int = 0, relativeLoudnessDb: Double? = nil, youtubeVideoId: String? = nil, durationSeconds: Int? = nil
    ) async throws -> String {
        let qualityIdentity = StreamFileCache.qualityIdentity
        return try await withCheckedThrowingContinuation { continuation in
            let lock = NSLock()
            var resumed = false
            StreamDownloadBridge.shared.streamToFile(
                url: url,
                headers: headers,
                ready: DownloadCallbackAdapter { path, message in
                    lock.lock()
                    defer { lock.unlock() }
                    guard !resumed else { return }
                    resumed = true
                    if let path {
                        streamGate.lock.withLock { streamGate.growing[videoId] = path; streamGate.growingQuality[videoId] = qualityIdentity; streamGate.growingKbps[videoId] = kbps }
                        Task { await StreamFileCache.shared.noteGrowing(videoId: videoId, path: path, kbps: kbps, quality: qualityIdentity, relativeLoudnessDb: relativeLoudnessDb, youtubeVideoId: youtubeVideoId, durationSeconds: durationSeconds) }
                        continuation.resume(returning: path)
                    } else {
                        continuation.resume(throwing: InnertubeStreamResolver.StreamError(
                            message: message ?? "Stream failed"))
                    }
                },
                done: DownloadCallbackAdapter { path, message in
                    if let path {
                        Task { await StreamFileCache.shared.store(videoId, path: path, sourceIdentity: DiskCache.hashName(url), codec: codec, kbps: kbps, quality: qualityIdentity, relativeLoudnessDb: relativeLoudnessDb, youtubeVideoId: youtubeVideoId, durationSeconds: durationSeconds) }
                    } else if let message {
                        print("[Playback] stream tail failed for \(videoId): \(message)")
                        streamGate.lock.withLock { streamGate.growing[videoId] = nil }
                        Task { await StreamFileCache.shared.dropGrowing(videoId: videoId) }
                    }
                }
            )
        }
    }

    private func prepareNowPlayingForPlayback(entry: QueueEntry, duration: Double, position: Double) {
        nowPlaying.prepareForPlayback(
            id: entry.id, title: entry.title, artist: entry.artist,
            duration: duration, artworkData: entry.artworkData,
            thumbnailUrl: entry.thumbnailUrl, position: position,
            canNext: playingIndex + 1 < queue.count || repeatMode == .all,
            canPrevious: true, canSeek: duration > 0
        )
    }

    private func loadDidSucceed(
        entry: QueueEntry,
        index: Int,
        info: TrackInfoRec,
        startAt: Double = 0,
        headers: [String: String]
    ) {
        NSLog("[BitChord] loaded track at %.2fs (duration %.2fs)", startAt, info.durationSeconds)
        playingIndex = index
        current = entry
        historyVideoID = youtubeVideoID(for: entry)
        engineLoadedId = entry.id
        loadedSourcePath = info.source
        loadedSourceHeaders = headers
        position = startAt
        positionSampledAt = Date()
        duration = info.durationSeconds
        repairMissingDuration(entry: entry, info: info)
        lastError = nil
        state = .playing
        persistSession()
        refreshArtwork(entry)
        fetchLyrics(for: entry)
        fetchCanvas(for: entry)
        applySpatialPreference()
        nerd = dolbyRenderer?.nerd ?? engine.nerdStats()
        racingLossless = QualityUpgrade.isRacing(entry.id)
        scrobbleArmed = false
        scrobbleSent = false
        if let id = historyVideoID {
            QueueBuilderBridge.shared.rememberPlayed(videoId: id)
            PlaybackTrackerBridge.shared.onPlaying(videoId: id)
        }
        publishPresence()
        ScrobbleBridge.shared.nowPlaying(
            artist: scrobbleArtist(for: entry), title: entry.title, album: entry.albumName,
            durationSec: Swift.Int32(info.durationSeconds), positionMs: Swift.Int64(0)
        )
        nowPlaying.update(
            id: entry.id, title: entry.title, artist: entry.artist,
            duration: info.durationSeconds, artworkData: entry.artworkData,
            thumbnailUrl: entry.thumbnailUrl, isPlaying: isPlaying, position: position
        )
        nowPlaying.playbackDidStart()
        widgetPublisher.publish(entry: entry, isPlaying: true,
                                canNext: playingIndex + 1 < queue.count,
                                canPrevious: index > 0)
        if dolbyRenderer == nil { lookForBetterCopy(entry, codec: info.codec, kbps: info.kbps) }
        // The incoming source must be ready before the outgoing tail begins.
        // Waiting for the current download here made prefetch start up to eight
        // seconds late, then full analysis delayed queueing it even further.
        syncEngineQueueNext()
        scheduleSequencing()
    }

    /// Legacy cached WebM files can lack both container and saved duration.
    /// Repair metadata after playback starts, without delaying cached/offline audio.
    private func repairMissingDuration(entry: QueueEntry, info: TrackInfoRec) {
        guard duration <= 0, let videoId = entry.videoId else { return }
        let generation = playGeneration
        let ceiling = ResolvePrefs.current().maxKbps
        durationRepairTask?.cancel()
        durationRepairTask = Task { [weak self] in
            guard let stream = try? await InnertubeStreamResolver.shared.resolve(videoId: videoId, maxKbps: ceiling),
                  let seconds = stream.durationSeconds, seconds > 0, !Task.isCancelled,
                  let self, self.playGeneration == generation, self.engineLoadedId == entry.id,
                  self.loadedSourcePath == info.source, let current = self.current else { return }
            self.duration = Double(seconds)
            self.nowPlaying.update(id: current.id, title: current.title, artist: current.artist,
                duration: self.duration, artworkData: current.artworkData, thumbnailUrl: current.thumbnailUrl,
                isPlaying: self.isPlaying, position: self.position)
            self.nowPlaying.updateCommands(canNext: self.nextEntry != nil, canPrevious: true, canSeek: true)
            self.publishSmartWindow()
            await StreamFileCache.shared.storeDuration(seconds, at: info.source)
        }
    }

    private func loadDidFail(entry: QueueEntry, error: Error) {
        lastError = "Couldn't play “\(entry.title)” — \(error.localizedDescription)"
        // Somebody (pause, another load, sleep, interruption) owns the
        // transport now; their state stands and only the message is new.
        // Tearing the engine down here would stop whatever they started.
        guard state == .buffering else { return }
        state = .stopped
        dolbyRenderer?.stop()
        dolbyRenderer = nil
        engineLoadedId = nil
        try? engine.pause()
        let engine = self.engine
        loadSubmissionGate.advance(to: playGeneration) { try? engine.stop() }
        nowPlaying.stop()
        deactivateAudioSessionIfIdle()
    }

    /// A streamed download is finished once `.complete` lands, or when it was
    /// never a stream. `.grow` without `.complete` means bytes are still arriving
    /// and a plan made now is only as good as the audio on disk.
    private nonisolated static func fileSettled(_ path: String) -> Bool {
        let files = FileManager.default
        if files.fileExists(atPath: path + ".complete") { return true }
        if files.fileExists(atPath: path + ".grow") { return false }
        return true
    }

    /// Keeps the engine's pending-next pointing at the following queue entry
    /// so gapless/crossfade arming works (spec §3.1). Repeat-one without Automix
    /// must not arm the next song — the current track seeks to 0 at EOS.
    /// Repeat-one *with* Automix arms a self-mix into the same track.
    private func syncEngineQueueNext() {
        guard !sleepAfterTrack else { return }
        if dolbyRenderer != nil {
            nowPlaying.updateCommands(canNext: nextEntry != nil, canPrevious: current != nil, canSeek: duration > 0)
            return
        }
        nowPlaying.updateCommands(canNext: playingIndex + 1 < queue.count || repeatMode == .all, canPrevious: current != nil,
                                  canSeek: engineLoadedId != nil && duration > 0)
        // Recommendation replies can arrive before the selected song has loaded.
        // Read-ahead starts after that load, using its authoritative audio path.
        guard engineLoadedId != nil, engineLoadedId == current?.id else { return }
        queueNextRevision &+= 1
        let revision = queueNextRevision
        let gate = loadSubmissionGate
        gate.setQueueRevision(revision)
        let generation = playGeneration
        let expectedSource = loadedSourcePath ?? ""
        // Clear an obsolete prefetch now, including a voice armed but not audible.
        gate.submit(generation: generation, revision: revision) { [engine] in
            try? engine.queueNextIfCurrent(request: LoadRequest(
                source: "", title: "", artist: "", startSeconds: 0, plan: nil,
                headers: [:], claimedKbps: 0, loudnessDb: nil, durationSeconds: nil
            ), expectedSource: expectedSource)
        }
        // Upstream still measures the following track while a non-Automix
        // repeat-one loop runs, so leaving the loop is not a cold start.
        warmUpcoming(around: playingIndex, generation: generation)
        if repeatMode == .one && !automixEnabled { return }
        guard let next = nextEntry else {
            return
        }
        let nextId = next.id
        let outgoingId = current?.id
        let selfMix = repeatMode == .one || nextId == outgoingId
        let engine = self.engine
        let automix = automixEnabled
        // The *file* the engine opened, not `current.source` — which for a
        // YouTube track is `yt:<videoId>` and not something the planner can
        // decode. Passing the identifier made `duration_of` return 0, which
        // skips the whole-track analysis, leaves `bpm` at 0, and drops the plan
        // to `Tier::Plain`. The incoming side still analysed fine, so the only
        // symptom was a plausible-looking cue sitting on top of a plain 12 s
        // crossfade — which was every transition on normal streaming playback.
        let currentSource = loadedSourcePath ?? ""
        let outgoingDuration = duration > 0 ? duration : (current?.durationSeconds ?? 0)
        let currentSourceHeaders = loadedSourceHeaders
        let currentText = current?.itemText ?? ""
        let nextText = next.itemText
        // A self-mix is never an album gapless splice — force a real blend.
        let albumSequential = !selfMix && !shuffleEnabled && (current?.sameAlbum(as: next) ?? false)
        let prefs = ResolvePrefs.current()
        // `.utility` is deferrable. The scheduler was holding this until the
        // song was nearly over, so the next download — and the plan that waits
        // on it — started after the blend should already have been playing.
        Task.detached(priority: .userInitiated) {
            do {
                let outcome = try await Self.resolveSource(next, prefs: prefs)
                let stillCurrent = await MainActor.run { [weak self] in
                    guard let self else { return false }
                    return self.playGeneration == generation
                        && self.nextEntry?.id == nextId
                        && self.current?.id == outgoingId
                        && self.queueNextRevision == revision
                }
                guard stillCurrent else { return }
                await MainActor.run { [weak self] in
                    guard let self, self.playGeneration == generation, self.queueNextRevision == revision else { return }
                    self.noteResolved(next, outcome: outcome, prefs: prefs)
                    self.sourceHeadersByPath = [outcome.source.source: outcome.source.headers]
                    DownloadStore.shared.retainPlayback(paths: Set([outcome.source.source, self.loadedSourcePath ?? ""]))
                    // The better copy has to be in hand before the blend arms.
                    // Waiting until this track becomes current means the upgrade
                    // arrives during the ramp and cuts it. Skip for self-mix —
                    // the playing file is already the one being upgraded in place.
                    if !selfMix {
                        self.lookForBetterCopy(
                            next,
                            codec: outcome.source.format.codec ?? "",
                            kbps: Swift.UInt32(outcome.source.kbps)
                        )
                    }
                }
                let stillQueueTarget = await MainActor.run { [weak self] in
                    guard let self else { return false }
                    return self.playGeneration == generation
                        && self.nextEntry?.id == nextId
                        && self.current?.id == outgoingId
                        && self.queueNextRevision == revision
                }
                guard stillQueueTarget else { return }
                let resolved = outcome.source
                guard !PlaybackCodecCapabilities.shared.canRenderDolby(codec: resolved.codec, headers: resolved.headers) else { return }
                let incomingDuration = next.durationSeconds > 0
                    ? next.durationSeconds : Double(resolved.durationSec ?? 0)
                let declaredDuration = incomingDuration > 0 ? incomingDuration : nil
                let safetyFade = albumSequential ? 4.0 : min(
                    8.0,
                    outgoingDuration > 0 ? outgoingDuration / 3 : 8.0,
                    incomingDuration > 0 ? incomingDuration / 3 : 8.0
                )
                // Queue a real overlap as soon as the source is resolved. Beat
                // and vocal analysis can take seconds and must not be on the
                // critical path to hearing the next record under this one.
                let initialSafetyPlan: TransitionPlanRec? = automix ? TransitionPlanRec(
                    style: .equalPower, bassSwap: false, bassSwapFraction: 0.7,
                    filterSweep: 0, vocalOverlap: 0, fadeSeconds: safetyFade,
                    transitionEndSeconds: 0, cueSeconds: 0, playbackRate: 1,
                    bedFraction: 0, bedGainDb: 0, dipDepth: 0, dipWidth: 0,
                    postGlideSeconds: 0, outgoingDurationSeconds: outgoingDuration
                ) : nil
                let safetyPlan = initialSafetyPlan.map { constrainAutomixPlanForSources(plan: $0, outgoingSource: currentSource, incomingSource: resolved.source, outgoingDuration: outgoingDuration, incomingDuration: incomingDuration) }
                guard try gate.performIfCurrent(generation: generation, revision: revision, {
                    try engine.queueNextIfCurrent(request: LoadRequest(
                    source: resolved.source, title: next.title, artist: next.artist,
                    startSeconds: 0, plan: safetyPlan, headers: resolved.headers,
                    claimedKbps: Swift.UInt32(resolved.kbps),
                    loudnessDb: resolved.loudnessDb, durationSeconds: declaredDuration
                ), expectedSource: expectedSource)
                }) != nil else { return }
                if let safetyPlan {
                    await MainActor.run { [weak self] in
                        guard let self, self.playGeneration == generation,
                              self.queueNextRevision == revision, self.current?.id == outgoingId else { return }
                        self.adoptAutomixPlan(safetyPlan)
                    }
                }
                if automix {
                    NSLog(
                        "[BitChord] automix queued %@%@ with an immediate %.1fs overlap",
                        next.title,
                        selfMix ? " (self-mix)" : "",
                        safetyPlan?.fadeSeconds ?? 0
                    )
                }
                guard automix, !currentSource.isEmpty else { return }
                let fade = Double(PlatformSettings.shared.getInt(key: "crossfade_seconds", default: 0))
                // Plan from whatever is already downloaded, then again as the
                // files grow. Waiting for both downloads to finish is what put
                // the real blend at the last second of the song.
                for attempt in 0..<12 {
                    let stillPlanning = await MainActor.run { [weak self] in
                        guard let self else { return false }
                        return self.playGeneration == generation
                            && self.nextEntry?.id == nextId
                            && self.current?.id == outgoingId
                            && self.queueNextRevision == revision
                    }
                    guard stillPlanning else { return }
                    // Music Understanding (OS 27+): seed rhythm/key/structure
                    // overlays once per pair before the first plan. Sequential
                    // so we never run two Metal sessions at once (background
                    // GPU asserts abort the process).
                    if attempt == 0, MusicUnderstandingAnalyzer.isAvailable {
                        let outOk = await MusicUnderstandingAnalyzer.analyzeAndSeed(
                            filePath: currentSource
                        )
                        let inOk = await MusicUnderstandingAnalyzer.analyzeAndSeed(
                            filePath: resolved.source
                        )
                        if outOk || inOk {
                            NSLog(
                                "[BitChord] Music Understanding overlay out=%@ in=%@",
                                outOk ? "yes" : "no",
                                inOk ? "yes" : "no"
                            )
                        }
                    }
                    let rawPlan = engine.planAutomix(
                        outgoingPath: currentSource,
                        incomingPath: resolved.source,
                        outgoingText: currentText,
                        incomingText: nextText,
                        albumSequential: albumSequential,
                        crossfadeSeconds: fade,
                        outgoingDurationSeconds: outgoingDuration,
                        incomingDurationSeconds: incomingDuration,
                        outgoingHeaders: currentSourceHeaders,
                        incomingHeaders: resolved.headers
                    )
                    let plan = constrainAutomixPlanForSources(plan: rawPlan, outgoingSource: currentSource, incomingSource: resolved.source, outgoingDuration: outgoingDuration, incomingDuration: incomingDuration)
                    guard try gate.performIfCurrent(generation: generation, revision: revision, {
                        try engine.queueNextIfCurrent(request: LoadRequest(
                            source: resolved.source,
                            title: next.title,
                            artist: next.artist,
                            startSeconds: plan.cueSeconds,
                            plan: plan,
                            headers: resolved.headers,
                            claimedKbps: Swift.UInt32(resolved.kbps),
                            loudnessDb: resolved.loudnessDb,
                            // Not bookkeeping: the mixer schedules a transition against
                            // the end of the outgoing track, and a container that
                            // declares no length gives it nothing to schedule against —
                            // the incoming is then never armed and the queue advances by
                            // a cut. We already know the length.
                            durationSeconds: declaredDuration
                        ), expectedSource: expectedSource)
                    }) != nil else { return }
                    NSLog(
                        "[BitChord] automix plan %d for %@%@: %@, cue %.2fs, fade %.2fs, end %.1fs",
                        attempt, next.title, selfMix ? " (self-mix)" : "",
                        String(describing: plan.style),
                        plan.cueSeconds, plan.fadeSeconds, plan.transitionEndSeconds
                    )
                    await MainActor.run { [weak self] in
                        guard let self, self.queueNextRevision == revision else { return }
                        self.adoptAutomixPlan(plan)
                    }
                    let settled = Self.fileSettled(currentSource) && Self.fileSettled(resolved.source)
                    if settled { return }
                    let position = engine.positionSeconds()
                    let remaining = outgoingDuration - position
                    let lead = max(plan.fadeSeconds, safetyFade) + 8
                    if outgoingDuration > 0, remaining < lead { return }
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                }
            } catch {
                // Keep the current song playing; natural end retries with a
                // full load and reports any final failure to the listener.
                await MainActor.run { [weak self] in
                    guard let self, self.playGeneration == generation,
                          self.queueNextRevision == revision else { return }
                    PlaybackDebugLog.shared.record("next-track preparation failed: \(error.localizedDescription)", about: nextId)
                }
            }
        }
    }

    fileprivate func handleState(_ newState: PlaybackState) {
        guard dolbyRenderer == nil else { return }
        // A load callback can arrive from the outgoing voice after the listener
        // has already selected another track. Its load result is discarded by
        // the generation gate; don't let its state callback relabel the new
        // selection as playing while that selection is still buffering.
        if state == .buffering && (newState == .playing || newState == .stopped) { return }
        // A stale natural-end/stop for a superseded source must not wipe the
        // new selection either; the gate owns that call.
#if os(iOS)
        // Transport intent is updated synchronously. Rust delivers Play/Pause
        // acknowledgments later; an older acknowledgment must not reverse a
        // newer tap or publish a contradictory native button state.
        if (state == .paused && newState == .playing)
            || (state == .playing && newState == .paused) { return }
#endif
        state = newState
        if let current {
            nowPlaying.update(
                id: current.id, title: current.title, artist: current.artist,
                duration: duration, artworkData: current.artworkData,
                thumbnailUrl: current.thumbnailUrl,
                isPlaying: newState == .playing
            )
        }
        widgetPublisher.publish(entry: current, isPlaying: newState == .playing,
                                canNext: canPlayNext, canPrevious: canPlayPrevious)
        if newState == .stopped {
            nowPlaying.stop()
        }
        if newState == .paused { persistSession() }
    }

    fileprivate func handleHandoff(_ info: TrackInfoRec) {
        // The engine flipped to the incoming track. Trust-but-verify: the
        // mixer only arms what the gated queueNext asked for, but a manual
        // skip promotes on reply and flips the index itself, so a handoff
        // that follows it (or one from a superseded arm) must not advance
        // the queue a second time.
        if repeatMode != .one {
            if let next = nextEntry, info.title == next.title, info.artist == next.artist,
               sourceHeadersByPath[info.source] != nil {
                // The expected advance — fall through to the index logic.
            } else if let current, info.title == current.title, info.artist == current.artist {
                // Already here: adopt the authoritative path/headers and stop.
                // This is the skip path's own handoff arriving after the reply
                // already flipped the queue, or a duplicate delivery.
                loadedSourcePath = info.source
                if let headers = sourceHeadersByPath.removeValue(forKey: info.source) {
                    loadedSourceHeaders = headers
                }
                if info.durationSeconds > 0 { duration = info.durationSeconds }
                return
            } else {
                // A stale voice from a superseded arm (e.g. a blend abandoned
                // by a manual skip). Acting on it would move or stop the wrong
                // track.
                NSLog("[BitChord] ignoring handoff for untracked voice %@ — %@", info.title, info.artist)
                return
            }
        }
        // The engine flipped to the incoming track. Repeat-one with Automix is
        // a self-mix: stay on the same queue item. Repeat-all wrap lands on 0.
        if repeatMode == .one {
            // Same song again — count the lap like upstream REASON_REPEAT.
        } else if playingIndex + 1 < queue.count {
            playingIndex += 1
        } else if repeatMode == .all, !queue.isEmpty {
            playingIndex = 0
        } else {
            return
        }
        let outgoingPosition = position
        let sameSong = current?.id == queue[playingIndex].id
        autoplayRefresh.invalidate()
        current = queue[playingIndex]
        historyVideoID = current.flatMap(youtubeVideoID)
        duration = info.durationSeconds
        position = 0
        if let entry = current {
            if !sameSong {
                refreshArtwork(entry)
                fetchLyrics(for: entry)
                fetchCanvas(for: entry)
            }
            nerd = dolbyRenderer?.nerd ?? engine.nerdStats()
            racingLossless = QualityUpgrade.isRacing(entry.id)
            scrobbleArmed = false
            scrobbleSent = false
            PlaybackTrackerBridge.shared.onTrackChanged(positionSeconds: Int64(outgoingPosition))
            if let id = historyVideoID {
                QueueBuilderBridge.shared.rememberPlayed(videoId: id)
                PlaybackTrackerBridge.shared.onPlaying(videoId: id)
            }
            publishPresence()
            nowPlaying.update(
                id: entry.id, title: entry.title, artist: entry.artist,
                duration: info.durationSeconds, artworkData: entry.artworkData,
                thumbnailUrl: entry.thumbnailUrl, isPlaying: isPlaying, position: position
            )
            engineLoadedId = entry.id
            loadedSourcePath = info.source
            loadedSourceHeaders = sourceHeadersByPath.removeValue(forKey: info.source) ?? [:]
            beginSmartMixIfNeeded()
            if dolbyRenderer == nil { lookForBetterCopy(entry, codec: info.codec, kbps: info.kbps) }
        }
        persistSession()
        syncEngineQueueNext()
        scheduleSequencing()
        maybeAutoplay(lowWaterRefill: true)
    }

    fileprivate func handleTrackEnded(_ reason: TrackEndReason, source: String) {
        guard reason == .natural else { return }
        // A natural end for a voice the transport already left (manual skip,
        // or a blend that already handed off) must not move or stop the new
        // selection. Empty source keeps backward compatibility with callers
        // that do not report one.
        if !source.isEmpty, let loaded = loadedSourcePath, loaded != source { return }
        if historyVideoID != nil {
            PlaybackTrackerBridge.shared.onPlaybackFinished(positionSeconds: Int64(position))
        }
        if sleepAfterTrack {
            sleepAfterTrack = false
            pausePlayback(releaseAudioSession: true)
            try? engine.holdTrackEnd(hold: false)
            try? engine.setSleepGain(gain: 1)
            return
        }
        if let current, !scrobbleSent {
            ScrobbleBridge.shared.scrobble(
                artist: scrobbleArtist(for: current), title: current.title, album: current.albumName,
                durationSec: Swift.Int32(duration)
            )
            scrobbleSent = true
        }
        // Source validation above excludes the outgoing voice after a handoff.
        // If the current voice reaches EOS, prefetch may have failed or not
        // finished. Advance with a fresh load instead of assuming it was armed.
        PlaybackDebugLog.shared.record("natural end without handoff; index=\(playingIndex) count=\(queue.count)", about: current?.id)
        dolbyRenderer?.stop()
        dolbyRenderer = nil
        engineLoadedId = nil
        switch repeatMode {
        case .one:
            // Automix self-mix should have handed off before EOS. A natural end
            // here means the blend never armed — reopen rather than sit stopped
            // (the previous seek-after-EOF path left the decoder finished).
            restartCurrentAfterNaturalEnd()
        case .all:
            dolbyRenderer?.stop()
            dolbyRenderer = nil
            engineLoadedId = nil
            advanceToNext(userInitiated: false)
        case .off:
            if playingIndex + 1 < queue.count {
                loadCurrent(playingIndex + 1, refreshAutoplay: false)
                return
            }
            state = .stopped
            position = 0
            nowPlaying.updateRate(0.0, position: 0)
            nowPlaying.stop()
            deactivateAudioSessionIfIdle()
        }
    }

    /// Reopen the current queue item after a natural end. Seeking a finished
    /// voice after the mixer has drained often fails to produce audio again;
    /// a fresh load is what actually loops without Automix.
    private func restartCurrentAfterNaturalEnd() {
        guard queue.indices.contains(playingIndex) else { return }
        let index = playingIndex
        scrobbleArmed = false
        scrobbleSent = false
        dolbyRenderer?.stop()
        dolbyRenderer = nil
        engineLoadedId = nil
        loadCurrent(index, refreshAutoplay: false)
    }

    fileprivate func handleDuration(_ seconds: Double) {
        duration = seconds
        publishSmartWindow()
        // The lyric lookup may have gone out before the container said how long
        // the track is — the one field that lets most of these providers choose
        // between takes — and a lookup made blind is not evidence that there are
        // no lyrics. Upstream defers and re-runs on the length; so does this.
        if lyricsNeedsDurationRefresh, seconds > 0, let entry = current {
            lyricsNeedsDurationRefresh = false
            fetchLyrics(for: entry)
        }
    }

    /// Look again for the track that is playing.
    ///
    /// The "Change" sheet edits *which* sources are enabled and in what order,
    /// and those settings only ever applied to the next track: nothing re-ran
    /// the lookup for the one on screen, so a wrong or missing lyric could not
    /// be fixed from the player at all — the only way was to disable sources
    /// globally and play the track again. Upstream has a per-track provider
    /// picker for this; re-running with the settings the listener just changed
    /// is the part that makes those settings mean something.
    func refetchLyrics() {
        guard let entry = current else { return }
        fetchLyrics(for: entry)
    }

    fileprivate func handleError(_ message: String) {
        lastError = message
        if let id = current?.id, QualityUpgrade.forcedStream(id) != nil {
            QualityUpgrade.refuseUpgrades(id)
            debugLog.record("broke on its upgrade; no more swaps", about: id)
        }
    }

    private var nextEntry: QueueEntry? {
        if repeatMode == .one {
            // Automix: blend the track into itself. Without Automix there is no
            // engine next — EOS reopens the same item.
            return automixEnabled ? current : nil
        }
        if playingIndex + 1 < queue.count { return queue[playingIndex + 1] }
        // Including a one-item queue: Media3 wrap under REPEAT_ALL points next
        // at the same index, which is how a single track on repeat-all self-mixes.
        if repeatMode == .all, !queue.isEmpty { return queue[0] }
        return nil
    }

    private func fetchLyrics(for entry: QueueEntry) {
        lyricsAlignmentTask?.cancel()
        lyricsAlignmentTask = nil
        lyricsAligning = false
        lyricsRequestGeneration &+= 1
        let requestGeneration = lyricsRequestGeneration
        lyricsNeedsDurationRefresh = false
        lyrics = []
        lyricsSourceLabel = nil
        // Cleared rather than set: a new track has not been looked up yet, and a
        // stale "there are none" from the previous one would say so about this
        // one before anyone had asked.
        attemptedLyrics = false
        // A translation belongs to the lyric it was made from. Carrying it across
        // a track change would show one song's words over another's music, which is
        // worse than having no translation at all.
        lyricsTranslator.reset()
        // A remote library's file is "local" in the sense that it needs no download,
        // but its `source` is an `https` address and cannot be opened for tags. Asking
        // again here is what keeps a remote row from trying to read a URL as a file.
        let localPath = entry.isLocal && !entry.source.isEmpty && !entry.source.hasPrefix("http")
            ? entry.source
            : nil
        let allowNetwork = PlatformSettings.shared.getBoolean(key: "synced_lyrics", default: true)
        if !allowNetwork, localPath == nil {
            // Not a search that found nothing — a search that was never going to
            // be made, because the listener has lyrics off. "Unavailable" would
            // be a lie; the strip says nothing was looked for.
            lyricsLoading = false
            attemptedLyrics = true
            return
        }
        lyricsLoading = true
        // Compare provider timelines with the decoded audio that is playing.
        // Queue metadata can describe a longer video upload or another edition.
        let knownDuration = duration > 0 ? duration : entry.durationSeconds
        let durationMs = Swift.Int64(knownDuration * 1000)
        lyricsNeedsDurationRefresh = durationMs <= 0
        LyricsBridge.shared.fetchAttributed(
            title: entry.title,
            artist: entry.artist,
            durationMs: durationMs,
            album: entry.albumName,
            videoId: entry.videoId,
            localPath: localPath,
            callback: AttributedLyricsAdapter { [weak self] _, label, lines in
                Task { @MainActor in
                    guard let self,
                          self.current?.id == entry.id,
                          self.lyricsRequestGeneration == requestGeneration
                    else { return }
                    self.lyrics = lines
                    self.lyricsSourceLabel = label.isEmpty ? nil : label
                    self.lyricsLoading = false
                    // The search finished either way, which is what the deck's
                    // strip reads to tell "none" apart from "looking".
                    self.attemptedLyrics = true
                    self.alignFetchedLyricsIfNeeded(
                        lines,
                        for: entry,
                        requestGeneration: requestGeneration
                    )
                }
            }
        )
    }

    /// Fill in missing word timestamps in the background. The fetched text stays
    /// the authority; local speech recognition only contributes candidate word
    /// times, and the shared aligner rejects transcript words that do not match.
    private func alignFetchedLyricsIfNeeded(
        _ lines: [LyricLineDto],
        for entry: QueueEntry,
        requestGeneration: UInt64
    ) {
        guard lines.contains(where: { !$0.isGap && $0.words.isEmpty }),
              let source = loadedSourcePath,
              !source.isEmpty
        else { return }

        let trackDuration = duration > 0 ? duration : entry.durationSeconds
        guard trackDuration > 0 else { return }
        let engine = self.engine
        let headers = loadedSourceHeaders
        let decode: LyricsAudioAligner.Decode = { start, length in
            guard let region = engine.decodeRegionWithHeaders(
                source: source,
                startSeconds: start,
                durationSeconds: length,
                mono: true,
                headers: headers
            ) else { return nil }
            return LyricsAudioAligner.Region(
                samples: region.samples,
                sampleRate: Double(region.sampleRate),
                startSeconds: region.startSeconds
            )
        }

        lyricsAligning = true
        lyricsAlignmentTask = Task { @MainActor [weak self] in
            let aligned = await LyricsAudioAligner.align(
                lines: lines,
                durationSeconds: trackDuration,
                decode: decode,
                onUpdate: { [weak self] updated in
                    guard let self,
                          self.current?.id == entry.id,
                          self.lyricsRequestGeneration == requestGeneration
                    else { return }
                    self.lyrics = updated
                }
            )
            guard let self,
                  self.current?.id == entry.id,
                  self.lyricsRequestGeneration == requestGeneration
            else { return }
            self.lyricsAligning = false
            self.lyricsAlignmentTask = nil
            NSLog("[BitChord] local lyric alignment %@ for %@",
                  aligned ? "added word timings" : "found no confident word matches",
                  entry.title)
        }
    }

    /// Re-read the feature/network preferences and run the same lookup used
    /// when a track starts. Settings surfaces call this after changing a
    /// canvas preference.
    func refreshCanvasLookup() {
        guard let current else { return }
        fetchCanvas(for: current)
    }

    private func fetchCanvas(for entry: QueueEntry) {
        let titleKey = entry.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let artistKey = entry.artist.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let identity = "\(titleKey)|\(artistKey)"
        if canvasIdentity != identity {
            canvasURL = nil
            canvasFallbackURL = nil
            canvasSource = nil
            canvasIdentity = identity
        }
        canvasLookupGeneration &+= 1
        let generation = canvasLookupGeneration
        guard NetworkQuality.shared.canvasAllowed,
              // A catalogue track can have a local downloaded file while
              // retaining its catalogue id. A true library file uses its
              // path as both id and source and has no catalogue lookup.
              !(entry.isLocal && entry.id == entry.source) else {
            canvasURL = nil
            canvasFallbackURL = nil
            canvasSource = nil
            return
        }
        CanvasBridge.shared.lookup(title: entry.title, artist: entry.artist, album: entry.albumName, callback: CanvasAdapter { [weak self] json in
            Task { @MainActor in
                guard let self, self.canvasLookupGeneration == generation,
                      let active = self.current,
                      active.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == titleKey,
                      active.artist.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == artistKey else { return }
                guard let json, let data = json.data(using: .utf8),
                      let payload = try? JSONDecoder().decode(CanvasPayload.self, from: data),
                      let url = URL(string: payload.url) else {
                    NSLog("[BitChord] no animated artwork found for '%@' by '%@'", entry.title, entry.artist)
                    return
                }
                self.canvasURL = url
                self.canvasFallbackURL = payload.fallbackUrl.flatMap(URL.init(string:))
                self.canvasSource = payload.source
                NSLog("[BitChord] animated artwork source=%@ host=%@ for '%@'",
                      payload.source, url.host ?? "unknown", entry.title)
            }
        })
        if entry.albumName == nil {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(350))
                guard let self, self.canvasLookupGeneration == generation,
                      let latest = self.current, latest.id == entry.id,
                      let album = latest.albumName else { return }
                self.canvasLookupGeneration &+= 1
                let retryGeneration = self.canvasLookupGeneration
                CanvasBridge.shared.lookup(title: latest.title, artist: latest.artist, album: album, callback: CanvasAdapter { [weak self] json in
                    Task { @MainActor in
                        guard let self, self.canvasLookupGeneration == retryGeneration,
                              self.current?.id == latest.id else { return }
                        guard let json,
                              let data = json.data(using: .utf8),
                              let payload = try? JSONDecoder().decode(CanvasPayload.self, from: data),
                              let url = URL(string: payload.url) else {
                            NSLog("[BitChord] no animated artwork found for '%@' by '%@' after album metadata arrived",
                                  latest.title, latest.artist)
                            return
                        }
                        self.canvasURL = url
                        self.canvasFallbackURL = payload.fallbackUrl.flatMap(URL.init(string:))
                        self.canvasSource = payload.source
                        NSLog("[BitChord] animated artwork source=%@ host=%@ for '%@' after album metadata arrived",
                              payload.source, url.host ?? "unknown", latest.title)
                    }
                })
            }
        }
    }

    private struct CanvasPayload: Codable {
        let url: String
        let source: String
        let fallbackUrl: String?
    }

    private func tickSleep() {
        if let mixFadeUntil, Date() >= mixFadeUntil {
            self.mixFadeUntil = nil
            smartMixInProgress = false
            // An upgrade that arrived during the ramp was shelved so it would
            // not cut the blend. The new song is on its own now.
            if let entry = current, QualityUpgrade.shelvedFor(entry.id) != nil {
                lookForBetterCopy(entry, codec: "", kbps: nerd?.kbps ?? 0)
            }
        }
    }

    private func tickHistory() {
        guard let id = historyVideoID else { return }
        PlaybackTrackerBridge.shared.onProgress(
            videoId: id,
            positionSeconds: Int64(position)
        )
    }

    private func tickScrobble() {
        guard let current, duration > 0 else { return }
        let minDur = Double(PlatformSettings.shared.getInt(key: "scrobble_min_duration", default: 30))
        let pct = Double(PlatformSettings.shared.getFloat(key: "scrobble_delay_percent", default: 0.5))
        let maxDelay = Double(PlatformSettings.shared.getInt(key: "scrobble_delay_seconds", default: 180))
        let threshold = min(max(duration * pct, minDur), maxDelay)
        if !scrobbleArmed, position >= minDur {
            scrobbleArmed = true
        }
        if scrobbleArmed, !scrobbleSent, position >= threshold {
            ScrobbleBridge.shared.scrobble(
                artist: scrobbleArtist(for: current), title: current.title, album: current.albumName,
                durationSec: Swift.Int32(duration)
            )
            scrobbleSent = true
        }
    }

    private func tickListening() {
        guard let current else { return }
        ListeningStore.shared.onSample(
            id: current.id, title: current.title, artist: current.artist,
            album: current.albumName, albumId: current.albumId, artistId: current.artistId,
            art: current.thumbnailUrl, duration: duration
        )
    }

    private func pollWidgetCommands() {
        guard let defaults = UserDefaults(suiteName: "group.app.bitchord.BitChord"),
              let cmd = defaults.string(forKey: "widget.command") else { return }
        defaults.removeObject(forKey: "widget.command")
        switch cmd {
        case "toggle": togglePlayPause()
        case "next": next()
        case "previous": previous()
        default: break
        }
    }

    func pauseForBackground() {
        if isPlaying || isBuffering { pausePlayback() }
    }

    /// The heart in the player, for whatever is playing.
    func toggleLike() {
        guard let vid = current?.videoId else { return }
        toggleLike(videoId: vid)
    }

    /// The heart for a named track — the row swipe and the long-press menu use
    /// this one, so there is a single like path rather than three that disagree.
    ///
    /// `LibraryActions.toggleLike` owns the optimistic write and its rollback;
    /// this adds the reporting, which every call site used to skip by writing
    /// the result to `_`. A refused rating was therefore invisible *and*
    /// permanent — the heart kept a status the account did not have. `lastError`
    /// is the app's single failure surface (RootView turns it into a toast), so
    /// a like that YouTube refuses is said out loud in the same place a
    /// playback failure is.
    func toggleLike(videoId: String) {
        Task { @MainActor [weak self] in
            if let failure = await self?.toggleLikeAndWait(videoId: videoId) {
                self?.lastError = failure
            }
        }
    }

    func toggleLikeAndWait(videoId: String) async -> String? {
        let generation = PageSession.generation()
        let failure = await LibraryActions.toggleLike(videoId: videoId)
        refreshAfterRating(failure: failure, sessionGeneration: generation)
        return failure
    }

    func rateTrack(videoId: String, status: String) async -> String? {
        let generation = PageSession.generation()
        let previous = LibraryActions.cachedLike(videoId)
        let failure = await LibraryActions.rate(videoId: videoId, status: status)
        if generation == PageSession.generation() {
            if failure != nil { LikeStore.shared.set(videoId, previous) }
            refreshAfterRating(failure: failure, sessionGeneration: generation)
        }
        return failure
    }

    private func refreshAfterRating(failure: String?, sessionGeneration: Int64) {
        guard failure == nil, sessionGeneration == PageSession.generation() else { return }
        maybeAutoplay(force: true)
    }

    var isLiked: Bool {
        _ = LikeStore.shared.epoch
        guard let vid = current?.videoId else { return false }
        return LibraryActions.cachedLike(vid) == "LIKE"
    }

    /// When [position] was last read from the engine. See [livePosition].
    @ObservationIgnored private var positionSampledAt = Date.distantPast
    /// The engine advances source time at this rate between position polls.
    @ObservationIgnored private var playbackRate = 1.0

    /// The transport position, advanced between engine polls.
    ///
    /// `position` is the engine's answer, four times a second. Judging a word
    /// highlight against it means the highlight can only change on those four
    /// ticks — up to 250 ms late, in 250 ms steps, and frozen for as long as the
    /// engine is not reporting. Upstream keeps a reconciler and a per-frame
    /// advance for exactly this ([LyricClock]), added on the grounds that a
    /// twice-a-second clock is "far too coarse for a highlight".
    ///
    /// So the lyric pane reads this instead: the last reported position plus the
    /// wall clock since it arrived, which the pane drives at frame rate through
    /// a `TimelineView(.animation)`.
    ///
    /// Only while `state == .playing`, deliberately. Paused, buffering or
    /// seeking, the answer is exactly `position` — interpolation must never
    /// invent motion the engine is not making. The `elapsed < 1` bound is the
    /// same instinct for a stalled tick: past a second, the honest answer is the
    /// last measurement rather than a guess with a second of drift in it.
    ///
    /// The listener's playback-rate setting is included; omitting it made every
    /// lyric drift steadily whenever playback was slower or faster than 1×. A
    /// beatmatched transition can still stretch the incoming by up to 5 %, which
    /// over one 250 ms poll is at most 12 ms before the next engine sample.
    func livePosition(at now: Date) -> Double {
        guard state == .playing else { return position }
        let elapsed = now.timeIntervalSince(positionSampledAt)
        guard elapsed > 0, elapsed < 1 else { return position }
        return position + elapsed * playbackRate
    }

    private func youtubeVideoID(for entry: QueueEntry) -> String? {
        if entry.source.hasPrefix("yt:") { return entry.videoId }
        return entry.isLocal ? DownloadStore.shared.selectedYouTubeVideoId(for: entry.source) : nil
    }

    private var recommendationContext: AutoplayRefreshState.Context? {
        guard autoplayEnabled, repeatMode != .all, let current,
              let id = youtubeVideoID(for: current), state != .stopped else { return nil }
        return .init(
            source: "yt:\(id)", index: playingIndex, playbackGeneration: playGeneration,
            queueEditRevision: queueEditRevision, sessionGeneration: PageSession.generation()
        )
    }

    private func maybeAutoplay(force: Bool = false, lowWaterRefill: Bool = false) {
        guard let context = recommendationContext,
              force || (lowWaterRefill && PlaybackQueuePolicy.shouldRefillAutoplay(
                  upcomingCount: queue.count - playingIndex - 1
              )),
              let request = autoplayRefresh.begin(context, force: force) else { return }
        let videoId = String(context.source.dropFirst(3))
        fetchRecommendations(videoId: videoId) { [weak self] json, _ in
            Task { @MainActor in
                guard let self, let json, let currentContext = self.recommendationContext,
                      self.autoplayRefresh.accepts(request, current: currentContext) else { return }
                // An explicit action replaces stale suggestions but keeps the
                // played prefix and user/list entries. Natural low-water refills
                // append behind everything already queued.
                let kept = force
                    ? PlaybackQueuePolicy.withoutUpcomingAutoplay(self.queue, after: self.playingIndex)
                    : self.queue
                guard kept.indices.contains(self.playingIndex) else { return }
                // QueueBuilder reads the final existing entry as the station seed.
                // Its filtering snapshot ends with the current song; actual queue
                // positions and manual/list priority are unchanged.
                let filteringEntries = kept.enumerated().filter { $0.offset != self.playingIndex }.map(\.element) + [kept[self.playingIndex]]
                let existing = (try? JSONEncoder().encode(filteringEntries.map { $0.asSongJSON(videoIDOverride: self.youtubeVideoID(for: $0)) }))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
                let extraJson = QueueBuilderBridge.shared.extendJson(
                    existingJson: existing, candidatesJson: json, limit: Int32(8)
                )
                guard let data = extraJson.data(using: .utf8),
                      let songs = try? JSONDecoder().decode([SongDTO].self, from: data) else { return }
                var known = Set(kept.map(\.id))
                let extras = songs.filter { known.insert($0.videoId).inserted }.map {
                    QueueEntry.youtube(
                        videoId: $0.videoId, title: $0.title, artist: $0.artist,
                        thumbnailUrl: $0.thumbnailUrl, durationText: $0.durationText,
                        albumName: $0.albumName, artistId: $0.artistId, albumId: $0.albumId,
                        fromAutoplay: true
                    )
                }
                self.queue = kept + extras
                self.persistSession()
                self.syncEngineQueueNext()
                self.scheduleSequencing()
            }
        }
    }

    private func fetchRecommendations(videoId: String, response: @escaping (String?, String?) -> Void) {
        #if DEBUG
        if let recommendationFetchOverride { recommendationFetchOverride(videoId, response); return }
        #endif
        AutoPlayBridge.shared.related(videoId: videoId, callback: AutoPlayAdapter(response))
    }

    private func tasteScores(_ entries: [QueueEntry], transitionFits: [Int: Double] = [:]) -> [Double] {
        let taste = ListeningStore.shared.summary(includeGenres: true)
        let lastPlayed = ListeningStore.shared.lastPlayedByTrack()
        let now = Date().timeIntervalSince1970 * 1000
        return entries.enumerated().map { index, entry in
            let primaryArtist = ListeningStore.primaryArtist(entry.artist) ?? entry.artist
            let artistRank = taste.artists.firstIndex {
                $0.name.caseInsensitiveCompare(primaryArtist) == .orderedSame
            }
            let artistAffinity = artistRank.map { max(0, 1.0 - Double($0) / 10.0) } ?? 0
            let artistGenres = ListeningStore.shared.knownGenres[primaryArtist] ?? []
            let genreRank = taste.genres.firstIndex { genre in
                artistGenres.contains { $0.caseInsensitiveCompare(genre.name) == .orderedSame }
            }
            let genreAffinity = genreRank.map { max(0, 1.0 - Double($0) / 10.0) } ?? 0
            return PlaybackQueuePolicy.score(
                transitionFit: transitionFits[index], affinity: max(artistAffinity, genreAffinity),
                playedAt: lastPlayed[entry.id], now: now
            )
        }
    }

    private func scheduleSequencing() {
        sequencingTask?.cancel()
        sequencingGeneration &+= 1
        guard automixSequencingEnabled, let current else { return }
        let initial = queue
        let initialScores = tasteScores(initial)
        for positions in [PlaybackQueuePolicy.listIndices(initial, after: playingIndex),
                          PlaybackQueuePolicy.autoplayIndices(initial, after: playingIndex)] {
            queue = PlaybackQueuePolicy.replacing(
                queue, at: positions,
                with: PlaybackQueuePolicy.ranked(positions, scores: initialScores).map { initial[$0] }
            )
        }
        if queue != initial { persistSession(); syncEngineQueueNext() }
        let generation = sequencingGeneration
        let snapshot = queue
        let index = playingIndex
        let playbackGeneration = playGeneration
        let sessionGeneration = PageSession.generation()
        let currentPath = loadedSourcePath
        let fade = Double(PlatformSettings.shared.getInt(key: "crossfade_seconds", default: 0))
        let skipVocals = automixPerformanceMode == "EFFICIENT"
        let listPositions = PlaybackQueuePolicy.listIndices(snapshot, after: index)
        let autoplayPositions = PlaybackQueuePolicy.autoplayIndices(snapshot, after: index)
        guard listPositions.count > 1 || autoplayPositions.count > 1 else { return }
        // Taste/freshness gives every candidate an order immediately. Decode and
        // analyse only a bounded window of audio already available on this device.
        let fallback = tasteScores(snapshot)
        sequencingTask = Task(priority: .utility) { [weak self] in
            var transitionFits: [Int: Double] = [:]
            if let currentPath, FileManager.default.fileExists(atPath: currentPath) {
                for positions in [Array(listPositions.prefix(12)), Array(autoplayPositions.prefix(12))] {
                    var paths: [String] = []
                    var texts: [String] = []
                    var available: [Int] = []
                    for position in positions {
                        if Task.isCancelled { return }
                        let entry = snapshot[position]
                        let path: String?
                        if entry.isLocal, FileManager.default.fileExists(atPath: entry.source) {
                            path = entry.source
                        } else if entry.source.hasPrefix("yt:"), let id = entry.videoId {
                            path = await StreamFileCache.shared.path(for: id)
                        } else { path = nil }
                        if let path, FileManager.default.fileExists(atPath: path) {
                            paths.append(path)
                            texts.append(entry.itemText)
                            available.append(position)
                        }
                    }
                    guard !Task.isCancelled else { return }
                    if paths.count > 1 {
                        let ranked = await AutomixQueueRanker.shared.rank(
                            currentPath: currentPath, candidatePaths: paths,
                            currentText: current.itemText, candidateTexts: texts,
                            crossfadeSeconds: fade, skipVocals: skipVocals
                        )
                        for (rank, value) in ranked.enumerated() {
                            let candidate = Int(value)
                            if available.indices.contains(candidate) {
                                transitionFits[available[candidate]] = 1 - Double(rank) / Double(max(1, available.count - 1))
                            }
                        }
                    }
                }
            }
            guard let self, !Task.isCancelled, self.sequencingGeneration == generation,
                  self.automixSequencingEnabled, self.queue == snapshot, self.playingIndex == index,
                  self.playGeneration == playbackGeneration, self.current?.id == current.id,
                  PageSession.generation() == sessionGeneration else { return }
            let scores = transitionFits.isEmpty ? fallback : self.tasteScores(snapshot, transitionFits: transitionFits)
            var ordered = snapshot
            for positions in [listPositions, autoplayPositions] {
                ordered = PlaybackQueuePolicy.replacing(
                    ordered, at: positions,
                    with: PlaybackQueuePolicy.ranked(positions, scores: scores).map { snapshot[$0] }
                )
            }
            guard ordered != self.queue else { return }
            self.queue = ordered
            self.persistSession()
            self.syncEngineQueueNext()
        }
    }

    /// Clears AutoPlay's tail for the duration of repeat-all, keeping it to put back.
    private func stashAutoplayTracks() {
        if !repeatAllStash.isEmpty { return }
        let seed = current?.id
        var kept: [QueueEntry] = []
        var dropped: [QueueEntry] = []
        for (i, entry) in queue.enumerated() {
            // Never pull the playing item or anything before it out of the loop.
            if i <= playingIndex || !entry.fromAutoplay {
                kept.append(entry)
            } else {
                dropped.append(entry)
            }
        }
        guard !dropped.isEmpty else { return }
        queue = kept
        repeatAllStash = dropped
        repeatAllStashSeed = seed
        persistSession()
    }

    /// Puts the stashed AutoPlay tracks back when repeat-all ends.
    private func restoreAutoplayTracks() {
        let stashed = repeatAllStash
        let seed = repeatAllStashSeed
        repeatAllStash = []
        repeatAllStashSeed = nil
        guard !stashed.isEmpty, autoplayEnabled else { return }
        guard current?.id == seed else { return }
        let present = Set(queue.map(\.id))
        let restored = stashed.filter { !present.contains($0.id) }
        guard !restored.isEmpty else { return }
        queue.append(contentsOf: restored)
        persistSession()
    }

    private struct SongDTO: Codable {
        let videoId: String
        let title: String
        let artist: String
        let thumbnailUrl: String?
        let durationText: String?
        let albumName: String?
        let artistId: String?
        let albumId: String?
    }

    private func publishPresence() {
        guard PlatformSettings.shared.getBoolean(key: "discord_rpc_enabled", default: true) else { return }
        guard let current else { return }
        let speed = PlatformSettings.shared.getFloat(key: "playback_speed", default: 1)
        let videoId = current.source.hasPrefix("yt:") ? String(current.source.dropFirst(3)) : nil
        DiscordGateway.shared.updatePresence(
            title: current.title, artist: current.artist, album: current.albumName,
            positionMs: Swift.Int64(position * 1000), durationMs: Swift.Int64(duration * 1000),
            speed: speed, videoId: videoId
        )
    }

    // ---- Quality upgrade / Automix UI state ---------------------------------

    private var resolvedOrigin: [String: ResolvedSource.Origin] = [:]

    private func noteResolved(_ entry: QueueEntry, outcome: ResolveOutcome, prefs: ResolvePrefs) {
        resolvedOrigin[entry.id] = outcome.source.origin
        if let videoId = outcome.source.youtubeVideoId { resolvedVideoIds[outcome.source.source] = videoId }
        prepareRegions(source: outcome.source.source, videoId: outcome.source.youtubeVideoId)

        debugLog.record(
            "resolved \(outcome.source.origin) \(outcome.source.format.summary)",
            about: entry.id
        )
        let below = prefs.wantLossless && !outcome.source.lossless
        let youtubeWon = outcome.source.origin == .youtube
        let leftover = outcome.leftover
        if youtubeWon || (outcome.source.origin == .substitute && below) {
            let pending = QualityUpgrade.settledForLess(
                mediaId: entry.id,
                target: QualityUpgrade.Target(
                    title: entry.title,
                    artist: entry.artist,
                    durationSec: {
                        let s = Int(entry.durationSeconds.rounded())
                        return s > 0 ? s : nil
                    }()
                ),
                inFlight: leftover,
                playing: outcome.source.format,
                canSubstitute: prefs.canSubstitute
            )
            if current?.id == entry.id { racingLossless = pending }
            if pending {
                debugLog.record(
                    leftover != nil
                        ? "started on the fallback; lookup is still running"
                        : "below request; will look again during playback",
                    about: entry.id
                )
            } else {
                leftover?.cancel()
            }
        } else {
            leftover?.cancel()
            if current?.id == entry.id { racingLossless = QualityUpgrade.isRacing(entry.id) }
        }
    }

    private func lookForBetterCopy(_ entry: QueueEntry, codec: String, kbps: UInt32) {
        guard !entry.isLocal, entry.source.hasPrefix("yt:") else { return }
        let mediaId = entry.id
        // A pinned track is held off the automatic search on purpose: the
        // listener reverted it, and an upgrade that arrives mid-playback would
        // swap them straight back onto the copy they rejected — the same
        // outcome the pin exists to prevent, arriving without being asked for.
        // Checked here rather than inside `QualityUpgrade` so the store keeps
        // one job, and so `upgradeQuality` is the only thing that can undo it.
        guard !OriginalVersion.shared.isPinned(videoId: mediaId) else {
            racingLossless = false
            return
        }
        let prefs = ResolvePrefs.current()
        if let shelved = QualityUpgrade.shelvedFor(mediaId) {
            debugLog.record("re-offering the upgrade already proved", about: mediaId)
            QualityUpgrade.onRaceStart(mediaId)
            racingLossless = true
            startUpgradeJob(entry: entry, prefs: prefs, shelved: shelved)
            return
        }
        if !QualityUpgrade.isPending(mediaId) {
            if resolvedOrigin[mediaId] == .cache {
                let playing = cachedFloor(kbps: kbps)
                let adopted = QualityUpgrade.adoptUnresolved(
                    mediaId: mediaId,
                    target: QualityUpgrade.Target(
                        title: entry.title, artist: entry.artist,
                        durationSec: duration > 0 ? Int(duration.rounded()) : nil
                    ),
                    playingCodec: codec,
                    playing: playing,
                    canSubstitute: prefs.canSubstitute
                )
                racingLossless = adopted
                if adopted {
                    debugLog.record(
                        "playing \(playing?.summary ?? "an unmeasured stream") from cache; looking for a better copy",
                        about: mediaId
                    )
                }
                guard adopted else { return }
            } else if !QualityUpgrade.couldStillUpgrade(
                mediaId: mediaId, canSubstitute: prefs.canSubstitute
            ) {
                racingLossless = QualityUpgrade.isRacing(mediaId)
                return
            }
        }
        if upgradeFor == mediaId { return }
        if QualityUpgrade.isPending(mediaId) {
            debugLog.record("looking again for a better copy", about: mediaId)
        }
        startUpgradeJob(entry: entry, prefs: prefs, shelved: nil)
    }

    private func cachedFloor(kbps: UInt32) -> QualityUpgrade.Format? {
        let codec = nerd?.codec
        guard kbps > 0 || codec != nil else { return nil }
        return QualityUpgrade.Format(codec: codec, kbps: kbps > 0 ? Int(kbps) : nil,
            lossless: QualityUpgrade.Format.isLosslessCodec(codec))
    }

    private func startUpgradeJob(
        entry: QueueEntry, prefs: ResolvePrefs, shelved: QualityUpgrade.Candidate?
    ) {
        let mediaId = entry.id
        upgradeFor = mediaId
        let generation = playGeneration
        racingLossless = true
        let eng = engine
        let log = debugLog
        Task.detached(priority: .utility) { [weak self] in
            let better: QualityUpgrade.Candidate?
            if let shelved {
                better = shelved
            } else {
                better = await QualityUpgrade.lookAgain(
                    mediaId: mediaId,
                    playingDurationSec: await MainActor.run { [weak self] () -> Int? in
                        guard let self, self.duration > 0 else { return nil }
                        return Int(self.duration.rounded())
                    },
                    search: {
                        let playing = await MainActor.run { [weak self] () -> QualityUpgrade.Format? in
                            guard let self else { return nil }
                            let kbps = self.nerd?.kbps ?? 0
                            let codec = self.nerd?.codec
                            return QualityUpgrade.Format(codec: codec, kbps: kbps > 0 ? Int(kbps) : nil,
                                lossless: QualityUpgrade.Format.isLosslessCodec(codec))
                        }
                        let dur = await MainActor.run { [weak self] () -> Int? in
                            guard let self, self.duration > 0 else { return nil }
                            return Int(self.duration.rounded())
                        }
                        guard let hit = await Self.resolveSubstitute(
                            entry, prefs: prefs, waitForAll: true, playingDurationSec: dur, playing: playing
                        ) else { return nil }
                        let format = hit.format
                        guard QualityUpgrade.worthSwapping(format, playing: playing) else {
                            return nil
                        }
                        if let dur, !QualityUpgrade.sameRecordingAs(hit.durationSec, dur),
                           hit.durationSec != nil {
                            return nil
                        }
                        return hit.asCandidate()
                    }
                )
            }
            defer {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if self.upgradeFor == mediaId { self.upgradeFor = nil }
                    if self.current?.id == mediaId {
                        self.racingLossless = QualityUpgrade.isRacing(mediaId)
                    }
                    QualityUpgrade.onRaceEnd(mediaId)
                }
            }
            let moment = await MainActor.run { [weak self] () -> String in
                guard let self, self.playGeneration == generation else { return "gone" }
                if self.current?.id == mediaId { return "current" }
                if self.nextEntry?.id == mediaId { return "next" }
                return "gone"
            }
            guard let better else { return }
            switch moment {
            case "current":
                await self?.performSwap(
                    mediaId: mediaId, stream: better, entry: entry,
                    generation: generation, engine: eng, log: log
                )
            case "next":
                await self?.installUpgradedIncoming(
                    mediaId: mediaId, stream: better, entry: entry,
                    generation: generation, engine: eng, log: log
                )
            default:
                QualityUpgrade.shelve(mediaId, stream: better)
                log.record("upgrade proved but the queue moved on; shelved", about: mediaId)
            }
        }
    }

    nonisolated private func installUpgradedIncoming(
        mediaId: String,
        stream: QualityUpgrade.Candidate,
        entry: QueueEntry,
        generation: UInt64,
        engine: PlayerEngine,
        log: PlaybackDebugLog
    ) async {
        let path: String?
        if stream.url.hasPrefix("/") || stream.url.hasPrefix("file:") {
            let local = stream.url.hasPrefix("file:")
                ? (URL(string: stream.url)?.path ?? stream.url)
                : stream.url
            path = FileManager.default.fileExists(atPath: local) ? local : nil
        } else {
            path = try? await Self.streamViaKtor(
                videoId: "\(mediaId)#\(QualityUpgrade.upgraded)",
                url: stream.url,
                headers: stream.headers
            )
        }
        guard let path else {
            QualityUpgrade.forget(mediaId)
            log.record("upgrade audition failed", about: mediaId)
            return
        }
        let context = await MainActor.run { () -> (String, String, String, Bool, Double, [String: String])? in
            guard self.playGeneration == generation, self.nextEntry?.id == mediaId else { return nil }
            let outgoing = self.loadedSourcePath ?? ""
            guard !outgoing.isEmpty else { return nil }
            let album = !self.shuffleEnabled && (self.current?.sameAlbum(as: entry) ?? false)
            let outgoingDuration = self.duration > 0
                ? self.duration : (self.current?.durationSeconds ?? 0)
            return (
                outgoing, self.current?.itemText ?? "", entry.itemText, album,
                outgoingDuration, self.loadedSourceHeaders
            )
        }
        guard let (outgoing, outgoingText, incomingText, album, outgoingDuration, outgoingHeaders) = context else {
            let nowPlaying = await MainActor.run {
                self.playGeneration == generation && self.current?.id == mediaId
            }
            if nowPlaying {
                var local = stream
                local.url = path
                await performSwap(
                    mediaId: mediaId, stream: local, entry: entry,
                    generation: generation, engine: engine, log: log
                )
            } else {
                var local = stream
                local.url = path
                QualityUpgrade.shelve(mediaId, stream: local)
                log.record("upgrade proved but the queue moved on; shelved", about: mediaId)
            }
            return
        }
        let fade = Double(PlatformSettings.shared.getInt(key: "crossfade_seconds", default: 0))
        let plan = engine.planAutomix(
            outgoingPath: outgoing,
            incomingPath: path,
            outgoingText: outgoingText,
            incomingText: incomingText,
            albumSequential: album,
            crossfadeSeconds: fade,
            outgoingDurationSeconds: outgoingDuration,
            incomingDurationSeconds: entry.durationSeconds > 0
                ? entry.durationSeconds : Double(stream.durationSec ?? 0),
            outgoingHeaders: outgoingHeaders,
            // The queued replacement is a local file by this point.
            incomingHeaders: [:]
        )
        let target = await MainActor.run { () -> (PlaybackLoadSubmissionGate, UInt64)? in
            guard self.playGeneration == generation, self.nextEntry?.id == mediaId,
                  self.loadedSourcePath == outgoing else { return nil }
            self.queueNextRevision &+= 1
            self.loadSubmissionGate.setQueueRevision(self.queueNextRevision)
            self.sourceHeadersByPath[path] = [:]
            return (self.loadSubmissionGate, self.queueNextRevision)
        }
        guard let (gate, revision) = target else { return }
        do {
            guard try gate.performIfCurrent(generation: generation, revision: revision, {
                try engine.queueNextIfCurrent(request: LoadRequest(
                    source: path,
                    title: entry.title,
                    artist: entry.artist,
                    startSeconds: plan.cueSeconds,
                    plan: plan,
                    headers: stream.headers,
                    claimedKbps: Swift.UInt32(stream.format.kbps ?? 0),
                    loudnessDb: nil,
                    durationSeconds: entry.durationSeconds > 0 ? entry.durationSeconds : stream.durationSec.map(Double.init)
                ), expectedSource: outgoing)
            }) != nil else { return }
        } catch {
            var local = stream
            local.url = path
            QualityUpgrade.shelve(mediaId, stream: local)
            log.record("upgrade could not join the blend", about: mediaId)
            return
        }
        await MainActor.run { [weak self] in
            guard let self, self.playGeneration == generation, self.nextEntry?.id == mediaId else { return }
            self.adoptAutomixPlan(plan)
        }
        QualityUpgrade.unshelve(mediaId)
        log.record("upgrade joined the blend as \(stream.format.summary)", about: mediaId)
    }

    nonisolated private func performSwap(
        mediaId: String,
        stream: QualityUpgrade.Candidate,
        entry: QueueEntry,
        generation: UInt64,
        engine: PlayerEngine,
        log: PlaybackDebugLog
    ) async {
        let snapshot = await MainActor.run { () -> (Double, Double, Bool, Double)? in
            guard self.playGeneration == generation, self.current?.id == mediaId else { return nil }
            let planned = self.pendingAutomixPlan?.fadeSeconds ?? 0
            // No plan yet still means a blend is coming. Eight seconds is the
            // plain-crossfade floor, and a swap inside that window is the cut.
            let fade = self.automixEnabled ? max(planned, 8) : planned
            return (self.position, self.duration, self.smartMixInProgress, fade)
        }
        guard let (pos, dur, mixing, fade) = snapshot else {
            QualityUpgrade.shelve(mediaId, stream: stream)
            log.record("upgrade proved but the queue moved on; shelved", about: mediaId)
            return
        }
        let horizon = max(QualityUpgrade.minRemaining, fade + 6)
        if mixing || (dur > 0 && dur - pos < horizon) {
            QualityUpgrade.shelve(mediaId, stream: stream)
            log.record(
                mixing
                    ? "upgrade shelved: a crossfade was still running"
                    : "upgrade held: the blend starts inside \(Int(horizon))s",
                about: mediaId
            )
            return
        }
        QualityUpgrade.force(mediaId, stream: stream)
        QualityUpgrade.beginAudition(mediaId)
        let warmed: String?
        if stream.url.hasPrefix("/") || stream.url.hasPrefix("file:") {
            let path = stream.url.hasPrefix("file:")
                ? (URL(string: stream.url)?.path ?? stream.url)
                : stream.url
            warmed = FileManager.default.fileExists(atPath: path) ? path : nil
        } else {
            warmed = try? await Self.streamViaKtor(
                videoId: "\(mediaId)#\(QualityUpgrade.upgraded)",
                url: stream.url,
                headers: stream.headers
            )
        }
        QualityUpgrade.endAudition(mediaId)
        guard let path = warmed else {
            QualityUpgrade.forget(mediaId)
            log.record("upgrade audition failed", about: mediaId)
            return
        }
        let again = await MainActor.run { () -> (Double, Bool, Double?, String?, [String: String])? in
            guard self.playGeneration == generation, self.current?.id == mediaId else { return nil }
            if self.smartMixInProgress { return nil }
            return (
                self.position, self.isPlaying, self.currentLoudnessDb,
                self.loadedSourcePath, self.loadedSourceHeaders
            )
        }
        guard let (nowPos, playing, loudnessDb, priorSource, priorHeaders) = again else {
            QualityUpgrade.shelve(mediaId, stream: stream)
            log.record("upgrade proved but the queue moved on; shelved", about: mediaId)
            return
        }
        // Low-energy swap placement: defer swap execution to the next local energy
        // dip in the audio curve (within 0.1–2.0s) so the 550ms crossfade begins at
        // the valley, making the seam inaudible.
        var effectivePos = nowPos
        if playing, let currentSource = priorSource {
            if let dipTime = engine.nextEnergyDip(source: currentSource, positionSeconds: nowPos) {
                let delay = dipTime - nowPos
                if delay >= 0.1 && delay <= 2.0 {
                    log.record("delaying swap by \(Int(delay * 1000))ms for energy dip at \(Int(dipTime * 1000))ms", about: mediaId)
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    let stillValid = await MainActor.run { () -> Double? in
                        guard self.playGeneration == generation, self.current?.id == mediaId, self.isPlaying else { return nil }
                        return self.position
                    }
                    guard let updatedPos = stillValid else {
                        QualityUpgrade.shelve(mediaId, stream: stream)
                        return
                    }
                    effectivePos = updatedPos
                }
            }
        }
        // Frozen before the concurrent work below: capturing the `var` itself
        // in `MainActor.run` is a Swift 6 error.
        let swapPos = effectivePos
        do {
            // Same track, better source: the engine opens the replacement and
            // equal-power crossfades into it *in place* (upstream
            // `swapCurrentToVersion`) instead of reloading the track. A reload
            // stops the voice, opens the file and seeks — which is heard as a
            // hole in the song — and it cannot align the two copies, so even a
            // fade would double the vocal.
            //
            // `startSeconds` is ignored on this path on purpose: the caller
            // only knows the audible playhead, which trails the decoder by the
            // whole output ring, and the engine is the only side that knows
            // where the samples it is about to replace actually are.
            let gate = await MainActor.run { self.loadSubmissionGate }
            guard let info = try gate.performIfCurrent(generation: generation, {
                try engine.swapSourceIfCurrent(
                    request: LoadRequest(
                        source: path,
                        title: entry.title,
                        artist: entry.artist,
                        startSeconds: swapPos,
                        plan: nil,
                        headers: stream.headers,
                        claimedKbps: Swift.UInt32(stream.format.kbps ?? 0),
                        // Same recording, new file: the figure belongs to the track,
                        // not the URL, so the upgrade keeps the current correction
                        // instead of dropping to unity mid-song.
                        loudnessDb: loudnessDb,
                        // And the same for its length — a swap continues a track
                        // that is already playing, so the current entry's figure is
                        // the right one.
                        durationSeconds: entry.durationSeconds > 0 ? entry.durationSeconds : stream.durationSec.map(Double.init)
                    ),
                    crossfadeSeconds: QualityUpgrade.swapCrossfadeSeconds,
                    expectedSource: priorSource ?? ""
                )
            }) else { return }
            await MainActor.run {
                guard self.playGeneration == generation, self.current?.id == mediaId else { return }
                QualityUpgrade.unshelve(mediaId)
                self.engineLoadedId = entry.id
                self.loadedSourcePath = info.source
                self.loadedSourceHeaders = stream.headers
                self.duration = info.durationSeconds
                // The playhead is continuous across a swap; the engine keeps it.
                self.position = swapPos
                self.nerd = engine.nerdStats()
                self.racingLossless = false
                // No syncEngineQueueNext here on purpose: the armed blend
                // survives the swap untouched — the mixer renders the current
                // voice (now the new file, same recording, aligned), and the
                // baked-in plan still applies. Re-arming would clear the
                // pending blend and re-resolve/re-plan from scratch; a swap
                // landing near the track's end would then miss the transition
                // and cut at EOS instead of blending.
                log.record(
                    "upgraded to \(stream.format.summary) in place at \(Int(swapPos * 1000))ms",
                    about: mediaId
                )
            }
            // Monitor swap crossfade completion: verify Pearson correlation rho >= 0.85.
            // If the engine rejected the swap due to mismatched recording or transcode,
            // roll back the source path and mark the track refused for upgrades.
            Task { [weak self] in
                let waitSeconds = QualityUpgrade.swapCrossfadeSeconds + 0.2
                try? await Task.sleep(nanoseconds: UInt64(waitSeconds * 1_000_000_000))
                guard let self = self else { return }
                await MainActor.run {
                    guard self.playGeneration == generation, self.current?.id == mediaId else { return }
                    let currentNerd = self.engine.nerdStats()
                    self.nerd = currentNerd
                    if let rho = currentNerd.swapCorrelation, rho < 0.85 {
                        QualityUpgrade.refuseUpgrades(mediaId)
                        if let prior = priorSource {
                            self.loadedSourcePath = prior
                            self.loadedSourceHeaders = priorHeaders
                            // No re-arm here either: the engine is still on the
                            // swapped file (the revert is bookkeeping only), so
                            // a sync would compare against the wrong source and
                            // drop the queued next. The armed blend stands.
                        }
                        log.record(
                            "swap rejected by engine (rho=\(String(format: "%.3f", rho)) < 0.85); reverted to original source",
                            about: mediaId
                        )
                    }
                }
            }
        } catch EngineError.LoadFailed(let message)
            where message.contains("transition is already running") {
            // A crossfade reached the engine before the swap did. That is a
            // race, not a verdict — keep the candidate and try again instead of
            // writing the track off.
            QualityUpgrade.shelve(mediaId, stream: stream)
            log.record("upgrade deferred: \(message)", about: mediaId)
        } catch {
            QualityUpgrade.refuseUpgrades(mediaId)
            QualityUpgrade.forget(mediaId)
            log.record("upgrade broke playback; no more swaps", about: mediaId)
        }
    }

    private func adoptAutomixPlan(_ plan: TransitionPlanRec) {
        pendingAutomixPlan = plan
        let rateNote = abs(plan.playbackRate - 1) > 0.001
            ? String(format: " @%.3fx", plan.playbackRate)
            : ""
        analysisTier = Self.tierName(plan) + rateNote
        let sources = lastAutomixAnalysisSources()
        if sources.count >= 2 {
            analysisSources = "\(sources[0]) → \(sources[1])"
        } else if let only = sources.first, !only.isEmpty {
            analysisSources = only
        } else {
            analysisSources = nil
        }
        automixCueSeconds = plan.cueSeconds
        publishSmartWindow()
    }

    private func publishSmartWindow() {
        guard automixEnabled, let plan = pendingAutomixPlan, duration > 0 else {
            smartTransitionWindow = nil
            return
        }
        let fade = plan.fadeSeconds > 0
            ? plan.fadeSeconds
            : Double(PlatformSettings.shared.getInt(key: "crossfade_seconds", default: 0))
        guard fade > 0, Self.isRealMix(plan) else {
            smartTransitionWindow = nil
            return
        }
        // Match the mixer's authoritative analysed anchor; it can finish
        // before the file ends. Zero denotes the initial duration-based plan.
        let endSeconds = plan.transitionEndSeconds.isFinite && plan.transitionEndSeconds > 0
            ? min(duration, plan.transitionEndSeconds) : duration
        let start = max(0, (endSeconds - fade) / duration)
        let end = min(1, endSeconds / duration)
        smartTransitionWindow = end > start ? TransitionWindow(start: start, end: end) : nil
    }

    private func beginSmartMixIfNeeded() {
        smartTransitionWindow = nil
        guard let plan = pendingAutomixPlan, Self.isRealMix(plan) else {
            smartMixInProgress = false
            mixFadeUntil = nil
            pendingAutomixPlan = nil
            analysisTier = nil
            return
        }
        smartMixInProgress = true
        let fade = plan.fadeSeconds > 0 ? plan.fadeSeconds : 6
        mixFadeUntil = Date().addingTimeInterval(fade)
        pendingAutomixPlan = nil
    }

    /// Whether this plan is a real transition rather than the no-analysis
    /// fallback.
    ///
    /// Was `cueSeconds > 0.05 || |playbackRate − 1| > 0.01`, which was a proxy
    /// for "the planner found something". It stopped being one: a mix-in at the
    /// top of the record is now the *correct* answer, so a well-planned
    /// transition can legitimately arrive with a cue of zero and no tempo
    /// stretch — and this read that as "no mix" and dropped the transition
    /// marker and the label, for a transition that was about to be rendered.
    ///
    /// The style used to be the only signal, which left a plain crossfade —
    /// the one a partial analysis actually plays — invisible to the upgrade
    /// guard. Any ramp of a second or more is a transition the quality swap
    /// must not cut across.
    private static func isRealMix(_ plan: TransitionPlanRec) -> Bool {
        switch plan.style {
        case .djBlend, .djFilter: return true
        case .equalPower, .gapless: return plan.fadeSeconds >= 1
        }
    }

    private static func tierName(_ plan: TransitionPlanRec) -> String {
        switch plan.style {
        case .djBlend: return "beatmatched blend"
        case .djFilter: return "filter ride"
        case .gapless: return "gapless"
        case .equalPower: return "crossfade"
        }
    }

    private func refreshArtwork(_ entry: QueueEntry) {
        guard let raw = entry.thumbnailUrl, !raw.isEmpty else { return }
        let sized = SharedArtwork.sized(raw, 544) ?? raw
        let headers = WebDavBridge.shared.playbackHeaders(fileUrl: sized)
        Task {
            guard let data = await ArtworkRequests.shared.data(url: sized, headers: headers), !data.isEmpty else { return }
            await MainActor.run { [weak self] in
                guard let self, self.current?.id == entry.id else { return }
                self.current?.artworkData = data
                if let i = self.queue.firstIndex(where: { $0.id == entry.id }) {
                    self.queue[i].artworkData = data
                }
                self.nowPlaying.update(
                    id: entry.id, title: entry.title, artist: entry.artist,
                    duration: self.duration, artworkData: data,
                    thumbnailUrl: entry.thumbnailUrl, isPlaying: self.isPlaying, position: self.position
                )
            }
        }
    }
}

/// UniFFI callback implementation — hops to the main queue, since views read
/// this state directly.
final class EngineCallbacks: EngineCallback, @unchecked Sendable {
    private weak var controller: PlaybackController?

    init(controller: PlaybackController) {
        self.controller = controller
    }

    func onStateChanged(state: PlaybackState) {
        Task { @MainActor in controller?.handleState(state) }
    }

    func onTrackEnded(reason: TrackEndReason, source: String) {
        Task { @MainActor in guard controller?.dolbyRenderer == nil else { return }; controller?.handleTrackEnded(reason, source: source) }
    }

    func onError(message: String) {
        PlaybackDebugLog.shared.record("engine error: \(message)")
        Task { @MainActor in guard controller?.dolbyRenderer == nil else { return }; controller?.handleError(message) }
    }

    func onHandoff(info: TrackInfoRec) {
        Task { @MainActor in guard controller?.dolbyRenderer == nil else { return }; controller?.handleHandoff(info) }
    }

    func onDurationChanged(seconds: Double) {
        Task { @MainActor in guard controller?.dolbyRenderer == nil else { return }; controller?.handleDuration(seconds) }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

/// Bridge callback adapter for StreamDownloadBridge.
private final class DownloadCallbackAdapter: StreamDownloadBridgeDownloadCallback {
    private let onResult: (String?, String?) -> Void

    init(onResult: @escaping (String?, String?) -> Void) {
        self.onResult = onResult
    }

    func onResult(path: String?, message: String?) {
        onResult(path, message)
    }
}

/// Bridge callback adapter for LyricsBridge.fetchAttributed.
private final class AttributedLyricsAdapter: LyricsBridgeAttributedLyricsCallback {
    private let handler: (String, String, [LyricLineDto]) -> Void
    init(_ handler: @escaping (String, String, [LyricLineDto]) -> Void) {
        self.handler = handler
    }
    func onResult(source: String, sourceLabel: String, lines: [LyricLineDto]) {
        handler(source, sourceLabel, lines)
    }
}

private final class CustomStreamAdapter: SourceBridgeStreamCallback {
    private let handler: (String?, String?) -> Void
    init(_ handler: @escaping (String?, String?) -> Void) { self.handler = handler }
    func onResult(json: String?, message: String?) { handler(json, message) }
}

private final class AuthAdapter: ScrobbleBridgeAuthCallback {
    private let handler: (Bool, String?) -> Void
    init(_ handler: @escaping (Bool, String?) -> Void) { self.handler = handler }
    func onResult(ok: Bool, message: String?) { handler(ok, message) }
}

private final class CanvasAdapter: CanvasBridgeCanvasCallback {
    private let handler: (String?) -> Void
    init(_ handler: @escaping (String?) -> Void) { self.handler = handler }
    func onResult(json: String?) { handler(json) }
}

/// Serial background analysis avoids a burst of decodes after rapid skips.
private actor AutomixQueueRanker {
    static let shared = AutomixQueueRanker()
    func rank(currentPath: String, candidatePaths: [String], currentText: String,
              candidateTexts: [String], crossfadeSeconds: Double, skipVocals: Bool) -> [UInt32] {
        guard !Task.isCancelled else { return [] }
        return rankAutomixCandidates(
            currentPath: currentPath, candidatePaths: candidatePaths,
            currentText: currentText, candidateTexts: candidateTexts,
            crossfadeSeconds: crossfadeSeconds, skipVocals: skipVocals
        )
    }
}

private final class AutoPlayAdapter: AutoPlayBridgeAutoPlayCallback {
    private let handler: (String?, String?) -> Void
    init(_ handler: @escaping (String?, String?) -> Void) { self.handler = handler }
    func onResult(json: String?, message: String?) { handler(json, message) }
}

#if DEBUG
extension PlaybackController {
#if os(iOS)
    /// Explicit, muted cold-launch diagnostic: exercise the saved queue that
    /// init restored, rather than loading a replacement fixture in this process.
    func verifyRestoredResumeBehavior(mixing: Bool) async {
        let savedQueue = UserDefaults.standard.data(forKey: "bitchord_last_played")
        let savedContext = PlatformSettings.shared.getString(key: "last_playback_context", default: "")
        let savedMixing = mixWithOtherAudio
        let savedAutomix = automixEnabled
        let savedVolume = volume
        let saved = LastPlayed.load()
        let background = UIApplication.shared.beginBackgroundTask(withName: "restored resume verification")
        defer { UIApplication.shared.endBackgroundTask(background) }
        var checks: [String: Bool] = [:]
        var samples: [[String: Any]] = []
        func sample(_ label: String) {
            let session = AVAudioSession.sharedInstance()
            let row: [String: Any] = ["label": label, "id": current?.id ?? "",
                "position": position, "enginePosition": engine.positionSeconds(),
                "state": String(describing: state), "audioActive": AudioSessionManager.isActive,
                "category": session.category.rawValue, "options": session.categoryOptions.rawValue,
                "policy": session.routeSharingPolicy.rawValue, "error": lastError ?? ""]
            samples.append(row)
            debugLog.record("restored resume verification \(row)")
        }
        if let saved {
            let entry = saved.tracks[saved.index]
            checks["restored_track_and_position"] = current?.id == entry.id
                && playingIndex == saved.index && abs(position - saved.position) < 0.01
            checks["cold_output_inactive"] = !started && !AudioSessionManager.isActive && state == .paused
            sample("cold restore")
            do {
                setMixWithOtherAudio(mixing)
                setAutomixEnabled(false)
                volume = 0
                togglePlayPause()
                await playbackStartTask?.value
                // Native commands finish submitting before the render thread
                // publishes its first position snapshot. Observe that snapshot
                // before checking the restored seek, rather than reading 0.
                for _ in 0..<40 {
                    if !isPlaying || engine.positionSeconds() >= max(0, saved.position - 0.1) { break }
                    try await Task.sleep(for: .milliseconds(50))
                }
                checks["loaded_saved_track"] = isPlaying && current?.id == entry.id && lastError == nil
                let resumedAt = engine.positionSeconds()
                checks["loaded_saved_position"] = abs(resumedAt - saved.position) < 1
                sample("first play")
                try await Task.sleep(for: .seconds(3))
                checks["playback_progress"] = isPlaying && engine.positionSeconds() > resumedAt + 2
                let session = AVAudioSession.sharedInstance()
                checks["mixing_preference_preserved"] = mixWithOtherAudio == mixing
                    && session.categoryOptions.contains(.mixWithOthers) == mixing
                checks["compatible_routing_policy"] = session.routeSharingPolicy == (mixing ? .default : .longFormAudio)
                checks["active_playback_category"] = AudioSessionManager.isActive && session.category == .playback
                sample("playing")
                pausePlayback()
                let pausedAt = engine.positionSeconds()
                try await Task.sleep(for: .milliseconds(500))
                checks["stable_pause"] = state == .paused && abs(engine.positionSeconds() - pausedAt) < 0.1
                try await nowPlaying.onPlayAsync?()
                try await Task.sleep(for: .seconds(2))
                checks["resume_progress"] = isPlaying && engine.positionSeconds() > pausedAt + 1
                sample("resumed")
            } catch {
                checks["runtime_error"] = false
                debugLog.record("restored resume verification error: \(error)")
            }
        } else {
            checks["saved_track_available"] = false
        }
        pausePlayback()
        playGeneration &+= 1
        resumeGeneration &+= 1
        loadSubmissionGate.advance(to: playGeneration) { [engine] in try? engine.stop() }
        nowPlaying.stop()
        await AudioSessionManager.deactivate()
        setMixWithOtherAudio(savedMixing)
        setAutomixEnabled(savedAutomix)
        volume = savedVolume
        if let savedQueue { UserDefaults.standard.set(savedQueue, forKey: "bitchord_last_played") }
        else { UserDefaults.standard.removeObject(forKey: "bitchord_last_played") }
        PlatformSettings.shared.putString(key: "last_playback_context", value: savedContext)
        restoreSession()
        checks["saved_queue_restored"] = UserDefaults.standard.data(forKey: "bitchord_last_played") == savedQueue
        checks["saved_preferences_restored"] = mixWithOtherAudio == savedMixing && automixEnabled == savedAutomix
            && volume == savedVolume
        let result: [String: Any] = ["checks": checks, "samples": samples, "mixing": mixing,
            "passed": !checks.isEmpty && checks.values.allSatisfy { $0 }]
        let report = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("restored-resume-\(mixing ? "mixing" : "exclusive")-verification.json")
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: report, options: .atomic)
        }
        debugLog.record("restored resume verification complete: \(checks)")
    }

    /// Explicit, muted device diagnostic. Uses the signed-in account already
    /// restored by AuthController and restores the user's saved queue afterward.
    func verifyRapidNavigation() async {
        let savedQueue = UserDefaults.standard.data(forKey: "bitchord_last_played")
        let savedContext = PlatformSettings.shared.getString(key: "last_playback_context", default: "")
        let savedAutomix = automixEnabled
        let savedVolume = volume
        let background = UIApplication.shared.beginBackgroundTask(withName: "navigation verification")
        defer {
            UIApplication.shared.endBackgroundTask(background)
            setAutomixEnabled(savedAutomix)
            volume = savedVolume
            if let savedQueue { UserDefaults.standard.set(savedQueue, forKey: "bitchord_last_played") }
            else { UserDefaults.standard.removeObject(forKey: "bitchord_last_played") }
            PlatformSettings.shared.putString(key: "last_playback_context", value: savedContext)
            restoreSession()
        }
        let ids = ["8UhQfqMkObk", "r6fihQByHx0", "gOnyq8DjpFY", "qKyF5R-IE64",
                   "pNxTO1czMkc", "QX1KRphxnQc", "Xxq1XfsQOIE", "35tNuvmBVMc",
                   "N7IxlspnaQw", "9NM0hPDWIyg"]
        let entries = ids.enumerated().map { index, id in
            QueueEntry(id: id, title: "Navigation fixture \(index + 1)", artist: "BitChord",
                       source: "yt:" + id, durationText: "", isLocal: false)
        }
        var checks: [String: Bool] = [:]
        var samples: [[String: Any]] = []
        func sample(_ label: String) {
            let row: [String: Any] = ["label": label, "id": current?.id ?? "", "index": playingIndex,
                "state": String(describing: state), "position": position, "error": lastError ?? ""]
            samples.append(row)
            debugLog.record("navigation verification \(row)")
        }
        do {
            setAutomixEnabled(false)
            volume = 0
            play(entries)
            for _ in 0..<50 {
                if (isPlaying && duration > 0) || lastError != nil { break }
                try await Task.sleep(for: .milliseconds(400))
            }
            checks["initial_track_playing"] = isPlaying && lastError == nil
            checks["initial_duration_from_resolver"] = duration > 0
            try await Task.sleep(for: .milliseconds(400))
            checks["initial_progress_fraction"] = duration > 0 && position > 0 && position / duration > 0
            seek(to: 15)
            try await Task.sleep(for: .seconds(1))
            checks["seek_changes_real_position"] = isPlaying && position >= 15 && position < 19
            sample("initial")
            var played = isPlaying
            for step in 1..<entries.count {
                next()
                try await Task.sleep(for: .seconds(4))
                checks["next_\(step)_selected"] = current?.id == ids[step]
                checks["next_\(step)_playing"] = isPlaying && lastError == nil
                checks["next_\(step)_duration_known"] = duration > 0
                played = played || isPlaying
                sample("next \(step)")
            }
            // Force the usual restart threshold out of the way so these taps
            // exercise actual Back selection, including after failed loads.
            for step in 1...3 {
                seek(to: 0)
                previous()
                try await Task.sleep(for: .seconds(4))
                checks["back_\(step)_selected"] = current?.id == ids[ids.count - 1 - step]
                checks["back_\(step)_playing"] = isPlaying && lastError == nil
                played = played || isPlaying
                sample("back \(step)")
            }
            checks["at_least_one_live_track_played"] = played
            // Return to the first track after all failures and rapid selections.
            play([entries[0]])
            for _ in 0..<50 {
                if (isPlaying && duration > 0) || lastError != nil { break }
                try await Task.sleep(for: .milliseconds(400))
            }
            checks["first_track_still_playable"] = isPlaying
            sample("return to first")
        } catch { checks["runtime_error"] = false }
        pausePlayback()
        playGeneration &+= 1
        resumeGeneration &+= 1
        loadSubmissionGate.advance(to: playGeneration) { [engine] in try? engine.stop() }
        nowPlaying.stop()
        await AudioSessionManager.deactivate()
        let result: [String: Any] = ["checks": checks, "samples": samples,
            "quality": ["wifiSaved": PlatformSettings.shared.getString(key: "audio_quality_wifi", default: "LOSSLESS"),
                        "mobileSaved": PlatformSettings.shared.getString(key: "audio_quality_cellular", default: "LOSSLESS"),
                        "wifiPolicy": AppSettings.shared.effectiveAudioQuality(metered: false).name,
                        "mobilePolicy": AppSettings.shared.effectiveAudioQuality(metered: true).name,
                        "metered": NetworkQuality.shared.metered,
                        "effective": AppSettings.shared.effectiveAudioQuality(metered: NetworkQuality.shared.metered).name],
            "passed": !checks.isEmpty && checks.values.allSatisfy { $0 }]
        let report = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("navigation-verification.json")
        try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: report)
        debugLog.record("navigation verification complete: \(checks)")
    }

    /// Reproduces a failed/unarmed prefetch using local audio and the real engine.
    func verifyNaturalEndFallback() async {
        let savedQueue = UserDefaults.standard.data(forKey: "bitchord_last_played")
        let savedContext = PlatformSettings.shared.getString(key: "last_playback_context", default: "")
        let savedAutomix = automixEnabled, savedVolume = volume
        let savedRepeat = repeatMode
        var checks: [String: Bool] = [:]
        let background = UIApplication.shared.beginBackgroundTask(withName: "natural end verification")
        defer {
            UIApplication.shared.endBackgroundTask(background)
            setAutomixEnabled(savedAutomix); volume = savedVolume; repeatMode = savedRepeat
            if let savedQueue { UserDefaults.standard.set(savedQueue, forKey: "bitchord_last_played") }
            else { UserDefaults.standard.removeObject(forKey: "bitchord_last_played") }
            PlatformSettings.shared.putString(key: "last_playback_context", value: savedContext)
            restoreSession()
        }
        do {
            let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44100 * 8)!
            buffer.frameLength = buffer.frameCapacity
            for channel in 0..<2 {
                for frame in 0..<Int(buffer.frameLength) {
                    buffer.floatChannelData![channel][frame] = Float(sin(Double(frame) * 2 * .pi * 220 / 44100) * 0.02)
                }
            }
            var entries: [QueueEntry] = []
            for index in 0..<2 {
                let path = FileManager.default.temporaryDirectory.appendingPathComponent("natural-end-\(index).wav")
                do { let file = try AVAudioFile(forWriting: path, settings: format.settings); try file.write(from: buffer) }
                entries.append(QueueEntry(id: "natural-end-\(index)", title: "End fixture \(index)", artist: "Validation",
                    source: path.path, durationText: "0:08", isLocal: true))
            }
            volume = 0; repeatMode = .off; setAutomixEnabled(false)
            play(entries)
            for _ in 0..<100 { if isPlaying && engineLoadedId == entries[0].id { break }; try await Task.sleep(for: .milliseconds(100)) }
            checks["first_started"] = isPlaying && current?.id == entries[0].id
            // Cancel any pending arming job, then explicitly leave no successor.
            queueNextRevision &+= 1
            loadSubmissionGate.setQueueRevision(queueNextRevision)
            try engine.queueNextIfCurrent(request: LoadRequest(source: "", title: "", artist: "", startSeconds: 0,
                plan: nil, headers: [:], claimedKbps: 0, loudnessDb: nil, durationSeconds: nil), expectedSource: entries[0].source)
            checks["no_prefetched_successor"] = engine.pendingTrack() == nil
            for _ in 0..<120 { if current?.id == entries[1].id && isPlaying { break }; try await Task.sleep(for: .milliseconds(100)) }
            checks["unarmed_end_advances"] = current?.id == entries[1].id && isPlaying
            handleTrackEnded(.natural, source: entries[0].source)
            checks["obsolete_end_ignored"] = current?.id == entries[1].id && isPlaying
            for _ in 0..<120 { if state == .stopped { break }; try await Task.sleep(for: .milliseconds(100)) }
            checks["final_end_releases_loaded_voice"] = state == .stopped && engineLoadedId == nil
            togglePlayPause()
            for _ in 0..<80 { if isPlaying && engineLoadedId == entries[1].id { break }; try await Task.sleep(for: .milliseconds(100)) }
            checks["resume_after_end_reopens_from_start"] = isPlaying && engine.positionSeconds() < 2
        } catch { checks["runtime_error"] = false; debugLog.record("natural end verification error: \(error)") }
        pausePlayback(); playGeneration &+= 1; resumeGeneration &+= 1
        loadSubmissionGate.advance(to: playGeneration) { [engine] in try? engine.stop() }
        nowPlaying.stop(); await AudioSessionManager.deactivate()
        let report = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("natural-end-verification.json")
        let result: [String: Any] = ["checks": checks, "passed": !checks.isEmpty && checks.values.allSatisfy { $0 }]
        try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: report)
        debugLog.record("natural end verification complete: \(checks)")
    }

    /// An explicit diagnostic launch exercises the real controller, RemoteIO,
    /// decoder and published MediaSession. User queue/preferences are restored.
    func verifyNativeResumeBehavior() async {
        let engine = self.engine
        let savedQueue = UserDefaults.standard.data(forKey: "bitchord_last_played")
        let savedContext = PlatformSettings.shared.getString(key: "last_playback_context", default: "")
        let savedMixing = mixWithOtherAudio
        let savedAutomix = automixEnabled
        let savedVolume = volume
        let background = UIApplication.shared.beginBackgroundTask(withName: "native resume verification")
        defer {
            UIApplication.shared.endBackgroundTask(background)
            setMixWithOtherAudio(savedMixing)
            setAutomixEnabled(savedAutomix)
            volume = savedVolume
            if let savedQueue { UserDefaults.standard.set(savedQueue, forKey: "bitchord_last_played") }
            else { UserDefaults.standard.removeObject(forKey: "bitchord_last_played") }
            PlatformSettings.shared.putString(key: "last_playback_context", value: savedContext)
            restoreSession()
        }
        var checks: [String: Bool] = nowPlaying.verifyModernObservation()
        var samples: [[String: Any]] = []
        func sample(_ label: String) {
            let health = engine.outputHealth()
            let row: [String: Any] = ["label": label, "position": engine.positionSeconds(),
                "state": String(describing: state), "audioActive": AudioSessionManager.isActive,
                "rebuilds": health.outputRebuilds, "buffered": health.bufferedFrames,
                "underruns": health.callbackUnderruns, "peak": health.outputPeak]
            samples.append(row)
            debugLog.record("native resume verification \(row)")
        }
        do {
            let directory = FileManager.default.temporaryDirectory
            let wav = directory.appendingPathComponent("native-resume-fixture.wav")
            let aac = directory.appendingPathComponent("native-resume-fixture.m4a")
            let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
            let count: AVAudioFrameCount = 44100 * 40
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count)!
            buffer.frameLength = count
            for channel in 0..<2 {
                for frame in 0..<Int(count) {
                    // Vary the signal with time so a repeated output segment is
                    // distinguishable from an ordinary steady test tone.
                    let seconds = Double(frame) / 44100
                    buffer.floatChannelData![channel][frame] = Float(sin(2 * .pi * (220 * seconds + 3 * seconds * seconds)) * 0.08)
                }
            }
            do {
                let pcm = try AVAudioFile(forWriting: wav, settings: format.settings)
                try pcm.write(from: buffer)
            }
            do {
                let compressed = try AVAudioFile(forWriting: aac, settings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44100,
                    AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 128000
                ], commonFormat: .pcmFormatFloat32, interleaved: false)
                try compressed.write(from: buffer)
            }
            setMixWithOtherAudio(false)
            setAutomixEnabled(false)
            volume = 0.08
            for fixture in [wav, aac] {
                let name = fixture.pathExtension
                let entry = QueueEntry(id: "native-resume-\(name)", title: "Resume verification", artist: "BitChord", source: fixture.path, durationText: "0:40", isLocal: true)
                play([entry])
                await playbackStartTask?.value
                try await Task.sleep(for: .seconds(2))
                checks["\(name)_initial_progress"] = isPlaying && engine.positionSeconds() > 1
                sample("\(name) initial")
                for (cycle, delay) in [0.3, 10.0, 0.3].enumerated() {
                    nowPlaying.onPause?()
                    let pausedPosition = engine.positionSeconds()
                    let rebuilds = engine.outputHealth().outputRebuilds
                    try await Task.sleep(for: .seconds(delay))
                    checks["\(name)_\(cycle)_stable_pause"] = state == .paused && abs(engine.positionSeconds() - pausedPosition) < 0.1
                    checks["\(name)_\(cycle)_retained_activation"] = AudioSessionManager.isActive
                    sample("\(name) paused \(cycle)")
                    try await nowPlaying.onPlayAsync?()
                    var positions: [Double] = []
                    for _ in 0..<12 {
                        try await Task.sleep(for: .milliseconds(200))
                        positions.append(engine.positionSeconds())
                    }
                    checks["\(name)_\(cycle)_resume_progress"] = positions.last! > pausedPosition + 1.5
                    checks["\(name)_\(cycle)_monotonic"] = zip(positions, positions.dropFirst()).allSatisfy { $1 + 0.02 >= $0 }
                    checks["\(name)_\(cycle)_no_rebuild"] = engine.outputHealth().outputRebuilds == rebuilds
                    checks["\(name)_\(cycle)_audible_output"] = engine.outputHealth().outputPeak > 0.00001
                    sample("\(name) resumed \(cycle)")
                }
                // The output must NOT be reused after an interruption or an
                // explicit session release, even if its hardware format agrees.
                pausePlayback()
                // Model an inactive output without asking a previously
                // interrupted competing app to resume halfway through this
                // controlled recovery measurement.
                await AudioSessionManager.deactivate(notifyOthers: false)
                let interruptedPosition = engine.positionSeconds()
                let interruptedRebuilds = engine.outputHealth().outputRebuilds
                try await nowPlaying.onPlayAsync?()
                try await Task.sleep(for: .seconds(2))
                checks["\(name)_released_session_recovers"] = isPlaying && engine.positionSeconds() > interruptedPosition + 1 && engine.outputHealth().outputRebuilds > interruptedRebuilds
                checks["\(name)_released_session_audible"] = engine.outputHealth().outputPeak > 0.00001
                sample("\(name) released-session recovery")

                // Pause during an unfinished native Play must win. A later
                // fresh Play must remain usable after the cancelled completion.
                nowPlaying.onPause?()
                let cancelledPosition = engine.positionSeconds()
                let pendingPlay = Task { @MainActor in try await self.nowPlaying.onPlayAsync?() }
                await Task.yield()
                nowPlaying.onPause?()
                _ = try? await pendingPlay.value
                try await Task.sleep(for: .milliseconds(500))
                checks["\(name)_rapid_pause_wins"] = state == .paused && abs(engine.positionSeconds() - cancelledPosition) < 0.15
                try await nowPlaying.onPlayAsync?()
                try await Task.sleep(for: .seconds(2))
                checks["\(name)_fresh_play_after_cancellation"] = isPlaying && engine.positionSeconds() > cancelledPosition + 1
                sample("\(name) fresh play after cancellation")
                nowPlaying.onPause?()
                let mixingPosition = engine.positionSeconds()
                setMixWithOtherAudio(true)
                _ = try await AudioSessionManager.activate()
                checks["\(name)_paused_mixing_on"] = !isPlaying && AVAudioSession.sharedInstance().categoryOptions.contains(.mixWithOthers)
                    && AVAudioSession.sharedInstance().routeSharingPolicy == .default
                setMixWithOtherAudio(false)
                _ = try await AudioSessionManager.activate()
                checks["\(name)_paused_mixing_off"] = !isPlaying && !AVAudioSession.sharedInstance().categoryOptions.contains(.mixWithOthers)
                    && AVAudioSession.sharedInstance().routeSharingPolicy == .longFormAudio
                checks["\(name)_paused_mixing_keeps_position"] = abs(engine.positionSeconds() - mixingPosition) < 0.15
            }
        } catch {
            checks["runtime_error"] = false
            debugLog.record("native resume verification error: \(error)")
        }
        pausePlayback()
        playGeneration &+= 1
        resumeGeneration &+= 1
        loadSubmissionGate.advance(to: playGeneration) { try? engine.stop() }
        nowPlaying.stop()
        await AudioSessionManager.deactivate()
        let result: [String: Any] = ["checks": checks, "samples": samples,
            "quality": ["wifiSaved": PlatformSettings.shared.getString(key: "audio_quality_wifi", default: "LOSSLESS"),
                        "mobileSaved": PlatformSettings.shared.getString(key: "audio_quality_cellular", default: "LOSSLESS"),
                        "wifiPolicy": AppSettings.shared.effectiveAudioQuality(metered: false).name,
                        "mobilePolicy": AppSettings.shared.effectiveAudioQuality(metered: true).name,
                        "metered": NetworkQuality.shared.metered,
                        "effective": AppSettings.shared.effectiveAudioQuality(metered: NetworkQuality.shared.metered).name],
            "passed": !checks.isEmpty && checks.values.allSatisfy { $0 }]
        let report = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("native-resume-verification.json")
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: report, options: .atomic) }
        debugLog.record("native resume verification result \(checks)")
        print("NATIVE RESUME VERIFICATION \(checks)")
    }
#endif

    /// Explicit Mac validation launch: local audio and controlled recommendation
    /// replies. Run in an isolated bundle so the listener's queue/preferences stay intact.
    func verifyQueueBehavior() async {
        var checks: [String: Bool] = [:]
        volume = 0
        autoplayEnabled = false
        setAutomixEnabled(false)
        repeatMode = .off
        let root = FileManager.default.temporaryDirectory
        let path = root.appendingPathComponent("queue-validation.wav")
        func word<T: FixedWidthInteger>(_ value: T) -> Data {
            var value = value.littleEndian
            return withUnsafeBytes(of: &value) { Data($0) }
        }
        let count: UInt32 = 44100 * 20
        var audio = Data("RIFF".utf8); audio.append(word(UInt32(36 + count * 4)))
        audio.append(Data("WAVEfmt ".utf8)); audio.append(word(UInt32(16)))
        audio.append(word(UInt16(1))); audio.append(word(UInt16(2))); audio.append(word(UInt32(44100)))
        audio.append(word(UInt32(44100 * 4))); audio.append(word(UInt16(4))); audio.append(word(UInt16(16)))
        audio.append(Data("data".utf8)); audio.append(word(count * 4))
        audio.append(Data(count: Int(count * 4)))
        try? audio.write(to: path)
        let entry = QueueEntry(id: "queue-local", title: "", artist: "", source: path.path, durationText: "0:20", isLocal: true)
        togglePlaybackContext([entry], title: "First list", contextID: "first")
        checks["buffering_hero_shows_pause"] = isPlaybackContextPlaying("first")
        for _ in 0..<100 { if isPlaying || lastError != nil { break }; try? await Task.sleep(for: .milliseconds(100)) }
        checks["local_audio_loaded"] = isPlaying && lastError == nil
        togglePlaybackContext([entry], title: "First list", contextID: "first")
        checks["same_list_pauses"] = state == .paused && !isPlaybackContextPlaying("first")
        togglePlaybackContext([entry], title: "First list", contextID: "first")
        for _ in 0..<30 { if isPlaying { break }; try? await Task.sleep(for: .milliseconds(100)) }
        checks["same_list_resumes"] = isPlaying && isPlaybackContextPlaying("first")
        togglePlaybackContext([entry], title: "Second list", contextID: "second")
        checks["different_list_replaces_origin"] = playbackContextID == "second" && !isPlaybackContextActive("first")
        let second = QueueEntry(id: "queue-second", title: "", artist: "", source: path.path, durationText: "0:20", isLocal: true)
        let third = QueueEntry(id: "queue-third", title: "", artist: "", source: path.path, durationText: "0:20", isLocal: true)
        let list = [entry, second, third]
        setAutomixEnabled(true)
        play(list, at: 1, context: "Automix list", contextID: "automix-list", shuffleRequested: true)
        checks["automix_row_keeps_selected_and_prefix"] = current?.id == second.id && playingIndex == 1 && queue[0].id == entry.id
        play(list, context: "Automix hero", contextID: "automix-hero", shuffleRequested: true, shuffleStart: true)
        checks["automix_overrides_shuffle_seed"] = current?.id == entry.id && playingIndex == 0
        setAutomixEnabled(false)
        play(list, context: "Shuffle list", contextID: "shuffle-list", shuffleRequested: true, shuffleStart: true)
        checks["shuffle_hero_keeps_all_tracks"] = Set(queue.map(\.id)) == Set(list.map(\.id)) && playingIndex == 0
        for _ in 0..<100 { if isPlaying || lastError != nil { break }; try? await Task.sleep(for: .milliseconds(100)) }
        pausePlayback()
        engineLoadedId = nil
        current = .youtube(videoId: "test-seed01", title: "Seed", artist: "Seed artist")
        queue = [current!]
        playingIndex = 0
        state = .paused
        autoplayEnabled = true
        autoplayRefresh.invalidate()
        var replies: [(String, (String?, String?) -> Void)] = []
        recommendationFetchOverride = { seed, reply in replies.append((seed, reply)) }
        func songs(_ ids: [String]) -> String {
            let rows = ids.map { ["videoId": $0, "title": $0, "artist": "Artist \($0)"] }
            return String(data: try! JSONSerialization.data(withJSONObject: rows), encoding: .utf8)!
        }
        func settle() async { try? await Task.sleep(for: .milliseconds(100)) }
        maybeAutoplay(lowWaterRefill: true)
        checks["initial_seed_requested"] = replies.count == 1 && replies[0].0 == "test-seed01"
        addToQueue(.youtube(videoId: "manual-song", title: "Manual", artist: "Manual artist"))
        checks["queue_add_does_not_refresh_immediately"] = replies.count == 1
        maybeAutoplay(force: true)
        checks["queue_add_is_used_by_next_refresh"] = replies.count == 2
        replies[0].1(songs(["stale-song"]), nil)
        await settle()
        checks["stale_queue_reply_ignored"] = !queue.contains { $0.id == "stale-song" }
        replies[1].1(songs(["manual-song", "suggestion1", "suggestion1", "suggestion2"]), nil)
        await settle()
        checks["manual_before_deduplicated_tail"] = queue.map(\.id) == ["test-seed01", "manual-song", "suggestion1", "suggestion2"]
        addToQueue(.youtube(videoId: "suggestion1", title: "Picked manually", artist: "Artist"))
        checks["manual_pick_promotes_suggestion"] = queue.map(\.id) == ["test-seed01", "manual-song", "suggestion1", "suggestion2"] && !queue[2].fromAutoplay
        let beforeRemoval = replies.count
        if let removeIndex = queue.firstIndex(where: { $0.id == "suggestion2" }) {
            removeFromQueue(at: removeIndex)
        }
        checks["queue_removal_does_not_refresh_immediately"] = replies.count == beforeRemoval && !queue.contains { $0.id == "suggestion2" }
        let beforeRating = replies.count
        refreshAfterRating(failure: "refused", sessionGeneration: PageSession.generation())
        checks["failed_rating_keeps_tail"] = replies.count == beforeRating && queue.last?.id == "suggestion1"
        refreshAfterRating(failure: nil, sessionGeneration: PageSession.generation())
        checks["successful_rating_refreshes"] = replies.count == beforeRating + 1
        replies.last!.1(songs(["fresh-tail1"]), nil)
        await settle()
        checks["rating_replaces_only_unplayed_tail"] = queue.map(\.id) == ["test-seed01", "manual-song", "suggestion1", "fresh-tail1"]
        let outgoing = replies.last!

        let threeUpcoming = (0..<3).map {
            QueueEntry.youtube(videoId: "queued-\($0)", title: "Queued \($0)", artist: "Artist")
        }
        queue = [queue[0]] + threeUpcoming
        playingIndex = 0
        current = queue[0]
        let beforeNaturalHandoff = replies.count
        maybeAutoplay(lowWaterRefill: true)
        checks["natural_handoff_does_not_refresh_with_three_upcoming"] = replies.count == beforeNaturalHandoff

        playingIndex = 1; current = queue[1]; playGeneration &+= 1
        maybeAutoplay(lowWaterRefill: true)
        let refillReply = replies.last!
        checks["low_water_refill_uses_current_seed"] = refillReply.0 == "queued-0" && replies.count == beforeNaturalHandoff + 1
        refillReply.1(songs(["queued-1", "low-water-extra"]), nil)
        await settle()
        checks["low_water_refill_appends_and_deduplicates"] = queue.map(\.id) == ["test-seed01", "queued-0", "queued-1", "queued-2", "low-water-extra"]

        playingIndex = 2; current = queue[2]; playGeneration &+= 1
        maybeAutoplay(force: true)
        let nextReply = replies.last!
        checks["manual_next_uses_new_seed"] = nextReply.0 == "queued-1"
        playingIndex = 1; current = queue[1]; playGeneration &+= 1
        maybeAutoplay(force: true)
        checks["manual_previous_uses_selected_seed"] = replies.last!.0 == "queued-0"
        nextReply.1(songs(["stale-next1"]), nil); outgoing.1(songs(["stale-rate1"]), nil)
        await settle()
        checks["stale_selection_reply_ignored"] = !queue.contains { $0.id.hasPrefix("stale-") }
        let pending = replies.last!
        toggleAutoplay()
        pending.1(songs(["disabled001"]), nil)
        await settle()
        checks["disabled_autoplay_rejects_reply"] = !queue.contains { $0.id == "disabled001" }
        recommendationFetchOverride = nil
        sequencingTask?.cancel()
        try? engine.stop()
        let result: [String: Any] = ["checks": checks, "passed": checks.values.allSatisfy { $0 }]
        let report = URL(fileURLWithPath: "/tmp/bitchord-queue-runtime.json")
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: report, options: .atomic) }
        print("QUEUE VALIDATION \(checks)")
        #if os(macOS)
        NSApplication.shared.terminate(nil)
        #endif
    }

    /// Runs only on an explicit validation launch in a separate app container.
    func verifySleepBehavior() async {
        #if os(iOS)
        let token = UIApplication.shared.beginBackgroundTask(withName: "sleep validation")
        defer { UIApplication.shared.endBackgroundTask(token) }
        #endif
        let root = FileManager.default.temporaryDirectory
        let path = root.appendingPathComponent("sleep-validation.wav")
        let rate: UInt32 = 44100, count = 44100 * 16
        func word<T: FixedWidthInteger>(_ value: T) -> Data {
            var v = value.littleEndian; return withUnsafeBytes(of: &v) { Data($0) }
        }
        var audio = Data("RIFF".utf8); audio.append(word(UInt32(36 + count * 4)))
        audio.append(Data("WAVEfmt ".utf8)); audio.append(word(UInt32(16)))
        audio.append(word(UInt16(1))); audio.append(word(UInt16(2))); audio.append(word(rate))
        audio.append(word(rate * 4)); audio.append(word(UInt16(4))); audio.append(word(UInt16(16)))
        audio.append(Data("data".utf8)); audio.append(word(UInt32(count * 4)))
        for frame in 0..<count {
            let value = Int16(sin(Double(frame) * 2 * .pi * 440 / Double(rate)) * 3000)
            audio.append(word(value)); audio.append(word(value))
        }
        var checks: [String: Bool] = [:]
        do {
            try audio.write(to: path)
            let secondPath = root.appendingPathComponent("sleep-second.wav"); try audio.write(to: secondPath)
            volume = 0.03
            setAutomixEnabled(true)
            let first = QueueEntry(id: "sleep-first", title: "Sleep fixture", artist: "Validation", source: path.path, durationText: "0:16", isLocal: true)
            let second = QueueEntry(id: "sleep-second", title: "Second fixture", artist: "Validation", source: secondPath.path, durationText: "0:16", isLocal: true)
            play([first, second])
            for _ in 0..<100 { if isPlaying { break }; try await Task.sleep(for: .milliseconds(100)) }
            checks["started_audio"] = isPlaying
            armSleep(seconds: 8)
            try await Task.sleep(for: .seconds(4))
            checks["six_second_fade"] = engine.applicationOutputGain() < Float(volume) * 0.9
            cancelSleep()
            checks["cancel_restores_volume"] = abs(engine.applicationOutputGain() - Float(volume)) < 0.0001
            armSleep(seconds: 8)
            try await Task.sleep(for: .seconds(9))
            let stoppedPosition = engine.positionSeconds()
            try await Task.sleep(for: .milliseconds(500))
            #if os(iOS)
            checks["background_deadline"] = UIApplication.shared.applicationState == .background
            #endif
            checks["deadline_pauses"] = state == .paused && abs(engine.positionSeconds() - stoppedPosition) < 0.15
            checks["deadline_restores_volume"] = abs(engine.applicationOutputGain() - Float(volume)) < 0.0001
            cancelSleep(); setAutomixEnabled(false)
            play([first, second])
            for _ in 0..<100 { if isPlaying { break }; try await Task.sleep(for: .milliseconds(100)) }
            repeatMode = .one; autoplayEnabled = true
            startSleepAfterTrack()
            if let source = loadedSourcePath {
                try engine.setPlaybackRegions(source: source, regions: PlaybackRegions(audibleStartSeconds: 0, audibleEndSeconds: 2, excluded: []))
            }
            try await Task.sleep(for: .seconds(4))
            checks["after_song_blocks_repeat_autoplay_next"] = state == .paused && current?.id == first.id
        } catch { debugLog.record("sleep validation error: \(error)"); checks["runtime_error"] = false }
        let result: [String: Any] = ["checks": checks, "passed": checks.values.allSatisfy { $0 }, "snapshot": PlaybackDebugLog.sanitize(diagnosticSnapshot)]
        let report = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("sleep-validation.json")
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: report, options: .atomic) }
        print("SLEEP VALIDATION \(checks)")
        debugLog.record("sleep validation \(checks)")
    }
}
#endif

#if DEBUG && os(iOS)
extension PlaybackController {
    func verifyDolbyQueue() async {
        let savedQueue = UserDefaults.standard.data(forKey: "bitchord_last_played")
        let savedContext = PlatformSettings.shared.getString(key: "last_playback_context", default: "")
        let savedVolume = volume
        let sampleURL = "https://devstreaming-cdn.apple.com/videos/streaming/examples/adv_dv_atmos/Job932393e2-1e4f-4fdb-ab59-0d201f752656-107660254-Transcode_audio_full_en_atmos_0_1-en_audio/prog_index.m3u8"
        var checks: [String: Bool] = [:]
        defer {
            pausePlayback()
            dolbyRenderer?.stop(); dolbyRenderer = nil
            volume = savedVolume
            if let savedQueue { UserDefaults.standard.set(savedQueue, forKey: "bitchord_last_played") }
            else { UserDefaults.standard.removeObject(forKey: "bitchord_last_played") }
            PlatformSettings.shared.putString(key: "last_playback_context", value: savedContext)
            restoreSession()
        }
        volume = 0
        let entries = (0..<2).map { QueueEntry(id: "dolby-test-\($0)", title: "Dolby validation \($0)", artist: "Apple", source: "dolby-test:" + sampleURL, durationText: "", isLocal: false) }
        play(entries)
        for _ in 0..<150 { if isPlaying || lastError != nil { break }; try? await Task.sleep(for: .milliseconds(100)) }
        try? await Task.sleep(for: .seconds(2))
        checks["first_dolby_playing"] = isPlaying && dolbyRenderer != nil && position > 0.5
        togglePlayPause()
        let paused = playbackPosition
        try? await Task.sleep(for: .seconds(1))
        checks["pause_stable"] = state == .paused && abs(playbackPosition - paused) < 0.1
        togglePlayPause()
        try? await Task.sleep(for: .seconds(2))
        checks["resume_progress"] = isPlaying && playbackPosition > paused + 0.5
        next()
        for _ in 0..<150 { if isPlaying || lastError != nil { break }; try? await Task.sleep(for: .milliseconds(100)) }
        checks["next_dolby"] = current?.id == entries[1].id && isPlaying && dolbyRenderer != nil
        seek(to: 0); previous()
        for _ in 0..<150 { if isPlaying || lastError != nil { break }; try? await Task.sleep(for: .milliseconds(100)) }
        checks["back_dolby"] = current?.id == entries[0].id && isPlaying && dolbyRenderer != nil
        let result: [String: Any] = ["checks": checks, "passed": checks.values.allSatisfy { $0 }, "codec": nerd?.codec ?? "", "error": lastError ?? ""]
        let report = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("dolby-queue-verification.json")
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: report, options: .atomic) }
        NSLog("[BitChord] Dolby queue verification complete: %@", String(describing: checks))
    }
}
#endif
