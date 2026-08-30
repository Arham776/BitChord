import Foundation
import BitChordShared

/// One playable entry in the queue. Wraps either a local file path or a
/// resolved stream URL; metadata mirrors upstream's `Song` row.
struct QueueEntry: Identifiable, Hashable {
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

    private var unshuffledQueue: [QueueEntry]?

    private var positionTimer: Timer?
    private var started = false
    /// Incremented on every user-initiated load so in-flight resolves/downloads
    /// from a previous tap cannot `loadTrack`/`queueNext` into the new song.
    private var playGeneration: UInt64 = 0
    private let nowPlaying = NowPlayingController()
    private let widgetPublisher = WidgetStatePublisher()

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
    }

    func startEngineIfNeeded() {
        guard !started else { return }
        started = true
        // Engine start touches HAL / cpal which blocks (~1s) and triggers
        // Thread Performance Checker if done on main. Run on utility QoS
        // so it doesn't outrank the Default QoS cpal monitor thread
        // (upstream runs PlaybackService on its own thread).
        let eng = engine
        Task.detached(priority: .utility) {
            do {
                try eng.start()
                try eng.setCrossfadeWindow(seconds: Double(AppSettings.shared.crossfadeSeconds.value as? KotlinInt != nil ? Int(truncating: AppSettings.shared.crossfadeSeconds.value as! KotlinInt) : 0))
                try eng.setSpatialEnabled(enabled: PlatformSettings.shared.getBoolean(key: "spatial_audio", default: false))
            } catch {
                await MainActor.run { self.lastError = "Audio engine failed to start: \(error)" }
            }
        }
        positionTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.state == .playing else { return }
                self.position = self.engine.positionSeconds()
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
        queue = entries
        unshuffledQueue = nil
        shuffleEnabled = false
        startEngineIfNeeded()
        loadCurrent(index)
    }

    func playNext(_ entry: QueueEntry) {
        let at = min(playingIndex + 1, queue.count)
        queue.insert(entry, at: at)
        syncEngineQueueNext()
    }

    func addToQueue(_ entry: QueueEntry) {
        queue.append(entry)
        // No engine change needed: pending next is refreshed by sync.
        syncEngineQueueNext()
    }

    func togglePlayPause() {
        startEngineIfNeeded()
        if state == .buffering { return }
        if current == nil {
            if !queue.isEmpty { loadCurrent(min(playingIndex, queue.count - 1)) }
            return
        }
        if isPlaying {
            // Flip the control immediately — the engine also silences the
            // device callback before the mixer thread runs Pause.
            state = .paused
            try? engine.pause()
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
        if position > 3 {
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
        syncEngineQueueNext()
    }

    func seek(to seconds: Double) {
        try? engine.seek(seconds: seconds)
        position = seconds
    }

    func removeFromQueue(at offsets: IndexSet) {
        // Only entries after the playing track are removable in v1.
        let adjusted = offsets.filter { $0 > playingIndex }
        guard !adjusted.isEmpty else { return }
        queue.remove(atOffsets: IndexSet(adjusted))
        syncEngineQueueNext()
    }

    func updateCrossfade(seconds: Int) {
        try? engine.setCrossfadeWindow(seconds: Double(seconds))
    }

    func updateSpatial(enabled: Bool) {
        try? engine.setSpatialEnabled(enabled: enabled)
    }

    // ---- Engine bridge ------------------------------------------------------

    private func loadCurrent(_ index: Int) {
        guard queue.indices.contains(index) else { return }
        let entry = queue[index]
        if current?.id == entry.id, playingIndex == index,
           state == .buffering || state == .playing {
            return
        }
        playGeneration += 1
        let generation = playGeneration
        let wasAudible = state == .playing || state == .paused
        playingIndex = index
        current = entry
        position = 0
        duration = 0
        lastError = nil
        state = .buffering
        nowPlaying.update(
            title: entry.title, artist: entry.artist,
            duration: 0, artworkData: entry.artworkData,
            thumbnailUrl: entry.thumbnailUrl, isPlaying: false
        )
        widgetPublisher.publish(entry: entry, isPlaying: false,
                                canNext: index + 1 < queue.count,
                                canPrevious: index > 0)
        if wasAudible {
            try? engine.stop()
        }
        let engine = self.engine
        Task.detached(priority: .utility) {
            do {
                let (source, headers) = try await Self.resolveSource(entry)
                let stillCurrent = await MainActor.run { [weak self] in
                    self?.playGeneration == generation
                }
                guard stillCurrent else { return }
                let info = try engine.loadTrack(request: LoadRequest(
                    source: source,
                    title: entry.title,
                    artist: entry.artist,
                    startSeconds: 0.0,
                    plan: nil,
                    headers: headers
                ))
                await MainActor.run { [weak self] in
                    guard let self, self.playGeneration == generation else { return }
                    self.loadDidSucceed(entry: entry, index: index, info: info)
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
    private static func resolveSource(_ entry: QueueEntry) async throws -> (String, [String: String]) {
        guard entry.source.hasPrefix("yt:") else {
            return (entry.source, [:])
        }
        let videoId = String(entry.source.dropFirst(3))
        if let cached = await StreamFileCache.shared.path(for: videoId) {
            return (cached, [:])
        }
        var lastError: Error?
        for attempt in 0..<2 {
            let stream = try await InnertubeStreamResolver.shared.resolve(videoId: videoId)
            do {
                let localPath = try await streamViaKtor(
                    videoId: videoId, url: stream.url, headers: stream.headers)
                return (localPath, [:])
            } catch {
                lastError = error
                let is403 = "\(error)".contains("403")
                print("[Playback] Ktor stream failed for \(videoId) attempt \(attempt+1): \(error)")
                if is403 && attempt == 0 {
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    continue
                }
                print("[Playback] falling back to direct stream for \(videoId)")
                return (stream.url, stream.headers)
            }
        }
        throw lastError!
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

    private func loadDidSucceed(entry: QueueEntry, index: Int, info: TrackInfoRec) {
        playingIndex = index
        current = entry
        position = 0
        duration = info.durationSeconds
        lastError = nil
        state = .playing
        refreshArtwork(entry)
        fetchLyrics(for: entry)
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
                source: "", title: "", artist: "", startSeconds: 0, plan: nil, headers: [:]
            ))
            return
        }
        guard playingIndex + 1 < queue.count || (repeatMode == .all && queue.count > 1),
              let next = nextEntry else {
            return
        }
        let generation = playGeneration
        let nextId = next.id
        let engine = self.engine
        Task.detached(priority: .utility) {
            do {
                let (source, headers) = try await Self.resolveSource(next)
                let stillCurrent = await MainActor.run { [weak self] in
                    guard let self else { return false }
                    return self.playGeneration == generation
                        && self.nextEntry?.id == nextId
                }
                guard stillCurrent else { return }
                try engine.queueNext(request: LoadRequest(
                    source: source,
                    title: next.title,
                    artist: next.artist,
                    startSeconds: 0.0,
                    plan: nil,
                    headers: headers
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
        current = queue[playingIndex]
        duration = info.durationSeconds
        position = 0
        if let entry = current {
            refreshArtwork(entry)
            fetchLyrics(for: entry)
            nowPlaying.update(
                title: entry.title, artist: entry.artist,
                duration: info.durationSeconds, artworkData: entry.artworkData,
                thumbnailUrl: entry.thumbnailUrl, isPlaying: true
            )
        }
        syncEngineQueueNext()
    }

    fileprivate func handleTrackEnded(_ reason: TrackEndReason) {
        guard reason == .natural else { return }
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
        lyricsLoading = true
        let durationMs = Int64((entry.durationSeconds > 0 ? entry.durationSeconds : duration) * 1000)
        LyricsBridge.shared.fetch(
            title: entry.title,
            artist: entry.artist,
            durationMs: durationMs,
            callback: LyricsCallbackAdapter { [weak self] lines in
                Task { @MainActor in
                    guard let self, self.current?.id == entry.id else { return }
                    self.lyrics = lines
                    self.lyricsLoading = false
                }
            }
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

/// Reuses a completed googlevideo download so a second tap of the same
/// videoId does not wait on another 2–5 MB fetch.
actor StreamFileCache {
    static let shared = StreamFileCache()
    private var paths: [String: String] = [:]

    func path(for videoId: String) -> String? {
        guard let path = paths[videoId],
              FileManager.default.fileExists(atPath: path),
              FileManager.default.fileExists(atPath: path + ".complete") else { return nil }
        return path
    }

    func store(_ videoId: String, path: String) {
        paths[videoId] = path
    }
}
