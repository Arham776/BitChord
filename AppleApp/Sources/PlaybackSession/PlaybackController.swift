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
        playingIndex > 0 || (repeatMode == .all && queue.count > 1)
    }
    var canPlayNext: Bool {
        playingIndex + 1 < queue.count || (repeatMode == .all && !queue.isEmpty)
    }

    /// Upstream ExoPlayer `REPEAT_MODE_OFF / ALL / ONE`.
    enum RepeatMode: Int, CaseIterable {
        case off, all, one
    }

    private(set) var repeatMode: RepeatMode = .off
    private(set) var shuffleEnabled = false
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
    private(set) var canvasURL: URL?
    private(set) var canvasFallbackURL: URL?
    private(set) var nerd: NerdStatsRec?
    /// True while a lossless/module lookup is still running for the playing track
    /// (upstream `NerdStats.racingLossless`).
    private(set) var racingLossless = false
    /// Automix analysis tier for stats-for-nerds: `beatmatched`, `dj`, or `plain`.
    private(set) var analysisTier: String?
    /// Beat-grid confidence when native-core exposes it. Nil until then.
    private(set) var analysisConfidence: Double?
    /// Marker on the progress bar while a planned Automix window is known.
    private(set) var smartTransitionWindow: TransitionWindow?
    /// True during a real Automix (not a plain equal-power fallback).
    private(set) var smartMixInProgress = false
    private(set) var sleepUntil: Date?
    private(set) var sleepAfterTrack = false
    private(set) var autoplayEnabled = PlatformSettings.shared.getBoolean(key: "autoplay", default: true)
    private(set) var automixEnabled = PlatformSettings.shared.getBoolean(key: "smart_fade_enabled", default: false)
    var hideVolumeBar = PlatformSettings.shared.getBoolean(key: "hide_volume_bar", default: false)
    private var scrobbleArmed = false
    private var scrobbleSent = false
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
    private var restoredStart: Double?
    private var lastPersistAt = Date.distantPast

    private var positionTimer: Timer?
    private var started = false
    /// Incremented on every user-initiated load so in-flight resolves/downloads
    /// from a previous tap cannot `loadTrack`/`queueNext` into the new song.
    private var playGeneration: UInt64 = 0
    private let nowPlaying = NowPlayingController()
    private let widgetPublisher = WidgetStatePublisher()
    private let headTracker = HeadTracker()

    init() {
        engine.registerCallback(callback: EngineCallbacks(controller: self))
        nowPlaying.onToggle = { [weak self] in self?.togglePlayPause() }
        nowPlaying.onPlay = { [weak self] in
            guard let self, !self.isPlaying else { return }
            self.togglePlayPause()
        }
        nowPlaying.onPause = { [weak self] in
            guard let self, self.isPlaying else { return }
            self.togglePlayPause()
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
        let eq = EqualizerView.load().map { Float($0) }
        Task.detached(priority: .utility) {
            do {
                // The session has to be up before the output stream exists, and
                // the iOS session owns the hardware format — so this is awaited,
                // and its answer is what the engine is told to open at.
                let format = await AudioSessionManager.activate()
                try eng.start(
                    rate: format?.rate,
                    channels: format?.channels
                )
                try eng.setCrossfadeWindow(seconds: crossfade)
                try eng.setSpatialEnabled(enabled: spatial)
                try eng.setSkipSilence(enabled: skip)
                try eng.setPlaybackSpeed(speed: speed)
                try eng.setEqGains(gainsDb: eq)
                if spatial {
                    await MainActor.run { self.headTracker.start(engine: eng) }
                }
            } catch {
                await MainActor.run { self.lastError = "Audio engine failed to start: \(error)" }
            }
        }
        positionTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.pollWidgetCommands()
                guard self.state == .playing else { return }
                self.position = self.engine.positionSeconds()
                self.nowPlaying.update(position: self.position)
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

    // ---- Queue operations ---------------------------------------------------

    /// Plays `entries`, starting at `index`. Replaces the queue.
    func play(_ entries: [QueueEntry], at index: Int = 0) {
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
        unshuffledQueue = nil
        shuffleEnabled = false
        restoredStart = nil
        persistSession()
        startEngineIfNeeded()
        loadCurrent(index)
    }

    func persistSession() {
        guard !queue.isEmpty, queue.indices.contains(playingIndex) else { return }
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

    func restoreSession() {
        guard let snap = LastPlayed.load() else { return }
        queue = snap.tracks
        playingIndex = snap.index
        current = queue[snap.index]
        position = snap.position
        duration = current?.durationSeconds ?? 0
        repeatMode = snap.repeatMode
        shuffleEnabled = snap.shuffleEnabled
        volume = snap.volume
        restoredStart = snap.position
        engineLoadedId = nil
        state = .paused
        if let entry = current {
            nowPlaying.update(
                title: entry.title, artist: entry.artist,
                duration: duration, artworkData: entry.artworkData,
                thumbnailUrl: entry.thumbnailUrl, isPlaying: false
            )
            widgetPublisher.publish(entry: entry, isPlaying: false,
                                    canNext: playingIndex + 1 < queue.count,
                                    canPrevious: playingIndex > 0)
        }
    }

    func playNext(_ entry: QueueEntry) {
        noteLocalIntent()
        let at = min(playingIndex + 1, queue.count)
        queue.insert(entry, at: at)
        if var original = unshuffledQueue {
            original.insert(entry, at: min(at, original.count))
            unshuffledQueue = original
        }
        persistSession()
        syncEngineQueueNext()
    }

    /// Upstream `playRadio`: seed plus related mix via `next` + QueueBuilder.
    func playRadio(_ entry: QueueEntry) {
        play([entry], at: 0)
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

    func addToQueue(_ entry: QueueEntry) {
        noteLocalIntent()
        queue.append(entry)
        unshuffledQueue?.append(entry)
        persistSession()
        syncEngineQueueNext()
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
        if state == .buffering { return }
        if current == nil {
            if !queue.isEmpty { loadCurrent(min(playingIndex, queue.count - 1)) }
            return
        }
        if engineLoadedId != current?.id {
            let start = restoredStart
            restoredStart = nil
            loadCurrent(playingIndex, startAt: start)
            return
        }
        if isPlaying {
            // Flip the control immediately — the engine also silences the
            // device callback before the mixer thread runs Pause.
            state = .paused
            try? engine.pause()
            persistSession()
        } else {
            state = .playing
            try? engine.play()
        }
    }

    func next() {
        noteLocalIntent()
        guard !queue.isEmpty else { return }
        if playingIndex + 1 < queue.count {
            loadCurrent(playingIndex + 1)
        } else if repeatMode == .all {
            loadCurrent(0)
        }
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
        switch repeatMode {
        case .off: repeatMode = .all
        case .all: repeatMode = .one
        case .one: repeatMode = .off
        }
        persistSession()
        syncEngineQueueNext()
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
        engine.seek(seconds: seconds)
        position = seconds
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
        try? engine.setPlaybackSpeed(speed: speed)
        nowPlaying.updateRate(isPlaying ? Double(speed) : 0)
    }

    func updateSkipSilence(enabled: Bool) {
        try? engine.setSkipSilence(enabled: enabled)
    }

    func updateEq(_ gains: [Float]) {
        try? engine.setEqGains(gainsDb: gains)
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

    func downloadCurrent() {
        guard let current else { return }
        DownloadStore.shared.download(current)
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
        if autoplayEnabled { maybeAutoplay() }
    }

    func toggleAutomix() {
        setAutomixEnabled(!automixEnabled)
    }

    func setAutomixEnabled(_ enabled: Bool) {
        guard automixEnabled != enabled else { return }
        automixEnabled = enabled
        AppSettings.shared.setSmartFadeEnabled(value: enabled)
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
        let entry = queue[index]
        if current?.id == entry.id, playingIndex == index, engineLoadedId == entry.id,
           state == .buffering || state == .playing {
            return
        }
        playGeneration += 1
        let generation = playGeneration
        upgradeFor = nil
        racingLossless = false
        smartMixInProgress = false
        smartTransitionWindow = nil
        pendingAutomixPlan = nil
        mixFadeUntil = nil
        analysisTier = nil
        analysisConfidence = nil
        let wasAudible = state == .playing || (state == .paused && engineLoadedId != nil)
        let previousPath = current?.isLocal == true ? current?.source : nil
        playingIndex = index
        current = entry
        let outgoingPosition = position
        position = startAt ?? 0
        duration = 0
        lastError = nil
        state = .buffering
        engineLoadedId = nil
        nowPlaying.update(
            title: entry.title, artist: entry.artist,
            duration: 0, artworkData: entry.artworkData,
            thumbnailUrl: entry.thumbnailUrl, isPlaying: false
        )
        widgetPublisher.publish(entry: entry, isPlaying: false,
                                canNext: index + 1 < queue.count,
                                canPrevious: index > 0)
        if wasAudible {
            PlaybackTrackerBridge.shared.onTrackChanged(positionSeconds: Int64(outgoingPosition))
            try? engine.stop()
        }
        let engine = self.engine
        let automix = automixEnabled
        let prefs = ResolvePrefs.current()
        let resume = startAt ?? 0
        Task.detached(priority: .utility) {
            do {
                let outcome = try await Self.resolveSource(entry, prefs: prefs)
                let stillCurrent = await MainActor.run { [weak self] in
                    self?.playGeneration == generation
                }
                guard stillCurrent else { return }
                await MainActor.run { [weak self] in
                    self?.noteResolved(entry, outcome: outcome, prefs: prefs)
                }
                let resolved = outcome.source
                var plan: TransitionPlanRec?
                var start = resume
                if automix, resume == 0, let previousPath, !previousPath.isEmpty {
                    let fade = Double(PlatformSettings.shared.getInt(key: "crossfade_seconds", default: 0))
                    plan = engine.planAutomix(
                        outgoingPath: previousPath,
                        incomingPath: resolved.source,
                        crossfadeSeconds: fade
                    )
                    start = plan?.cueSeconds ?? 0
                }
                let info = try engine.loadTrack(request: LoadRequest(
                    source: resolved.source,
                    title: entry.title,
                    artist: entry.artist,
                    startSeconds: start,
                    plan: plan,
                    headers: resolved.headers,
                    claimedKbps: Swift.UInt32(resolved.kbps)
                ))
                await MainActor.run { [weak self] in
                    guard let self, self.playGeneration == generation else { return }
                    self.loadDidSucceed(entry: entry, index: index, info: info, startAt: resume)
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

    private struct ResolvePrefs: Sendable {
        let maxKbps: Int
        let wantLossless: Bool
        let jiosaavn: Bool
        let canSubstitute: Bool

        @MainActor
        static func current() -> ResolvePrefs {
            let quality = PlatformSettings.shared.getString(key: "download_quality", default: "LOSSLESS")
            let wifi = PlatformSettings.shared.getString(key: "audio_quality_wifi", default: "HIGH")
            return ResolvePrefs(
                maxKbps: Int(NetworkQuality.shared.maxKbps),
                wantLossless: quality == "LOSSLESS" || wifi == "HIGH",
                jiosaavn: PlatformSettings.shared.getBoolean(key: "jiosaavn_enabled", default: true),
                canSubstitute: QualityUpgrade.canSubstituteForYouTube()
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
        if let cached = await StreamFileCache.shared.path(for: videoId) {
            return ResolveOutcome(
                source: ResolvedSource(
                    source: cached, headers: [:], kbps: 0, origin: .cache
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

        enum Leg { case lookup(QualityUpgrade.Candidate?); case fallback(ResolvedSource?) }

        // `withTaskGroup` is non-throwing in Swift 6 — collect, then throw outside.
        let outcome = await withTaskGroup(of: Leg.self) { group in
            group.addTask { .lookup(await lookup.value) }
            group.addTask { .fallback(await fallback.value) }
            var lookupDone: QualityUpgrade.Candidate??
            var fallbackDone: ResolvedSource??
            var outcome: ResolveOutcome?
            for await leg in group {
                switch leg {
                case .lookup(let stream):
                    lookupDone = .some(stream)
                    if let stream {
                        fallback.cancel()
                        let src = ResolvedSource(
                            source: stream.url, headers: stream.headers,
                            kbps: stream.format.kbps ?? 0,
                            lossless: stream.format.lossless,
                            durationSec: stream.durationSec,
                            origin: .substitute
                        )
                        outcome = ResolveOutcome(source: src, leftover: nil)
                        group.cancelAll()
                    } else if case .some(let yt) = fallbackDone {
                        if let yt {
                            outcome = ResolveOutcome(source: yt, leftover: nil)
                        }
                        group.cancelAll()
                    }
                case .fallback(let yt):
                    fallbackDone = .some(yt)
                    if let yt {
                        let leftover = lookupDone == nil ? lookup : nil
                        outcome = ResolveOutcome(source: yt, leftover: leftover)
                        group.cancelAll()
                    } else if case .some(let late) = lookupDone {
                        if let late {
                            let src = ResolvedSource(
                                source: late.url, headers: late.headers,
                                kbps: late.format.kbps ?? 0,
                                lossless: late.format.lossless,
                                durationSec: late.durationSec,
                                origin: .substitute
                            )
                            outcome = ResolveOutcome(source: src, leftover: nil)
                        }
                        group.cancelAll()
                    }
                }
                if outcome != nil { break }
            }
            return outcome
        }
        if let outcome { return outcome }
        throw InnertubeStreamResolver.StreamError(message: "No stream")
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
                videoId: videoId, url: stream.url, headers: stream.headers)
            return ResolvedSource(
                source: localPath, headers: [:], kbps: stream.kbps, origin: .youtube
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
                        videoId: videoId, url: fresh.url, headers: fresh.headers)
                    return ResolvedSource(
                        source: localPath, headers: [:], kbps: fresh.kbps, origin: .youtube
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
                source: stream.url, headers: stream.headers, kbps: stream.kbps, origin: .youtube
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

    /// Starts playback as soon as the first range is on disk — up to a megabyte,
    /// or half that for a client that caps lower. Remaining ranges keep
    /// appending; [StreamFileCache] is filled when the last one lands so a
    /// re-tap does not fetch again.
    private static func streamViaKtor(
        videoId: String, url: String, headers: [String: String]
    ) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
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
                        continuation.resume(returning: path)
                    } else {
                        continuation.resume(throwing: InnertubeStreamResolver.StreamError(
                            message: message ?? "Stream failed"))
                    }
                },
                done: DownloadCallbackAdapter { path, message in
                    if let path {
                        Task { await StreamFileCache.shared.store(videoId, path: path) }
                    } else if let message {
                        print("[Playback] stream tail failed for \(videoId): \(message)")
                    }
                }
            )
        }
    }

    private func loadDidSucceed(entry: QueueEntry, index: Int, info: TrackInfoRec, startAt: Double = 0) {
        playingIndex = index
        current = entry
        engineLoadedId = entry.id
        position = startAt
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
            artist: entry.artist, title: entry.title, album: entry.albumName,
            durationSec: Swift.Int32(info.durationSeconds), positionMs: Swift.Int64(0)
        )
        nowPlaying.update(
            title: entry.title, artist: entry.artist,
            duration: info.durationSeconds, artworkData: entry.artworkData,
            thumbnailUrl: entry.thumbnailUrl, isPlaying: true
        )
        widgetPublisher.publish(entry: entry, isPlaying: true,
                                canNext: playingIndex + 1 < queue.count,
                                canPrevious: index > 0)
        lookForBetterCopy(entry, codec: info.codec, kbps: info.kbps)
        // Don't steal googlevideo bandwidth from the track that just started
        // — wait until its file is fully on disk (or a few seconds) before
        // prefetching the next one. Upstream's AudioCache also never reads
        // the currently playing entry.
        let generation = playGeneration
        let currentId = entry.id
        Task { [weak self] in
            for _ in 0..<40 {
                guard let self, self.playGeneration == generation else { return }
                if await StreamFileCache.shared.path(for: currentId) != nil { break }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            await MainActor.run { [weak self] in
                guard let self, self.playGeneration == generation else { return }
                self.syncEngineQueueNext()
            }
        }
    }

    private func loadDidFail(entry: QueueEntry, error: Error) {
        lastError = "Couldn't play “\(entry.title)” — \(error)"
        state = .stopped
    }

    /// Keeps the engine's pending-next pointing at the following queue entry
    /// so gapless/crossfade arming works (spec §3.1). Repeat-one must not
    /// arm the next song — the current track should seek to 0 at EOS.
    private func syncEngineQueueNext() {
        if repeatMode == .one {
            try? engine.queueNext(request: LoadRequest(
                source: "", title: "", artist: "", startSeconds: 0, plan: nil, headers: [:], claimedKbps: 0
            ))
            return
        }
        guard playingIndex + 1 < queue.count || (repeatMode == .all && queue.count > 1),
              let next = nextEntry else {
            maybeAutoplay()
            return
        }
        let generation = playGeneration
        let nextId = next.id
        let engine = self.engine
        let automix = automixEnabled
        let currentSource = current?.source ?? ""
        let prefs = ResolvePrefs.current()
        Task.detached(priority: .utility) {
            do {
                let outcome = try await Self.resolveSource(next, prefs: prefs)
                let stillCurrent = await MainActor.run { [weak self] in
                    guard let self else { return false }
                    return self.playGeneration == generation
                        && self.nextEntry?.id == nextId
                }
                guard stillCurrent else { return }
                await MainActor.run { [weak self] in
                    self?.noteResolved(next, outcome: outcome, prefs: prefs)
                }
                let resolved = outcome.source
                var plan: TransitionPlanRec?
                var start = 0.0
                if automix, !currentSource.isEmpty {
                    let fade = Double(PlatformSettings.shared.getInt(key: "crossfade_seconds", default: 0))
                    plan = engine.planAutomix(
                        outgoingPath: currentSource,
                        incomingPath: resolved.source,
                        crossfadeSeconds: fade
                    )
                    start = plan?.cueSeconds ?? 0
                }
                try engine.queueNext(request: LoadRequest(
                    source: resolved.source,
                    title: next.title,
                    artist: next.artist,
                    startSeconds: start,
                    plan: plan,
                    headers: resolved.headers,
                    claimedKbps: Swift.UInt32(resolved.kbps)
                ))
                if let plan {
                    await MainActor.run { [weak self] in
                        self?.adoptAutomixPlan(plan)
                    }
                }
            } catch {
                // Prefetch failure is non-fatal; the next tap/natural end re-resolves.
            }
        }
    }

    fileprivate func handleState(_ newState: PlaybackState) {
        if newState == .stopped && state == .buffering { return }
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
        if newState == .paused { persistSession() }
    }

    fileprivate func handleHandoff(_ info: TrackInfoRec) {
        // The engine flipped to the incoming track: move the queue pointer.
        if playingIndex + 1 < queue.count {
            playingIndex += 1
        } else if repeatMode == .all, !queue.isEmpty {
            playingIndex = 0
        } else {
            return
        }
        let outgoingPosition = position
        current = queue[playingIndex]
        duration = info.durationSeconds
        position = 0
        if let entry = current {
            refreshArtwork(entry)
            fetchLyrics(for: entry)
            fetchCanvas(for: entry)
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
                thumbnailUrl: entry.thumbnailUrl, isPlaying: true
            )
            engineLoadedId = entry.id
            beginSmartMixIfNeeded()
            lookForBetterCopy(entry, codec: info.codec, kbps: info.kbps)
        }
        persistSession()
        syncEngineQueueNext()
    }

    fileprivate func handleTrackEnded(_ reason: TrackEndReason) {
        guard reason == .natural else { return }
        if sleepAfterTrack {
            sleepAfterTrack = false
            try? engine.pause()
            state = .paused
            return
        }
        if let current, current.source.hasPrefix("yt:") {
            PlaybackTrackerBridge.shared.onPlaybackFinished(positionSeconds: Int64(position))
        }
        if let current, !scrobbleSent {
            ScrobbleBridge.shared.scrobble(
                artist: current.artist, title: current.title, album: current.albumName,
                durationSec: Swift.Int32(duration)
            )
            scrobbleSent = true
        }
        switch repeatMode {
        case .one:
            seek(to: 0)
            try? engine.play()
            state = .playing
        case .all:
            next()
        case .off:
            state = .stopped
            position = 0
        }
    }

    fileprivate func handleDuration(_ seconds: Double) {
        duration = seconds
        publishSmartWindow()
    }

    fileprivate func handleError(_ message: String) {
        lastError = message
        if let id = current?.id, QualityUpgrade.forcedStream(id) != nil {
            QualityUpgrade.refuseUpgrades(id)
            debugLog.record("broke on its upgrade; no more swaps", about: id)
        }
    }

    private var nextEntry: QueueEntry? {
        if playingIndex + 1 < queue.count { return queue[playingIndex + 1] }
        if repeatMode == .all, queue.count > 1 { return queue[0] }
        return nil
    }

    private func fetchLyrics(for entry: QueueEntry) {
        lyrics = []
        lyricsSourceLabel = nil
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
            lyricsLoading = false
            return
        }
        lyricsLoading = true
        let durationMs = Swift.Int64((entry.durationSeconds > 0 ? entry.durationSeconds : duration) * 1000)
        LyricsBridge.shared.fetchAttributed(
            title: entry.title,
            artist: entry.artist,
            durationMs: durationMs,
            album: entry.albumName,
            videoId: entry.videoId,
            localPath: localPath,
            callback: AttributedLyricsAdapter { [weak self] _, label, lines in
                Task { @MainActor in
                    guard let self, self.current?.id == entry.id else { return }
                    self.lyrics = lines
                    self.lyricsSourceLabel = label.isEmpty ? nil : label
                    self.lyricsLoading = false
                }
            }
        )
    }

    private func fetchCanvas(for entry: QueueEntry) {
        canvasURL = nil
        canvasFallbackURL = nil
        guard NetworkQuality.shared.canvasAllowed, !entry.isLocal else { return }
        CanvasBridge.shared.lookup(title: entry.title, artist: entry.artist, album: entry.albumName, callback: CanvasAdapter { [weak self] json in
            Task { @MainActor in
                guard let self, self.current?.id == entry.id, let json,
                      let data = json.data(using: .utf8),
                      let payload = try? JSONDecoder().decode(CanvasPayload.self, from: data),
                      let url = URL(string: payload.url) else { return }
                self.canvasURL = url
                self.canvasFallbackURL = payload.fallbackUrl.flatMap(URL.init(string:))
            }
        })
    }

    private struct CanvasPayload: Codable {
        let url: String
        let source: String
        let fallbackUrl: String?
    }

    private func tickSleep() {
        if let sleepUntil, Date() >= sleepUntil {
            self.sleepUntil = nil
            try? engine.pause()
            state = .paused
        }
        if let mixFadeUntil, Date() >= mixFadeUntil {
            self.mixFadeUntil = nil
            smartMixInProgress = false
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
                artist: current.artist, title: current.title, album: current.albumName,
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
        if isPlaying { togglePlayPause() }
    }

    func toggleLike() {
        guard let vid = current?.videoId else { return }
        let next = LibraryActions.cachedLike(vid) == "LIKE" ? "INDIFFERENT" : "LIKE"
        Task { _ = await LibraryActions.rate(videoId: vid, status: next) }
    }

    var isLiked: Bool {
        _ = LikeStore.shared.epoch
        guard let vid = current?.videoId else { return false }
        return LibraryActions.cachedLike(vid) == "LIKE"
    }

    private func maybeAutoplay(force: Bool = false) {
        guard autoplayEnabled,
              let current, current.source.hasPrefix("yt:") else { return }
        let remaining = queue.count - playingIndex - 1
        if !force, remaining >= 6 { return }
        let videoId = String(current.source.dropFirst(3))
        QueueBuilderBridge.shared.rememberPlayed(videoId: videoId)
        AutoPlayBridge.shared.related(videoId: videoId, callback: AutoPlayAdapter { [weak self] json, _ in
            Task { @MainActor in
                guard let self, let json else { return }
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
                self.syncEngineQueueNext()
            }
        })
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
                    guard let self, self.current?.id == mediaId else { return }
                    self.racingLossless = QualityUpgrade.isRacing(mediaId)
                    if self.upgradeFor == mediaId { self.upgradeFor = nil }
                    QualityUpgrade.onRaceEnd(mediaId)
                }
            }
            let still = await MainActor.run { [weak self] in
                guard let self else { return false }
                return self.playGeneration == generation && self.current?.id == mediaId
            }
            guard still, let better else { return }
            await self?.performSwap(
                mediaId: mediaId, stream: better, entry: entry,
                generation: generation, engine: eng, log: log
            )
        }
    }

    nonisolated private func performSwap(
        mediaId: String,
        stream: QualityUpgrade.Candidate,
        entry: QueueEntry,
        generation: UInt64,
        engine: PlayerEngine,
        log: PlaybackDebugLog
    ) async {
        let snapshot = await MainActor.run { () -> (Double, Double, Bool)? in
            guard self.playGeneration == generation, self.current?.id == mediaId else { return nil }
            return (self.position, self.duration, self.smartMixInProgress)
        }
        guard let (pos, dur, mixing) = snapshot else {
            QualityUpgrade.shelve(mediaId, stream: stream)
            log.record("upgrade proved but the queue moved on; shelved", about: mediaId)
            return
        }
        if dur > 0, dur - pos < QualityUpgrade.minRemaining {
            log.record(
                "upgrade abandoned: only \(Int((dur - pos) * 1000))ms of the track left",
                about: mediaId
            )
            return
        }
        if mixing {
            QualityUpgrade.shelve(mediaId, stream: stream)
            log.record("upgrade shelved: a crossfade was still running", about: mediaId)
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
        let again = await MainActor.run { () -> (Double, Bool)? in
            guard self.playGeneration == generation, self.current?.id == mediaId else { return nil }
            if self.smartMixInProgress { return nil }
            return (self.position, self.isPlaying)
        }
        guard let (nowPos, playing) = again else {
            QualityUpgrade.shelve(mediaId, stream: stream)
            log.record("upgrade proved but the queue moved on; shelved", about: mediaId)
            return
        }
        do {
            let info = try engine.loadTrack(request: LoadRequest(
                source: path,
                title: entry.title,
                artist: entry.artist,
                startSeconds: nowPos,
                plan: nil,
                headers: stream.headers,
                claimedKbps: Swift.UInt32(stream.format.kbps ?? 0)
            ))
            await MainActor.run {
                guard self.playGeneration == generation, self.current?.id == mediaId else { return }
                QualityUpgrade.unshelve(mediaId)
                self.engineLoadedId = entry.id
                self.duration = info.durationSeconds
                self.position = nowPos
                self.nerd = engine.nerdStats()
                self.racingLossless = false
                if playing { self.state = .playing }
                log.record(
                    "upgraded to \(stream.format.summary) at \(Int(nowPos * 1000))ms",
                    about: mediaId
                )
            }
        } catch {
            QualityUpgrade.refuseUpgrades(mediaId)
            QualityUpgrade.forget(mediaId)
            log.record("upgrade broke playback; no more swaps", about: mediaId)
        }
    }

    private func adoptAutomixPlan(_ plan: TransitionPlanRec) {
        pendingAutomixPlan = plan
        analysisTier = Self.tierName(plan)
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

    private static func isRealMix(_ plan: TransitionPlanRec) -> Bool {
        switch plan.style {
        case .djBlend, .djFilter: return true
        default: break
        }
        return plan.cueSeconds > 0.05 || abs(plan.playbackRate - 1) > 0.01
    }

    private static func tierName(_ plan: TransitionPlanRec) -> String {
        switch plan.style {
        case .djBlend: return "beatmatched"
        case .djFilter: return "dj"
        default: return "plain"
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
                    thumbnailUrl: entry.thumbnailUrl, isPlaying: self.isPlaying
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

    func onTrackEnded(reason: TrackEndReason) {
        Task { @MainActor in controller?.handleTrackEnded(reason) }
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
