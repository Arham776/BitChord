import Foundation
import BitChordShared
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// One playable entry in the queue. Wraps either a local file path or a
/// resolved stream URL; metadata mirrors upstream's `Song` row.
struct QueueEntry: Identifiable, Hashable, Sendable {
    let id: String
    var title: String
    var artist: String
    var source: String
    var thumbnailUrl: String?
    var durationText: String?
    var albumName: String?
    var artworkData: Data?
    /// The audio is already on a disk this device can reach, so it is not something
    /// to download and not a catalogue row to rate.
    ///
    /// True for a file in the device's own library *and* for a file on a remote
    /// library the listener configured — a share on their own server is already saved
    /// as far as they are concerned, and offering to download it would be offering to
    /// copy a file they already have. It is not, and must not be read as, "a path on
    /// this device": a remote row's [source] is an `https` address, so the places that
    /// treat `source` as a filesystem path ask again before they open it.
    var isLocal: Bool
    var fromAutoplay: Bool = false
    var artistId: String? = nil
    var albumId: String? = nil
    var setVideoId: String? = nil

    /// Clean or uncensored edition, or nil when the originating catalogue did not
    /// say.
    ///
    /// Tri-state on purpose, for the same reason it is one in the shared `Song`:
    /// "not stated" and "stated as clean" are different claims, and the cross-source
    /// matcher rejects a candidate whose stated edition contradicts the target's
    /// while refusing to reject one that has simply made no claim.
    var isExplicit: Bool? = nil

    /// Whether this row is a music video rather than catalogue audio.
    ///
    /// Load-bearing beyond the badge: a video's runtime includes a visual intro or
    /// outro, so the matcher must not treat it as evidence about the audio's length,
    /// and a source match is another recording and can be a wrong song altogether.
    var isVideo: Bool = false

    var videoId: String? {
        if source.hasPrefix("yt:") { return String(source.dropFirst(3)) }
        if isLocal { return nil }
        return id
    }

    /// "title artist album" for the Automix speech/live guard (upstream
    /// `TransitionPlanner.itemText`).
    var itemText: String {
        [title, artist, albumName ?? ""]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Upstream `TransitionPlanner.sameAlbum` — the two rows are the same
    /// recording by album id, or by album name + artist.
    func sameAlbum(as other: QueueEntry) -> Bool {
        if let a = albumId, let b = other.albumId, !a.isEmpty, a == b { return true }
        if let a = albumName, let b = other.albumName, !a.isEmpty, a == b, artist == other.artist {
            return true
        }
        return false
    }

    static func youtube(
        videoId: String,
        title: String,
        artist: String,
        thumbnailUrl: String? = nil,
        durationText: String? = nil,
        albumName: String? = nil,
        artistId: String? = nil,
        albumId: String? = nil,
        setVideoId: String? = nil,
        fromAutoplay: Bool = false
    ) -> QueueEntry {
        QueueEntry(
            id: videoId, title: title, artist: artist, source: "yt:\(videoId)",
            thumbnailUrl: thumbnailUrl, durationText: durationText, albumName: albumName,
            artworkData: nil, isLocal: false, fromAutoplay: fromAutoplay,
            artistId: artistId, albumId: albumId, setVideoId: setVideoId
        )
    }

    var durationSeconds: Double {
        let parts = (durationText ?? "").split(separator: ":").compactMap { Double($0) }
        switch parts.count {
        case 2: return parts[0] * 60 + parts[1]
        case 3: return parts[0] * 3600 + parts[1] * 60 + parts[2]
        default: return 0
        }
    }

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

    static func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let mins = total / 60
        let secs = total % 60
        let hours = mins / 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, mins % 60, secs)
            : String(format: "%d:%02d", mins, secs)
    }

    fileprivate func asSongJSON() -> SongJSON {
        SongJSON(
            videoId: videoId ?? id,
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
    private(set) var queue: [QueueEntry] = []
    private(set) var playingIndex: Int = 0
    private(set) var position: Double = 0
    private(set) var duration: Double = 0
    private(set) var lastError: String?

    var volume: Double = 0.9 {
        didSet { engine.setVolume(gain: Float(volume)) }
    }

    var isPlaying: Bool { state == .playing }
    var isBuffering: Bool { state == .buffering }
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
    private(set) var sleepUntil: Date?
    private(set) var sleepAfterTrack = false
    private(set) var autoplayEnabled = PlatformSettings.shared.getBoolean(key: "autoplay", default: true)
    private(set) var automixEnabled = PlatformSettings.shared.getBoolean(key: "smart_fade_enabled", default: false)
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
    var loudnessNormalization = PlatformSettings.shared.getBoolean(key: "loudness_normalization", default: true)
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
        if let sleepUntil {
            let remaining = sleepUntil.timeIntervalSinceNow
            guard remaining > 0 else { return nil }
            let seconds = Int(remaining.rounded())
            return String(format: "%d:%02d", seconds / 60, seconds % 60)
        }
        return sleepAfterTrack ? "After this song" : nil
    }

    /// Last resolve/upgrade/source decisions, for a UI "Debug log" action.
    var debugLogText: String { debugLog.dump() }

    private let debugLog = PlaybackDebugLog.shared
    private var pendingAutomixPlan: TransitionPlanRec?
    private var upgradeFor: String?
    private var mixFadeUntil: Date?

    private var unshuffledQueue: [QueueEntry]?
    /// Id the engine currently has loaded — nil after a cold restore until Play.
    private var engineLoadedId: String?
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
    private var loadedSourcePath: String?
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
    /// The system-primary check only needs to run every few seconds while the
    /// app is visible, even though transport position is sampled four times a second.
    @ObservationIgnored private var lastNowPlayingClaimCheck = Date.distantPast
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
    private let nowPlaying = NowPlayingController()
    private let widgetPublisher = WidgetStatePublisher()
    private let headTracker = HeadTracker()
    /// Session route-change observers. Held so they stay registered for the
    /// life of the controller; releasing them is what unsubscribes.
    private var routeObservers: [NSObjectProtocol] = []
    /// Tracks if playback was interrupted by phone calls, Siri, or other exclusive audio.
    private var wasInterrupted = false

    init() {
        let configuredSpeed = Double(PlatformSettings.shared.getFloat(key: "playback_speed", default: 1))
        playbackRate = configuredSpeed.isFinite ? min(max(configuredSpeed, 0.5), 2.0) : 1.0
        engine.registerCallback(callback: EngineCallbacks(controller: self))
        // The engine rebuilds the *device* on a route change; only the app can
        // re-activate the session it rebuilds against. See `outputRouteChanged`.
        // Also pause if the old device became unavailable (e.g. headphones unplugged).
        routeObservers = AudioSessionManager.observeRouteChanges(
            { [weak self] in
                Task { @MainActor in self?.outputRouteChanged() }
            },
            onOldDeviceUnavailable: { [weak self] in
                Task { @MainActor in
                    guard let self, self.isPlaying else { return }
                    self.togglePlayPause()
                }
            }
        )
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
                        self.pausePlayback()
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
        routeObservers += AudioSessionManager.observeSessionEvents { event in
            NSLog("[BitChord] %@", event)
        }
        // And the one session signal that asks for an action rather than a line
        // in the log: another app wants the primary audio slot. Duck, don't
        // pause — the music is the thing this app promises not to take away, and
        // the prompt is the thing that has to be heard over it.
        routeObservers += AudioSessionManager.observeSecondaryAudioSilence { [weak self] shouldSilence in
            Task { @MainActor in self?.applyDuck(shouldSilence) }
        }
        nowPlaying.onToggle = { [weak self] in self?.togglePlayPause() }
        nowPlaying.onPlay = { [weak self] in
            guard let self, !self.isPlaying, !self.isBuffering else { return }
            self.togglePlayPause()
        }
        nowPlaying.onPause = { [weak self] in
            guard let self, self.isPlaying || self.isBuffering else { return }
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
        let spatial = PlatformSettings.shared.getBoolean(key: "spatial_audio", default: false)
        let skip = PlatformSettings.shared.getBoolean(key: "skip_silence", default: false)
        let speed = PlatformSettings.shared.getFloat(key: "playback_speed", default: 1)
        playbackRate = Double(speed).isFinite ? min(max(Double(speed), 0.5), 2.0) : 1.0
        let eq = Self.currentEqTuning()
        engineStartupTask = Task.detached(priority: .utility) { [weak self] in
            do {
                // The session has to be up before the output stream exists, and
                // the iOS session owns the hardware format — so this is awaited,
                // and its answer is what the engine is told to open at.
                let format = await AudioSessionManager.activate()
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
                try eng.setLoudnessEnabled(
                    enabled: PlatformSettings.shared.getBoolean(key: "loudness_normalization", default: true)
                )
                if spatial {
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
                self.pollWidgetCommands()
                guard self.state == .playing else { return }
                self.position = self.engine.positionSeconds()
                self.positionSampledAt = Date()
                self.nowPlaying.update(position: self.position)
                if Date().timeIntervalSince(self.lastNowPlayingClaimCheck) >= 2 {
                    self.lastNowPlayingClaimCheck = Date()
                    self.nowPlaying.reclaimAfterOtherAudioStops()
                }
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
    func reactivateAudioSessionAfterForeground() {
        guard started, state == .playing else { return }
        Task.detached(priority: .userInitiated) { [weak self] in
            _ = await AudioSessionManager.activate()
            await MainActor.run { [weak self] in
                guard let self, self.state == .playing else { return }
                self.nowPlaying.requestPrimaryIfPossible()
            }
        }
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
    private func outputRouteChanged() {
        guard started, state == .playing else { return }
        let engine = self.engine
        Task.detached(priority: .userInitiated) {
            _ = await AudioSessionManager.activate()
            do {
                try engine.requestOutputRebuild(force: true)
            } catch {
                NSLog("[BitChord] output rebuild after route change failed: \(error)")
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
        duckTask = Task.detached(priority: .userInitiated) {
            let steps = 20
            for step in 1...steps {
                if Task.isCancelled { return }
                let progress = Float(step) / Float(steps)
                engine.setVolume(gain: from + (to - from) * progress)
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
    }

    // ---- Queue operations ---------------------------------------------------

    /// Plays `entries`, starting at `index`. Replaces the queue.
    func play(_ entries: [QueueEntry], at index: Int = 0, context: String? = nil) {
        noteLocalIntent()
        guard entries.indices.contains(index) else { return }
        let entry = entries[index]
        // Same song already loading or playing: extra taps are from the
        // download delay, not a request to restart.
        if current?.id == entry.id, state == .buffering || state == .playing {
            return
        }
        if current?.id == entry.id, state == .paused, engineLoadedId == nil {
            queue = entries
            playingIndex = index
            persistSession()
            togglePlayPause()
            return
        }
        queue = entries
        playbackContext = context
        unshuffledQueue = nil
        shuffleEnabled = false
        restoredStart = nil
        repeatAllStash = []
        repeatAllStashSeed = nil
        persistSession()
        startEngineIfNeeded()
        loadCurrent(index)
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
            volume: volume
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
        playbackContext = savedContext.isEmpty ? nil : savedContext
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
        engineLoadedId = nil
        loadedSourcePath = nil
        loadedSourceHeaders = [:]
        sourceHeadersByPath.removeAll(keepingCapacity: true)
        state = .paused
        if let entry = current {
            nowPlaying.update(
                title: entry.title, artist: entry.artist,
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
        let at = min(playingIndex + 1, queue.count)
        queue.insert(entry, at: at)
        if var original = unshuffledQueue {
            original.insert(entry, at: min(at, original.count))
            unshuffledQueue = original
        }
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
        maybeAutoplay(force: true)
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
        let item = copy.remove(at: from)
        let insertAt = min(max(to, 0), copy.count)
        copy.insert(item, at: insertAt)
        queue = copy
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
        queue.append(entry)
        unshuffledQueue?.append(entry)
        persistSession()
        if wasEmpty, isIdle {
            // Nothing was playing and nothing was queued: this is the queue.
            playingIndex = 0
            loadCurrent(0)
            return
        }
        syncEngineQueueNext()
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
            if !queue.isEmpty { loadCurrent(min(playingIndex, queue.count - 1)) }
            return
        }
        if engineLoadedId != current?.id {
            // Only when it is still the track the position was saved for.
            let start = restoredStart.flatMap { $0.entryId == current?.id ? $0.position : nil }
            restoredStart = nil
            loadCurrent(playingIndex, startAt: start)
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
            // Reflect intent immediately so a second tap cancels this resume.
            state = .playing
            let engine = self.engine
            Task.detached(priority: .userInitiated) { [weak self] in
                // The engine still owns the loaded source here. Its current
                // format snapshot is enough to prepare the output after the
                // audio session has been reactivated.
                let sourceFormat = engine.nerdStats()
                let matchRate = PlatformSettings.shared.getBoolean(
                    key: "match_source_sample_rate", default: true
                )
                let sessionFormat = await AudioSessionManager.activate(
                    preferredSampleRate: matchRate
                        ? (sourceFormat.sampleRate > 0 ? Double(sourceFormat.sampleRate) : nil)
                        : nil
                )
                do {
                    _ = try gate.performIfCurrent(generation: selection) {
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
                          self.current?.id == self.engineLoadedId
                    else { return }
                    do {
                        try engine.play()
                        self.state = .playing
                        let speed = Double(PlatformSettings.shared.getFloat(key: "playback_speed", default: 1))
                        self.playbackRate = speed.isFinite ? min(max(speed, 0.5), 2.0) : 1.0
                        self.positionSampledAt = Date()
                        self.nowPlaying.updateRate(speed, position: self.position)
                    } catch {
                        self.state = .paused
                        self.lastError = "Audio output could not resume: \(error)"
                    }
                }
            }
        }
    }

    private func pausePlayback() {
        resumeGeneration &+= 1
        wasInterrupted = false
        let loading = state == .buffering
        if !loading { position = engine.positionSeconds() }
        positionSampledAt = Date()
        state = .paused
        try? engine.pause()
        if loading {
            playGeneration &+= 1
            engineLoadedId = nil
            let engine = self.engine
            loadSubmissionGate.advance(to: playGeneration) { try? engine.stop() }
        }
        nowPlaying.updateRate(0, position: position)
        persistSession()
        deactivateAudioSessionIfIdle()
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
            if self.resumeGeneration != intent || self.isPlaying || self.isBuffering {
                _ = await AudioSessionManager.activate()
            }
        }
    }

    func next() {
        noteLocalIntent()
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
        if trySkipToArmed(target) { return }
        loadCurrent(target)
    }

    /// Promotes the engine's armed successor when it is the requested queue
    /// entry, and adopts it like a completed load. Returns false when nothing
    /// suitable is armed — the caller loads normally.
    ///
    /// The peek comes first because promoting has the side effect of moving
    /// the engine: only the picked track may be promoted, never whatever
    /// happens to be armed (repeat-one arms the current track itself).
    private func trySkipToArmed(_ target: Int) -> Bool {
        guard queue.indices.contains(target) else { return false }
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
            loadCurrent(target)
            return true
        }
        // A paused output stays muted across the promote — the mixer flag is
        // separate from the transport — so unmute explicitly. Idempotent when
        // already playing.
        try? engine.play()
        let headers = sourceHeadersByPath.removeValue(forKey: info.source) ?? [:]
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
        persistSession()
        syncEngineQueueNext()
        if next != .all {
            maybeAutoplay()
        }
    }

    func toggleShuffle() {
        if shuffleEnabled {
            if let original = unshuffledQueue {
                let currentId = current?.id
                queue = original
                if let currentId, let idx = queue.firstIndex(where: { $0.id == currentId }) {
                    playingIndex = idx
                }
            }
            unshuffledQueue = nil
            shuffleEnabled = false
        } else {
            unshuffledQueue = queue
            let head = Array(queue.prefix(playingIndex + 1))
            var tail = Array(queue.dropFirst(playingIndex + 1))
            tail.shuffle()
            queue = head + tail
            shuffleEnabled = true
        }
        persistSession()
        syncEngineQueueNext()
    }

    func seek(to seconds: Double) {
        noteLocalIntent()
        // Queues and returns: the playhead is the engine's to move, and waiting
        // for it here would stall whatever thread asked — usually the main one.
        guard engineLoadedId == current?.id, engineLoadedId != nil else { return }
        engine.seek(seconds: seconds)
        nowPlaying.update(position: seconds)
        position = seconds
        positionSampledAt = Date()
    }

    func removeFromQueue(at offsets: IndexSet) {
        let adjusted = offsets.filter { $0 != playingIndex && queue.indices.contains($0) }
        guard !adjusted.isEmpty else { return }
        let removedIds = Set(adjusted.map { queue[$0].id })
        queue.remove(atOffsets: IndexSet(adjusted))
        if let original = unshuffledQueue {
            unshuffledQueue = original.filter { !removedIds.contains($0.id) }
        }
        removedIds.forEach { QualityUpgrade.forget($0) }
        if playingIndex >= queue.count { playingIndex = max(0, queue.count - 1) }
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
        try? engine.setSpatialEnabled(enabled: enabled)
        if enabled {
            headTracker.start(engine: engine)
        } else {
            headTracker.stop()
        }
    }

    func updateSpeed(_ speed: Float) {
        let sampledPosition = isPlaying ? engine.positionSeconds() : position
        let sampledAt = Date()
        try? engine.setPlaybackSpeed(speed: speed)
        let rate = Double(speed)
        playbackRate = rate.isFinite ? min(max(rate, 0.5), 2.0) : 1.0
        position = sampledPosition
        positionSampledAt = sampledAt
        nowPlaying.updateRate(isPlaying ? Double(speed) : 0)
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
        loudnessNormalization = enabled
        PlatformSettings.shared.putBoolean(key: "loudness_normalization", value: enabled)
        try? engine.setLoudnessEnabled(enabled: enabled)
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

    func startSleep(minutes: Int) {
        sleepAfterTrack = false
        sleepUntil = Date().addingTimeInterval(TimeInterval(minutes * 60))
    }

    func startSleepAfterTrack() {
        sleepUntil = nil
        sleepAfterTrack = true
    }

    func cancelSleep() {
        sleepUntil = nil
        sleepAfterTrack = false
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
        if let original = unshuffledQueue {
            let kept = Set(queue.map(\.id))
            unshuffledQueue = original.filter { kept.contains($0.id) }
        }
        persistSession()
        syncEngineQueueNext()
    }

    func toggleAutoplay() {
        autoplayEnabled.toggle()
        AppSettings.shared.setAutoplay(value: autoplayEnabled)
        if !autoplayEnabled {
            // Upstream clears the stash when AutoPlay is switched off mid-loop
            // so ending ALL later does not resurrect dropped suggestions.
            repeatAllStash = []
            repeatAllStashSeed = nil
        } else if repeatMode != .all {
            maybeAutoplay()
        }
    }

    func toggleAutomix() {
        setAutomixEnabled(!automixEnabled)
    }

    func setAutomixEnabled(_ enabled: Bool) {
        guard automixEnabled != enabled else { return }
        automixEnabled = enabled
        AppSettings.shared.setSmartFadeEnabled(value: enabled)
        syncEngineQueueNext()
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

    private func loadCurrent(_ index: Int, startAt: Double? = nil) {
        guard queue.indices.contains(index) else { return }
        startEngineIfNeeded()
        let engineStartupTask = self.engineStartupTask
        let entry = queue[index]
        if current?.id == entry.id, playingIndex == index, engineLoadedId == entry.id,
           state == .buffering || state == .playing {
            return
        }
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
        let outgoingPosition = position
        position = startAt ?? 0
        duration = 0
        lastError = nil
        state = .buffering
        nowPlaying.updateCommands(canNext: playingIndex + 1 < queue.count || repeatMode == .all, canPrevious: true, canSeek: false)
        engineLoadedId = nil
        loadedSourcePath = nil
        loadedSourceHeaders = [:]
        sourceHeadersByPath.removeAll(keepingCapacity: true)
        nowPlaying.update(
            title: entry.title, artist: entry.artist,
            duration: 0, artworkData: entry.artworkData,
            thumbnailUrl: entry.thumbnailUrl, isPlaying: false, position: position
        )
        widgetPublisher.publish(entry: entry, isPlaying: false,
                                canNext: index + 1 < queue.count,
                                canPrevious: index > 0)
        // The next songs start fetching now, in parallel with this one, including
        // when this load is a cold resume of the track that was playing last
        // time. Waiting until the handoff is what made their download show up
        // at the end of the current song.
        warmUpcoming(around: index, generation: generation)
        if wasAudible {
            PlaybackTrackerBridge.shared.onTrackChanged(positionSeconds: Int64(outgoingPosition))
        }
        let engine = self.engine
        let loadSubmissionGate = self.loadSubmissionGate
        let prefs = ResolvePrefs.current()
        let resume = startAt ?? 0
        Task.detached(priority: .utility) {
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
                let sessionFormat = await AudioSessionManager.activate(
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
                    durationSeconds: entry.durationSeconds > 0 ? entry.durationSeconds : nil
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
                    try? engine.play()
                    self.currentLoudnessDb = resolved.loudnessDb
                    self.loadDidSucceed(
                        entry: entry, index: index, info: info,
                        startAt: resume, headers: resolved.headers
                    )
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self, self.playGeneration == generation else { return }
                    self.loadDidFail(entry: entry, error: error)
                }
            }
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
        var durationSec: Int? = nil
        /// Player-response loudness figure (YouTube only; substitutes, cache
        /// hits and local files carry none). Rides to the engine's
        /// normalization stage with the load.
        var loudnessDb: Double? = nil
        var origin: Origin = .other

        enum Origin: Sendable { case local, cache, youtube, substitute, other }

        var format: QualityUpgrade.Format {
            QualityUpgrade.Format(
                codec: lossless ? "flac" : nil,
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
            let qualityKey = NetworkQuality.shared.metered ? "audio_quality_cellular" : "audio_quality_wifi"
            let streamQuality = PlatformSettings.shared.getString(key: qualityKey, default: "LOSSLESS")
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
                    source: growing, headers: [:], kbps: 0, origin: .cache
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
            return ResolveOutcome(
                source: ResolvedSource(
                    source: cached, headers: [:], kbps: metadata?.kbps ?? 0, loudnessDb: metadata?.relativeLoudnessDb, origin: .cache
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
        let fallback = Task<ResolvedSource?, Never> {
            try? await Self.resolveYouTube(videoId: videoId, prefs: prefs)
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
                        lossless: stream.format.lossless,
                        durationSec: stream.durationSec,
                        origin: .substitute
                    ),
                    leftover: nil
                )
            }
            if let yt = await fallback.value {
                return ResolveOutcome(source: yt, leftover: nil)
            }
            throw InnertubeStreamResolver.StreamError(message: "No stream")
        }

        let race = FirstUsableSourceRace()
        _ = Task { await race.finishLookup(await lookup.value) }
        _ = Task { await race.finishFallback(await fallback.value) }

        switch await race.wait() {
        case .substitute(let stream):
            fallback.cancel()
            let source = ResolvedSource(
                source: stream.url, headers: stream.headers,
                kbps: stream.format.kbps ?? 0,
                lossless: stream.format.lossless,
                durationSec: stream.durationSec,
                origin: .substitute
            )
            return ResolveOutcome(source: source, leftover: nil)
        case .youtube(let source):
            // Preserve the slower substitute lookup for the in-playback quality
            // upgrade path instead of making it delay the first audible sample.
            return ResolveOutcome(source: source, leftover: lookup)
        case .none:
            throw InnertubeStreamResolver.StreamError(message: "No stream")
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
        do {
            let localPath = try await streamViaKtor(
                videoId: videoId, url: stream.url, headers: stream.headers, codec: stream.mimeType.lowercased().contains("opus") ? "Opus" : "AAC", kbps: stream.kbps, relativeLoudnessDb: stream.loudnessDb)
            return ResolvedSource(
                source: localPath, headers: [:], kbps: stream.kbps,
                loudnessDb: stream.loudnessDb, origin: .youtube
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
                        videoId: videoId, url: fresh.url, headers: fresh.headers, codec: fresh.mimeType.lowercased().contains("opus") ? "Opus" : "AAC", kbps: fresh.kbps, relativeLoudnessDb: fresh.loudnessDb)
                    return ResolvedSource(
                        source: localPath, headers: [:], kbps: fresh.kbps,
                        loudnessDb: fresh.loudnessDb, origin: .youtube
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
                loudnessDb: stream.loudnessDb, origin: .youtube
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
        playingDurationSec: Int? = nil
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
            isVideo: entry.isVideo
        )
        guard let stream else { return nil }
        return ResolvedSource(
            source: stream.url,
            headers: stream.headers,
            kbps: stream.kbps ?? 0,
            lossless: stream.lossless,
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

    /// Fetches the tracks around the playing one into the stream cache
    /// without queueing any. The blend's own `syncEngineQueueNext` then
    /// finds the file already on disk — and so does a manual Back: the
    /// previous track's file is what "the kept one" means, and fetching two
    /// steps behind as well as ahead is what makes back-to-back Back taps
    /// instant instead of a re-download each.
    ///
    /// A cold resume takes this path too. It does not cancel a blend that is
    /// already running: that only exists once a track is loaded, and a resume
    /// from a killed process has no engine yet. Unpausing a track the engine
    /// still holds does not come through here.
    private func warmUpcoming(around index: Int, generation: UInt64) {
        // Repeat-one never arms a different next track into the engine, but the
        // song after the loop still has to be measured while the loop runs —
        // otherwise turning repeat off starts a cold whole-track decode with
        // seconds left (upstream requestAnalysisAround). Automix self-mix only
        // needs the current file, which is already loaded.
        let ahead: [QueueEntry]
        let behind: [QueueEntry]
        if repeatMode == .one {
            ahead = (index + 1 < queue.count) ? [queue[index + 1]] : []
            behind = index > 0 ? [queue[index - 1]] : []
        } else {
            ahead = (1...2).compactMap { offset -> QueueEntry? in
                let at = index + offset
                guard queue.indices.contains(at) else { return nil }
                return queue[at]
            }
            behind = (1...2).compactMap { offset -> QueueEntry? in
                let at = index - offset
                guard queue.indices.contains(at) else { return nil }
                return queue[at]
            }
        }
        let prefetch = ahead + behind
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
    }

    private static let streamGate = StreamGate()

    /// Starts playback as soon as the first range is on disk — up to a megabyte,
    /// or half that for a client that caps lower. Remaining ranges keep
    /// appending; [StreamFileCache] is filled when the last one lands so a
    /// re-tap does not fetch again.
    private static func streamViaKtor(
        videoId: String, url: String, headers: [String: String], codec: String = "unknown", kbps: Int = 0, relativeLoudnessDb: Double? = nil
    ) async throws -> String {
        let taskKey = videoId + "|" + StreamFileCache.qualityIdentity + "|" + DiskCache.hashName(url)
        let task: Task<String, Error> = streamGate.lock.withLock {
            if let existing = streamGate.tasks[taskKey] { return existing }
            let created = Task { try await streamViaKtorOnce(videoId: videoId, url: url, headers: headers, codec: codec, kbps: kbps, relativeLoudnessDb: relativeLoudnessDb) }
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
        videoId: String, url: String, headers: [String: String], codec: String = "unknown", kbps: Int = 0, relativeLoudnessDb: Double? = nil
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
                        Task { await StreamFileCache.shared.noteGrowing(videoId: videoId, path: path, kbps: kbps, quality: qualityIdentity, relativeLoudnessDb: relativeLoudnessDb) }
                        continuation.resume(returning: path)
                    } else {
                        continuation.resume(throwing: InnertubeStreamResolver.StreamError(
                            message: message ?? "Stream failed"))
                    }
                },
                done: DownloadCallbackAdapter { path, message in
                    if let path {
                        Task { await StreamFileCache.shared.store(videoId, path: path, sourceIdentity: DiskCache.hashName(url), codec: codec, kbps: kbps, quality: qualityIdentity, relativeLoudnessDb: relativeLoudnessDb) }
                    } else if let message {
                        print("[Playback] stream tail failed for \(videoId): \(message)")
                        streamGate.lock.withLock { streamGate.growing[videoId] = nil }
                        Task { await StreamFileCache.shared.dropGrowing(videoId: videoId) }
                    }
                }
            )
        }
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
        engineLoadedId = entry.id
        loadedSourcePath = info.source
        loadedSourceHeaders = headers
        position = startAt
        positionSampledAt = Date()
        duration = info.durationSeconds
        lastError = nil
        state = .playing
        persistSession()
        refreshArtwork(entry)
        fetchLyrics(for: entry)
        fetchCanvas(for: entry)
        nerd = engine.nerdStats()
        racingLossless = QualityUpgrade.isRacing(entry.id)
        scrobbleArmed = false
        scrobbleSent = false
        if entry.source.hasPrefix("yt:") {
            PlaybackTrackerBridge.shared.onPlaying(videoId: String(entry.source.dropFirst(3)))
        }
        publishPresence()
        ScrobbleBridge.shared.nowPlaying(
            artist: scrobbleArtist(for: entry), title: entry.title, album: entry.albumName,
            durationSec: Swift.Int32(info.durationSeconds), positionMs: Swift.Int64(0)
        )
        nowPlaying.update(
            title: entry.title, artist: entry.artist,
            duration: info.durationSeconds, artworkData: entry.artworkData,
            thumbnailUrl: entry.thumbnailUrl, isPlaying: isPlaying, position: position
        )
        widgetPublisher.publish(entry: entry, isPlaying: true,
                                canNext: playingIndex + 1 < queue.count,
                                canPrevious: index > 0)
        lookForBetterCopy(entry, codec: info.codec, kbps: info.kbps)
        // The incoming source must be ready before the outgoing tail begins.
        // Waiting for the current download here made prefetch start up to eight
        // seconds late, then full analysis delayed queueing it even further.
        syncEngineQueueNext()
    }

    private func loadDidFail(entry: QueueEntry, error: Error) {
        lastError = "Couldn't play “\(entry.title)” — \(error)"
        // Somebody (pause, another load, sleep, interruption) owns the
        // transport now; their state stands and only the message is new.
        // Tearing the engine down here would stop whatever they started.
        guard state == .buffering else { return }
        state = .stopped
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
        nowPlaying.updateCommands(canNext: playingIndex + 1 < queue.count || repeatMode == .all, canPrevious: current != nil,
                                  canSeek: engineLoadedId != nil && duration > 0)
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
            maybeAutoplay()
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
                    self.sourceHeadersByPath[outcome.source.source] = outcome.source.headers
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
                let safetyPlan: TransitionPlanRec? = automix ? TransitionPlanRec(
                    style: .equalPower, bassSwap: false, bassSwapFraction: 0.7,
                    filterSweep: 0, vocalOverlap: 0, fadeSeconds: safetyFade,
                    transitionEndSeconds: 0, cueSeconds: 0, playbackRate: 1,
                    bedFraction: 0, bedGainDb: 0, dipDepth: 0, dipWidth: 0,
                    postGlideSeconds: 0, outgoingDurationSeconds: outgoingDuration
                ) : nil
                guard try gate.performIfCurrent(generation: generation, revision: revision, {
                    try engine.queueNextIfCurrent(request: LoadRequest(
                    source: resolved.source, title: next.title, artist: next.artist,
                    startSeconds: 0, plan: safetyPlan, headers: resolved.headers,
                    claimedKbps: Swift.UInt32(resolved.kbps),
                    loudnessDb: resolved.loudnessDb, durationSeconds: declaredDuration
                ), expectedSource: expectedSource)
                }) != nil else { return }
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
                    let plan = engine.planAutomix(
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
                // Prefetch failure is non-fatal; the next tap/natural end re-resolves.
            }
        }
    }

    fileprivate func handleState(_ newState: PlaybackState) {
        // A load callback can arrive from the outgoing voice after the listener
        // has already selected another track. Its load result is discarded by
        // the generation gate; don't let its state callback relabel the new
        // selection as playing while that selection is still buffering.
        if state == .buffering && (newState == .playing || newState == .stopped) { return }
        // A stale natural-end/stop for a superseded source must not wipe the
        // new selection either; the gate owns that call.
        state = newState
        if let current {
            nowPlaying.update(
                title: current.title, artist: current.artist,
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
        current = queue[playingIndex]
        duration = info.durationSeconds
        position = 0
        if let entry = current {
            if !sameSong {
                refreshArtwork(entry)
                fetchLyrics(for: entry)
                fetchCanvas(for: entry)
            }
            nerd = engine.nerdStats()
            racingLossless = QualityUpgrade.isRacing(entry.id)
            scrobbleArmed = false
            scrobbleSent = false
            PlaybackTrackerBridge.shared.onTrackChanged(positionSeconds: Int64(outgoingPosition))
            if entry.source.hasPrefix("yt:") {
                PlaybackTrackerBridge.shared.onPlaying(videoId: String(entry.source.dropFirst(3)))
            }
            publishPresence()
            nowPlaying.update(
                title: entry.title, artist: entry.artist,
                duration: info.durationSeconds, artworkData: entry.artworkData,
                thumbnailUrl: entry.thumbnailUrl, isPlaying: isPlaying, position: position
            )
            engineLoadedId = entry.id
            loadedSourcePath = info.source
            loadedSourceHeaders = sourceHeadersByPath.removeValue(forKey: info.source) ?? [:]
            beginSmartMixIfNeeded()
            lookForBetterCopy(entry, codec: info.codec, kbps: info.kbps)
        }
        persistSession()
        syncEngineQueueNext()
    }

    fileprivate func handleTrackEnded(_ reason: TrackEndReason, source: String) {
        guard reason == .natural else { return }
        // A natural end for a voice the transport already left (manual skip,
        // or a blend that already handed off) must not move or stop the new
        // selection. Empty source keeps backward compatibility with callers
        // that do not report one.
        if !source.isEmpty, let loaded = loadedSourcePath, loaded != source { return }
        if sleepAfterTrack {
            sleepAfterTrack = false
            pausePlayback()
            return
        }
        if let current, current.source.hasPrefix("yt:") {
            PlaybackTrackerBridge.shared.onPlaybackFinished(positionSeconds: Int64(position))
        }
        if let current, !scrobbleSent {
            ScrobbleBridge.shared.scrobble(
                artist: scrobbleArtist(for: current), title: current.title, album: current.albumName,
                durationSec: Swift.Int32(duration)
            )
            scrobbleSent = true
        }
        // The queue advances through engine handoffs (gapless arm +
        // Automix blend), not here: by the time a natural end arrives the
        // handoff has already moved the index, and re-loading here would cut
        // what the blend just started. A natural end with tracks remaining
        // only happens when no blend armed, and the engine's queued next (or
        // an empty queue) already covers it.
        switch repeatMode {
        case .one:
            // Automix self-mix should have handed off before EOS. A natural end
            // here means the blend never armed — reopen rather than sit stopped
            // (the previous seek-after-EOF path left the decoder finished).
            restartCurrentAfterNaturalEnd()
        case .all:
            engineLoadedId = nil
            next()
        case .off:
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
        engineLoadedId = nil
        loadCurrent(index)
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
        if let sleepUntil, Date() >= sleepUntil {
            self.sleepUntil = nil
            pausePlayback()
        }
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
        guard let current, current.source.hasPrefix("yt:") else { return }
        PlaybackTrackerBridge.shared.onProgress(
            videoId: String(current.source.dropFirst(3)),
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
        guard let defaults = UserDefaults(suiteName: "group.com.example.bitchord"),
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
            if let failure = await LibraryActions.toggleLike(videoId: videoId) {
                self?.lastError = failure
            }
        }
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

    private func maybeAutoplay(force: Bool = false) {
        guard autoplayEnabled,
              repeatMode != .all,
              let current, current.source.hasPrefix("yt:") else { return }
        let remaining = queue.count - playingIndex - 1
        if !force, remaining >= 6 { return }
        let videoId = String(current.source.dropFirst(3))
        QueueBuilderBridge.shared.rememberPlayed(videoId: videoId)
        AutoPlayBridge.shared.related(videoId: videoId, callback: AutoPlayAdapter { [weak self] json, _ in
            Task { @MainActor in
                guard let self, let json else { return }
                // Repeat-all may have been switched on while the request was out.
                guard self.autoplayEnabled, self.repeatMode != .all else { return }
                let existing = (try? JSONEncoder().encode(self.queue.map { $0.asSongJSON() }))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
                let extraJson = QueueBuilderBridge.shared.extendJson(
                    existingJson: existing, candidatesJson: json, limit: Int32(8)
                )
                guard let data = extraJson.data(using: .utf8),
                      let songs = try? JSONDecoder().decode([SongDTO].self, from: data) else { return }
                let extras = songs.map {
                    QueueEntry.youtube(
                        videoId: $0.videoId, title: $0.title, artist: $0.artist,
                        thumbnailUrl: $0.thumbnailUrl, durationText: $0.durationText,
                        albumName: $0.albumName, artistId: $0.artistId, albumId: $0.albumId,
                        fromAutoplay: true
                    )
                }
                let known = Set(self.queue.map(\.id))
                self.queue.append(contentsOf: extras.filter { !known.contains($0.id) })
                await self.reorderAutoplayTailForAutomix()
                self.syncEngineQueueNext()
            }
        })
    }

    /// When Smart Sequencing is on, rank the Autoplay tail against the current
    /// track using local cache paths and bring the best mixable candidate next.
    private func reorderAutoplayTailForAutomix() async {
        guard automixEnabled,
              PlatformSettings.shared.getBoolean(key: "automix_smart_sequence", default: true),
              let current
        else { return }
        let start = autoplaySectionStart
        guard start < queue.count else { return }
        let window = Array(queue[start..<min(queue.count, start + 12)])
        guard window.count >= 2 else { return }

        var paths: [String] = []
        var texts: [String] = []
        var indices: [Int] = []
        var candidates: [QueueEntry] = []
        for (offset, entry) in window.enumerated() {
            let videoId: String?
            if entry.source.hasPrefix("yt:") {
                videoId = String(entry.source.dropFirst(3))
            } else if entry.isLocal {
                videoId = nil
            } else {
                videoId = nil
            }
            let path: String?
            if entry.isLocal, !entry.source.isEmpty, FileManager.default.fileExists(atPath: entry.source) {
                path = entry.source
            } else if let videoId {
                path = await StreamFileCache.shared.path(for: videoId)
            } else {
                path = nil
            }
            guard let path, FileManager.default.fileExists(atPath: path) else { continue }
            paths.append(path)
            texts.append(entry.itemText)
            indices.append(start + offset)
            candidates.append(entry)
        }
        guard paths.count >= 2,
              let currentPath = loadedSourcePath,
              FileManager.default.fileExists(atPath: currentPath)
        else { return }

        let fade = Double(PlatformSettings.shared.getInt(key: "crossfade_seconds", default: 0))
        let skipVocals = automixPerformanceMode == "EFFICIENT"
        let ranked = rankAutomixCandidates(
            currentPath: currentPath,
            candidatePaths: paths,
            currentText: current.itemText,
            candidateTexts: texts,
            crossfadeSeconds: fade,
            skipVocals: skipVocals
        )
        guard let bestLocal = ranked.first.map(Int.init),
              bestLocal >= 0,
              bestLocal < indices.count
        else { return }

        // The native planner supplies transition quality. Reorder the same
        // cached candidates using local taste and recency as well, so a
        // technically clean but repeatedly heard track does not always win.
        // The hand-built queue prefix is outside this method and is untouched.
        let mixRank = Dictionary(uniqueKeysWithValues: ranked.enumerated().map { rank, value in
            (Int(value), rank)
        })
        let taste = ListeningStore.shared.summary(includeGenres: true)
        let lastPlayedById = ListeningStore.shared.lastPlayedByTrack()
        let now = Date().timeIntervalSince1970 * 1000
        let bestTasteLocal = candidates.indices.max { lhs, rhs in
            autoplayCandidateScore(
                candidates[lhs], mixRank: mixRank[lhs] ?? ranked.count,
                candidateCount: candidates.count, taste: taste,
                lastPlayedById: lastPlayedById, now: now
            ) < autoplayCandidateScore(
                candidates[rhs], mixRank: mixRank[rhs] ?? ranked.count,
                candidateCount: candidates.count, taste: taste,
                lastPlayedById: lastPlayedById, now: now
            )
        }
        guard let bestTasteLocal else { return }
        let bestQueueIndex = indices[bestTasteLocal]
        guard bestQueueIndex != start else { return }

        var next = queue
        let best = next.remove(at: bestQueueIndex)
        next.insert(best, at: start)
        queue = next
        NSLog(
            "[BitChord] smart sequencing moved %@ ahead in Autoplay tail (transition rank %d)",
            best.title,
            Int32(mixRank[bestTasteLocal] ?? ranked.count)
        )
    }

    private func autoplayCandidateScore(
        _ entry: QueueEntry,
        mixRank: Int,
        candidateCount: Int,
        taste: ReplaySummary,
        lastPlayedById: [String: Double],
        now: TimeInterval
    ) -> Double {
        let transition = candidateCount <= 1
            ? 0.5
            : 1.0 - Double(mixRank) / Double(candidateCount - 1)
        let primaryArtist = ListeningStore.primaryArtist(entry.artist) ?? entry.artist
        let artistRank = taste.artists.firstIndex {
            $0.name.caseInsensitiveCompare(primaryArtist) == .orderedSame
        }
        let artistAffinity = artistRank.map { max(0, 1.0 - Double($0) / 10.0) } ?? 0
        let artistGenres = ListeningStore.shared.knownGenres[primaryArtist] ?? []
        let bestGenreRank = taste.genres.enumerated().first { _, genre in
            artistGenres.contains { $0.caseInsensitiveCompare(genre.name) == .orderedSame }
        }?.offset
        let genreAffinity = bestGenreRank.map { max(0, 1.0 - Double($0) / 10.0) } ?? 0
        let tasteAffinity = max(artistAffinity, genreAffinity)

        let playedAt = lastPlayedById[entry.id]
        let isRecent = (playedAt ?? 0) > now - 14 * 24 * 60 * 60 * 1000
        let novelty = playedAt == nil ? 1.0 : (isRecent ? 0.0 : 0.65)
        let repeatPenalty = isRecent ? 0.25 : 0.0

        return transition * 0.60 + tasteAffinity * 0.25 + novelty * 0.15 - repeatPenalty
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
        if let original = unshuffledQueue {
            let droppedIds = Set(dropped.map(\.id))
            unshuffledQueue = original.filter { !droppedIds.contains($0.id) }
        }
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
        unshuffledQueue?.append(contentsOf: restored)
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
        if kbps > 0 { return QualityUpgrade.Format(codec: nil, kbps: Int(kbps), lossless: false) }
        return nil
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
                            return kbps > 0
                                ? QualityUpgrade.Format(codec: nil, kbps: Int(kbps), lossless: false)
                                : nil
                        }
                        let dur = await MainActor.run { [weak self] () -> Int? in
                            guard let self, self.duration > 0 else { return nil }
                            return Int(self.duration.rounded())
                        }
                        guard let hit = await Self.resolveSubstitute(
                            entry, prefs: prefs, waitForAll: true, playingDurationSec: dur
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
                    durationSeconds: entry.durationSeconds > 0 ? entry.durationSeconds : nil
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
                        durationSeconds: entry.durationSeconds > 0 ? entry.durationSeconds : nil
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
        let start = max(0, (duration - fade) / duration)
        smartTransitionWindow = TransitionWindow(start: start, end: 1)
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
        guard let url = URL(string: sized) else { return }
        Task {
            guard let (data, _) = try? await URLSession.shared.data(from: url), !data.isEmpty else { return }
            await MainActor.run { [weak self] in
                guard let self, self.current?.id == entry.id else { return }
                self.current?.artworkData = data
                if let i = self.queue.firstIndex(where: { $0.id == entry.id }) {
                    self.queue[i].artworkData = data
                }
                self.nowPlaying.update(
                    title: entry.title, artist: entry.artist,
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
        Task { @MainActor in controller?.handleTrackEnded(reason, source: source) }
    }

    func onError(message: String) {
        Task { @MainActor in controller?.handleError(message) }
    }

    func onHandoff(info: TrackInfoRec) {
        Task { @MainActor in controller?.handleHandoff(info) }
    }

    func onDurationChanged(seconds: Double) {
        Task { @MainActor in controller?.handleDuration(seconds) }
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

private final class AutoPlayAdapter: AutoPlayBridgeAutoPlayCallback {
    private let handler: (String?, String?) -> Void
    init(_ handler: @escaping (String?, String?) -> Void) { self.handler = handler }
    func onResult(json: String?, message: String?) { handler(json, message) }
}
