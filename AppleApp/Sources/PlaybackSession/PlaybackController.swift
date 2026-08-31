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
    var isLocal: Bool
    var fromAutoplay: Bool = false
    var artistId: String? = nil
    var albumId: String? = nil
    var setVideoId: String? = nil

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
            isLocal: song.localPath != nil
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
    private(set) var lyricsLoading = false
    private(set) var canvasURL: URL?
    private(set) var canvasFallbackURL: URL?
    private(set) var nerd: NerdStatsRec?
    private(set) var sleepUntil: Date?
    private(set) var sleepAfterTrack = false
    private(set) var autoplayEnabled = PlatformSettings.shared.getBoolean(key: "autoplay", default: true)
    private(set) var automixEnabled = PlatformSettings.shared.getBoolean(key: "smart_fade_enabled", default: false)
    var hideVolumeBar = PlatformSettings.shared.getBoolean(key: "hide_volume_bar", default: false)
    private var scrobbleArmed = false
    private var scrobbleSent = false

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
        AudioSessionManager.activate()
        restoreSession()
        let token = PlatformSettings.shared.getString(key: "discord_token", default: "")
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
                try eng.start()
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
        let at = min(playingIndex + 1, queue.count)
        queue.insert(entry, at: at)
        persistSession()
        syncEngineQueueNext()
    }

    /// Upstream `playRadio`: seed plus related mix via `next` + QueueBuilder.
    func playRadio(_ entry: QueueEntry) {
        play([entry], at: 0)
        maybeAutoplay(force: true)
    }

    func moveQueue(from source: IndexSet, to destination: Int) {
        guard let from = source.first, from != playingIndex, destination > playingIndex else { return }
        var copy = queue
        let item = copy.remove(at: from)
        let dest = destination > from ? destination - 1 : destination
        copy.insert(item, at: min(max(dest, playingIndex + 1), copy.count))
        queue = copy
        syncEngineQueueNext()
    }

    func addToQueue(_ entry: QueueEntry) {
        queue.append(entry)
        persistSession()
        syncEngineQueueNext()
    }

    func togglePlayPause() {
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
        guard !queue.isEmpty else { return }
        if playingIndex + 1 < queue.count {
            loadCurrent(playingIndex + 1)
        } else if repeatMode == .all {
            loadCurrent(0)
        }
    }

    func previous() {
        if position > 10 {
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
        try? engine.seek(seconds: seconds)
        position = seconds
    }

    func removeFromQueue(at offsets: IndexSet) {
        let adjusted = offsets.filter { $0 != playingIndex }
        guard !adjusted.isEmpty else { return }
        let removingCurrent = offsets.contains(playingIndex)
        queue.remove(atOffsets: IndexSet(adjusted))
        if playingIndex >= queue.count { playingIndex = max(0, queue.count - 1) }
        syncEngineQueueNext()
        _ = removingCurrent
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
        queue.removeSubrange((playingIndex + 1)...)
        syncEngineQueueNext()
    }

    func toggleAutoplay() {
        autoplayEnabled.toggle()
        AppSettings.shared.setAutoplay(value: autoplayEnabled)
        if autoplayEnabled { maybeAutoplay() }
    }

    func toggleAutomix() {
        automixEnabled.toggle()
        AppSettings.shared.setSmartFadeEnabled(value: automixEnabled)
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
                let resolved = try await Self.resolveSource(entry, prefs: prefs)
                let stillCurrent = await MainActor.run { [weak self] in
                    self?.playGeneration == generation
                }
                guard stillCurrent else { return }
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
    /// PlayerBridge to get a real HTTP URL, then stream via the Ktor Darwin
    /// engine (same TLS fingerprint as the probe that succeeds — URLSession
    /// gets 403 from googlevideo due to different TLS fingerprint).
    ///
    /// Upstream's ExoPlayer starts on the first bounded range. We do the same:
    /// the first 1 MiB is written and we return that path while later ranges
    /// keep appending. The engine's GrowingFile waits at EOF until `.complete`.
    private struct ResolvedSource {
        let source: String
        let headers: [String: String]
        let kbps: Int
    }

    private struct ResolvePrefs: Sendable {
        let maxKbps: Int
        let wantLossless: Bool
        let jiosaavn: Bool

        @MainActor
        static func current() -> ResolvePrefs {
            let quality = PlatformSettings.shared.getString(key: "download_quality", default: "LOSSLESS")
            let wifi = PlatformSettings.shared.getString(key: "audio_quality_wifi", default: "HIGH")
            return ResolvePrefs(
                maxKbps: Int(NetworkQuality.shared.maxKbps),
                wantLossless: quality == "LOSSLESS" || wifi == "HIGH",
                jiosaavn: PlatformSettings.shared.getBoolean(key: "jiosaavn_enabled", default: true)
            )
        }
    }

    private static func resolveSource(_ entry: QueueEntry, prefs: ResolvePrefs) async throws -> ResolvedSource {
        if entry.source.hasPrefix("saavn:") || entry.id.hasPrefix("saavn:") {
            let id = entry.source.hasPrefix("saavn:") ? String(entry.source.dropFirst(6)) : String(entry.id.dropFirst(6))
            if let hit = await JioSaavn.streamURL(for: id) {
                return ResolvedSource(source: hit.url, headers: [:], kbps: hit.kbps)
            }
            throw InnertubeStreamResolver.StreamError(message: "JioSaavn had no stream")
        }
        guard entry.source.hasPrefix("yt:") else {
            return ResolvedSource(source: entry.source, headers: [:], kbps: 0)
        }
        let videoId = String(entry.source.dropFirst(3))
        if let cached = await StreamFileCache.shared.path(for: videoId) {
            return ResolvedSource(source: cached, headers: [:], kbps: 0)
        }
        // Upstream `resolveWithModulePriority`: start YouTube and substitutes
        // together. First usable URL wins so a slow JioSaavn/module lookup
        // cannot hold the first note hostage.
        let won = await withTaskGroup(of: ResolvedSource?.self) { group in
            group.addTask {
                try? await Self.resolveYouTube(videoId: videoId, prefs: prefs)
            }
            group.addTask {
                await Self.resolveSubstitute(entry, prefs: prefs)
            }
            var first: ResolvedSource?
            for await hit in group {
                guard let hit else { continue }
                group.cancelAll()
                first = hit
                break
            }
            return first
        }
        if let won { return won }
        throw InnertubeStreamResolver.StreamError(message: "No stream")
    }

    /// Innertube URL + first-megabyte file, the path that used to start playback alone.
    private static func resolveYouTube(videoId: String, prefs: ResolvePrefs) async throws -> ResolvedSource {
        var lastError: Error?
        for attempt in 0..<2 {
            let stream = try await InnertubeStreamResolver.shared.resolve(videoId: videoId, maxKbps: prefs.maxKbps)
            do {
                let localPath = try await streamViaKtor(
                    videoId: videoId, url: stream.url, headers: stream.headers)
                return ResolvedSource(source: localPath, headers: [:], kbps: stream.kbps)
            } catch {
                lastError = error
                let is403 = "\(error)".contains("403")
                print("[Playback] Ktor stream failed for \(videoId) attempt \(attempt+1): \(error)")
                if is403 && attempt == 0 {
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    continue
                }
                print("[Playback] falling back to direct stream for \(videoId)")
                return ResolvedSource(source: stream.url, headers: stream.headers, kbps: stream.kbps)
            }
        }
        throw lastError ?? InnertubeStreamResolver.StreamError(message: "YouTube stream failed")
    }

    /// Catalogues ranked above YouTube — first match that is the same recording.
    private static func resolveSubstitute(_ entry: QueueEntry, prefs: ResolvePrefs) async -> ResolvedSource? {
        await withTaskGroup(of: ResolvedSource?.self) { group in
            if prefs.wantLossless {
                group.addTask { await Self.resolveCustom(title: entry.title, artist: entry.artist) }
                group.addTask {
                    guard let module = await ModuleJsHost.shared.stream(
                        for: entry.title, artist: entry.artist, quality: "LOSSLESS"
                    ) else { return nil }
                    return ResolvedSource(source: module.url, headers: [:], kbps: module.kbps)
                }
            }
            if prefs.jiosaavn {
                group.addTask {
                    guard let matched = await JioSaavn.matchedStream(for: entry), matched.kbps > 256 else { return nil }
                    return ResolvedSource(source: matched.url, headers: [:], kbps: matched.kbps)
                }
            }
            var first: ResolvedSource?
            for await hit in group {
                if let hit {
                    group.cancelAll()
                    first = hit
                    break
                }
            }
            return first
        }
    }

    private static func resolveCustom(title: String, artist: String) async -> ResolvedSource? {
        await withCheckedContinuation { cont in
            SourceBridge.shared.resolveCustom(title: title, artist: artist, quality: "LOSSLESS", callback: CustomStreamAdapter { json, _ in
                guard let json, let data = json.data(using: .utf8),
                      let hit = try? JSONDecoder().decode(CustomHit.self, from: data) else {
                    cont.resume(returning: nil)
                    return
                }
                cont.resume(returning: ResolvedSource(source: hit.url, headers: [:], kbps: hit.kbps))
            })
        }
    }

    private struct CustomHit: Codable {
        let url: String
        let kbps: Int
        let lossless: Bool?
    }

    /// Starts playback as soon as the first 1 MiB is on disk. Remaining
    /// ranges keep appending; [StreamFileCache] is filled when the last
    /// range lands so a re-tap does not fetch again.
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
                let resolved = try await Self.resolveSource(next, prefs: prefs)
                let stillCurrent = await MainActor.run { [weak self] in
                    guard let self else { return false }
                    return self.playGeneration == generation
                        && self.nextEntry?.id == nextId
                }
                guard stillCurrent else { return }
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
    }

    fileprivate func handleError(_ message: String) {
        lastError = message
    }

    private var nextEntry: QueueEntry? {
        if playingIndex + 1 < queue.count { return queue[playingIndex + 1] }
        if repeatMode == .all, queue.count > 1 { return queue[0] }
        return nil
    }

    private func fetchLyrics(for entry: QueueEntry) {
        lyrics = []
        guard PlatformSettings.shared.getBoolean(key: "synced_lyrics", default: true) else {
            lyricsLoading = false
            return
        }
        lyricsLoading = true
        let durationMs = Swift.Int64((entry.durationSeconds > 0 ? entry.durationSeconds : duration) * 1000)
        LyricsBridge.shared.fetch(
            title: entry.title,
            artist: entry.artist,
            durationMs: durationMs,
            album: entry.albumName,
            videoId: entry.videoId,
            callback: LyricsCallbackAdapter { [weak self] lines in
                Task { @MainActor in
                    guard let self, self.current?.id == entry.id else { return }
                    self.lyrics = lines
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

/// Bridge callback adapter for LyricsBridge.
private final class LyricsCallbackAdapter: LyricsBridgeLyricsCallback {
    private let handler: ([LyricLineDto]) -> Void
    init(_ handler: @escaping ([LyricLineDto]) -> Void) {
        self.handler = handler
    }
    func onResult(lines: [LyricLineDto]) {
        handler(lines)
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
