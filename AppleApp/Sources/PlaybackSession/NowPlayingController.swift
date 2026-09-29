import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif
import MediaPlayer
import BitChordShared
#if os(iOS)
import NowPlaying
import AVFoundation
#endif

/// Lock-screen / media-key / Bluetooth controls (spec §3.2 NowPlayingController).
/// MPNowPlayingInfoCenter + MPRemoteCommandCenter work identically on macOS
/// and iOS for an audio app.
@MainActor
final class NowPlayingController {
    private var metadataKey: String?
    private var artwork: MPMediaItemArtwork?
    /// URL that `artwork` was built from — not the in-flight request.
    private var artworkURL: String?
    private var lastRequestedURL: String?
    private var handlers: [Any] = []
#if os(iOS)
    private var modern: AnyObject?
#endif

    init() {
#if os(iOS)
        NowPlayingActivityController.endLegacyActivities()
        if #available(iOS 27, *) {
            let model = ModernNowPlaying()
            model.delegate = self
            modern = model
            DispatchQueue.main.async {
                UIApplication.shared.beginReceivingRemoteControlEvents()
            }
            // iOS 27+: metadata and commands live EXCLUSIVELY on the
            // MediaSession. Publishing this playback through
            // MPNowPlayingInfoCenter / MPRemoteCommandCenter alongside it is
            // undefined behavior per Apple ("Don't mix the Now Playing
            // framework with ... MPNowPlayingInfoCenter and
            // MPRemoteCommandCenter ... for local playback"), and is what the
            // system answers with `internalFailure`. So: no MP handlers here.
            return
        }
        DispatchQueue.main.async {
            UIApplication.shared.beginReceivingRemoteControlEvents()
        }
#endif
        // MP path: macOS, and iOS versions without the NowPlaying framework.
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.isEnabled = true
        handlers.append(center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.onPlay?() }
            return .success
        })
        center.pauseCommand.isEnabled = true
        handlers.append(center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.onPause?() }
            return .success
        })
        center.togglePlayPauseCommand.isEnabled = true
        handlers.append(center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.onToggle?() }
            return .success
        })
        center.nextTrackCommand.isEnabled = true
        handlers.append(center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.onNext?() }
            return .success
        })
        center.previousTrackCommand.isEnabled = true
        handlers.append(center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.onPrevious?() }
            return .success
        })
        center.changePlaybackPositionCommand.isEnabled = true
        handlers.append(center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let position = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime else {
                return .commandFailed
            }
            Task { @MainActor [weak self] in self?.onSeek?(position) }
            return .success
        })
    }

    var onPlay: (() -> Void)?
    var onPause: (() -> Void)?
    var onToggle: (() -> Void)?
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onSeek: ((Double) -> Void)?

    func update(title: String, artist: String, duration: Double,
                artworkData: Data?, thumbnailUrl: String?, isPlaying: Bool,
                position: Double? = nil) {
        // iOS 27 publishes exclusively through the MediaSession (see init:
        // mixing in MPNowPlayingInfoCenter yields undefined behavior).
#if os(iOS)
        if #available(iOS 27, *), let model = modern as? ModernNowPlaying {
            model.update(title: title, artist: artist, duration: duration,
                         artworkData: artworkData, thumbnailUrl: thumbnailUrl,
                         isPlaying: isPlaying, position: position)
            return
        }
#endif
        let key = "\(title)|\(artist)"
        if metadataKey != key {
            metadataKey = key
            artwork = nil
            artworkURL = nil
            lastRequestedURL = nil
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: artist,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(PlatformSettings.shared.getFloat(key: "playback_speed", default: 1)) : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if let position {
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = position
        } else if let old = MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyElapsedPlaybackTime] {
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = old
        }
        if lastRequestedURL != thumbnailUrl { lastRequestedURL = nil }
        if let item = artworkFromBytes(artworkData) {
            info[MPMediaItemPropertyArtwork] = item
            artworkURL = thumbnailUrl
            lastRequestedURL = thumbnailUrl
        } else if let artwork, artworkURL == thumbnailUrl {
            info[MPMediaItemPropertyArtwork] = artwork
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
#if os(macOS)
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
#endif
        if let thumbnailUrl, !thumbnailUrl.isEmpty, artworkData == nil,
           artworkURL != thumbnailUrl, lastRequestedURL != thumbnailUrl {
            fetchArtwork(
                url: thumbnailUrl, title: title, artist: artist,
                duration: duration, isPlaying: isPlaying
            )
        }
    }

    func updateCommands(canNext: Bool, canPrevious: Bool, canSeek: Bool) {
#if os(iOS)
        if #available(iOS 27, *), let model = modern as? ModernNowPlaying {
            model.canNext = canNext
            model.canPrevious = canPrevious
            model.canSeek = canSeek
            return
        }
#endif
        let commands = MPRemoteCommandCenter.shared()
        commands.nextTrackCommand.isEnabled = canNext
        commands.previousTrackCommand.isEnabled = canPrevious
        commands.changePlaybackPositionCommand.isEnabled = canSeek
    }

    func update(position: Double) {
#if os(iOS)
        if #available(iOS 27, *), let model = modern as? ModernNowPlaying {
            model.position = position
            return
        }
#endif
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = position
        info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    func updateRate(_ rate: Double, position: Double? = nil) {
#if os(iOS)
        if #available(iOS 27, *), let model = modern as? ModernNowPlaying {
            model.rate = rate
            if let position { model.position = position }
            if rate > 0 { model.requestPrimaryIfPossible() }
            return
        }
#endif
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyPlaybackRate] = rate
        if let position {
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = position
        }
        info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
#if os(macOS)
        MPNowPlayingInfoCenter.default().playbackState = rate > 0 ? .playing : .paused
#endif
    }

    func requestPrimaryIfPossible() {
#if os(iOS)
        if #available(iOS 27, *), let model = modern as? ModernNowPlaying {
            model.requestPrimaryIfPossible()
        }
#endif
    }

    /// A foreground music session can regain the system slot after the other
    /// app finishes. Background checks only record the transition; the system
    /// slot request is made from the foreground lifecycle callback.
    func reclaimAfterOtherAudioStops() {
#if os(iOS)
        if #available(iOS 27, *), let model = modern as? ModernNowPlaying {
            model.reclaimAfterOtherAudioStops()
        }
#endif
    }

    func stop() {
#if os(iOS)
        if #available(iOS 27, *), let model = modern as? ModernNowPlaying {
            model.stop()
            return
        }
#endif
        lastRequestedURL = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
#if os(macOS)
        MPNowPlayingInfoCenter.default().playbackState = .stopped
#endif
    }

    private func artworkFromBytes(_ data: Data?) -> MPMediaItemArtwork? {
        guard let data else { return nil }
#if os(iOS)
        guard let image = UIImage(data: data) else { return nil }
        let size = image.size
        let item = MPMediaItemArtwork(boundsSize: size) { _ in image }
        artwork = item
        return item
#else
        guard let image = NSImage(data: data) else { return nil }
        let size = image.size
        let item = MPMediaItemArtwork(boundsSize: size) { requested in
            let canvas = NSImage(size: requested)
            canvas.lockFocus()
            image.draw(in: NSRect(origin: .zero, size: requested))
            canvas.unlockFocus()
            return canvas
        }
        artwork = item
        return item
#endif
    }

    /// Fetch the thumbnail off-main, then publish it. `lastRequestedURL` is
    /// the in-flight cache key so a later track cannot land artwork on this one.
    private func fetchArtwork(
        url: String, title: String, artist: String, duration: Double, isPlaying: Bool
    ) {
        lastRequestedURL = url
        let sized = SharedArtwork.sized(url, 544) ?? url
        Task.detached(priority: .utility) { [weak self] in
            guard let remote = URL(string: sized),
                  let (data, _) = try? await URLSession.shared.data(from: remote),
                  !data.isEmpty else { return }
            await MainActor.run { [weak self] in
                guard let self, self.lastRequestedURL == url else { return }
                guard let item = self.artworkFromBytes(data) else { return }
                self.artworkURL = url
                var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                info[MPMediaItemPropertyArtwork] = item
                info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue
                MPNowPlayingInfoCenter.default().nowPlayingInfo = info
            }
        }
    }
}

#if os(iOS)
/// iOS 27 publishes an explicit media session, including its playback state.
/// Keep it separate from the legacy MediaPlayer path: Apple says not to publish
/// the same local playback through both APIs.
@available(iOS 27, *)
@Observable
@MainActor
private final class ModernNowPlaying: MediaSessionRepresentable {
    let id = "bitchord-player"
    weak var delegate: NowPlayingController?
    var title = ""
    var artist = ""
    var duration: Double = 0
    var position: Double = 0 { didSet { timestamp = Date() } }
    var timestamp = Date()
    var rate: Double = 0 { didSet { timestamp = Date() } }
    var artworkData: Data?
    var artworkURL: String?
    var canNext = false
    var canPrevious = false
    var canSeek = false
    private var session: MediaSession<ModernNowPlaying>?
    private var primaryRequestInFlight = false
    /// `internalFailure` retried every two seconds flooded the log and the
    /// system. One failure holds the next ask off; a success clears it.
    private var nextClaimAt = Date.distantPast
    private var reportedClaimFailure = false
    private var otherAudioWasPlaying = false

    var content: (any MediaContentRepresentable)? {
        guard !title.isEmpty else { return nil }
        let imageData = artworkData
        let imageURL = artworkURL
        let artwork: Artwork? = (imageData != nil || imageURL != nil)
            ? Artwork(id: "\(title)|\(artist)|\(imageURL ?? "embedded")") { _ in
                if let imageData { return try ArtworkRepresentation(data: imageData) }
                guard let imageURL,
                      let url = URL(string: SharedArtwork.sized(imageURL, 544) ?? imageURL)
                else { throw ArtworkRepresentation.ArtworkRepresentationError.noRepresentationAvailable }
                let (data, _) = try await URLSession.shared.data(from: url)
                return try ArtworkRepresentation(data: data)
            }
            : nil
        return MusicContent(
            id: "\(title)|\(artist)", songTitle: title, artistName: artist,
            albumName: "", type: .audio,
            duration: duration > 0 ? .finite(duration) : nil,
            artwork: artwork
        )
    }

    var playbackSnapshot: MediaPlaybackSnapshot? {
        guard !title.isEmpty else { return nil }
        return MediaPlaybackSnapshot(
            state: rate > 0 ? .playing(rate: Float(rate)) : .paused,
            elapsedTime: position, timestamp: timestamp
        )
    }

    var commands: [MediaCommand] {
        [
            .play { [weak self] in self?.delegate?.onPlay?() },
            .pause { [weak self] in self?.delegate?.onPause?() },
            .togglePlayPause { [weak self] in self?.delegate?.onToggle?() },
            .next { [weak self] in self?.delegate?.onNext?() }.enabled(canNext),
            .previous { [weak self] in self?.delegate?.onPrevious?() }.enabled(canPrevious),
            .seekToPosition { [weak self] seconds in self?.delegate?.onSeek?(seconds) }.enabled(canSeek),
        ]
    }

    func update(title: String, artist: String, duration: Double,
                artworkData: Data?, thumbnailUrl: String?, isPlaying: Bool,
                position: Double?) {
        if self.title != title || self.artist != artist {
            self.position = position ?? 0
            // A new track gets a fresh claim attempt: a backoff set by the
            // previous track's failure must not mute this one.
            nextClaimAt = .distantPast
            reportedClaimFailure = false
        } else if let position {
            self.position = position
        }
        self.title = title
        self.artist = artist
        self.duration = duration
        self.artworkData = artworkData
        self.artworkURL = thumbnailUrl
        self.rate = isPlaying
            ? Double(PlatformSettings.shared.getFloat(key: "playback_speed", default: 1)) : 0
        // The session is created on the claim path below, not here: creating
        // it for a paused/restored track would register a same-id session
        // with the system before anything is playing.
        if isPlaying { claimNowPlaying(reason: "playback") }
    }

    func requestPrimaryIfPossible() {
        nextClaimAt = .distantPast
        reportedClaimFailure = false
        claimNowPlaying(reason: "foreground")
    }

    func stop() {
        rate = 0
        title = ""
        session = nil
        nextClaimAt = .distantPast
    }

    func reclaimAfterOtherAudioStops() {
        let other = AVAudioSession.sharedInstance().isOtherAudioPlaying
        if otherAudioWasPlaying && !other { nextClaimAt = .distantPast }
        otherAudioWasPlaying = other
        // Keep publishing in the background. Only the explicit system takeover
        // below requires foreground; iOS arbitrates background prominence.
        guard rate > 0 else { return }
        claimNowPlaying(reason: "eligibility changed")
    }

    /// Publish the session and, when appropriate, ask for the system slot.
    ///
    /// Two separate steps with separate rules (Apple docs):
    /// - `requestToBecomeApplicationPrimary` is what publishes local playback
    ///   — lock screen, island, Control Center. It is attempted whenever there
    ///   is something to publish, after the audio session is active (callers
    ///   only invoke this while loaded/playing).
    /// - `requestToBecomeSystemPrimary` is ONLY for taking over the prominent
    ///   slot from another session (our exact "shows Apple Music instead"
    ///   symptom), requires the foreground, and errors when there is nothing
    ///   to take over. Calling it for plain local playback, from the
    ///   background, or alongside MPNowPlayingInfoCenter publishing is what
    ///   the system answers with `internalFailure` / no effect.
    private func claimNowPlaying(reason: String) {
        guard !title.isEmpty else { return }
        if session == nil { session = MediaSession(self) }
        guard let session, !primaryRequestInFlight, Date() >= nextClaimAt else { return }
        guard !session.isApplicationPrimary || !session.isSystemPrimary else { return }
        primaryRequestInFlight = true
        Task { @MainActor in
            defer { primaryRequestInFlight = false }
            if !session.isApplicationPrimary {
                do {
                    try await session.requestToBecomeApplicationPrimary()
                } catch {
                    self.noteClaimFailure("app-session", reason: reason, error: error)
                    return
                }
            }
            // Takeover only: playing, foregrounded, and not already prominent.
            // Apple: "Your app must be in the foreground when calling this
            // method, otherwise this request doesn't take effect."
            guard self.session === session, self.rate > 0,
                  UIApplication.shared.applicationState == .active,
                  !session.isSystemPrimary else { return }
            do {
                try await session.requestToBecomeSystemPrimary()
                self.reportedClaimFailure = false
                self.nextClaimAt = .distantPast
                NSLog("[BitChord] Now Playing is the system session (\(reason))")
            } catch {
                self.noteClaimFailure("system", reason: reason, error: error)
            }
        }
    }

    private func noteClaimFailure(_ step: String, reason: String, error: Error) {
        nextClaimAt = Date().addingTimeInterval(30)
        guard !reportedClaimFailure else { return }
        reportedClaimFailure = true
        NSLog("[BitChord] Now Playing \(step) request failed (\(reason)): \(error)")
    }
}
#endif

/// Publishes the widget snapshot into the App Group container
/// (spec §3.2 WidgetStatePublisher / §9): ready-to-play semantics, no
/// position, last-played fallback handled widget-side. Artwork crosses as a
/// file (the spec's "size-capped artwork file"), and the whole publish runs
/// off the main thread — preference writes to a group container can stall on
/// container resolution and must never block the UI.
@MainActor
final class WidgetStatePublisher {
    func publish(entry: QueueEntry?, isPlaying: Bool, canNext: Bool, canPrevious: Bool) {
        guard let entry else { return }
        let group = "group.com.example.bitchord"
        // Unprovisioned App Groups hang cfprefsd on write — skip when the
        // container is missing rather than compiling DEBUG out entirely.
        guard FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: group
        ) != nil else { return }
        let title = entry.title
        let artist = entry.artist
        let artwork = entry.artworkData
        let artworkURL = Self.artworkFileURL()
        DispatchQueue.global(qos: .utility).async {
            guard let defaults = UserDefaults(suiteName: group) else { return }
            defaults.set(title, forKey: "widget.title")
            defaults.set(artist, forKey: "widget.artist")
            defaults.set(isPlaying, forKey: "widget.playing")
            defaults.set(canNext, forKey: "widget.canNext")
            defaults.set(canPrevious, forKey: "widget.canPrevious")
            if let artwork {
                if let url = artworkURL {
                    try? artwork.write(to: url, options: .atomic)
                    defaults.set(url.path, forKey: "widget.artworkPath")
                }
            } else {
                defaults.removeObject(forKey: "widget.artworkPath")
            }
        }
    }

    nonisolated private static func artworkFileURL() -> URL? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.example.bitchord"
        ) else { return nil }
        return container.appendingPathComponent("widget-artwork.jpg")
    }
}
