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
        if #available(iOS 27, *) {
            let model = ModernNowPlaying()
            model.delegate = self
            modern = model
            return
        }
        DispatchQueue.main.async {
            UIApplication.shared.beginReceivingRemoteControlEvents()
        }
#endif
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.isEnabled = true
        handlers.append(center.playCommand.addTarget { [weak self] _ in
            self?.onPlay?()
            return .success
        })
        center.pauseCommand.isEnabled = true
        handlers.append(center.pauseCommand.addTarget { [weak self] _ in
            self?.onPause?()
            return .success
        })
        center.togglePlayPauseCommand.isEnabled = true
        handlers.append(center.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.onToggle?()
            return .success
        })
        center.nextTrackCommand.isEnabled = true
        handlers.append(center.nextTrackCommand.addTarget { [weak self] _ in
            self?.onNext?()
            return .success
        })
        center.previousTrackCommand.isEnabled = true
        handlers.append(center.previousTrackCommand.addTarget { [weak self] _ in
            self?.onPrevious?()
            return .success
        })
        center.changePlaybackPositionCommand.isEnabled = true
        handlers.append(center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let position = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime else {
                return .commandFailed
            }
            self?.onSeek?(position)
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
#if os(iOS)
        if #available(iOS 27, *), let model = modern as? ModernNowPlaying {
            model.update(title: title, artist: artist, duration: duration,
                         artworkData: artworkData, thumbnailUrl: thumbnailUrl,
                         isPlaying: isPlaying, position: position)
            return
        }
#endif
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
        if let item = artworkFromBytes(artworkData) {
            info[MPMediaItemPropertyArtwork] = item
            artworkURL = thumbnailUrl
            lastRequestedURL = thumbnailUrl
        } else if let artwork, artworkURL == thumbnailUrl {
            info[MPMediaItemPropertyArtwork] = artwork
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        if let thumbnailUrl, !thumbnailUrl.isEmpty, artworkData == nil,
           artworkURL != thumbnailUrl, lastRequestedURL != thumbnailUrl {
            fetchArtwork(
                url: thumbnailUrl, title: title, artist: artist,
                duration: duration, isPlaying: isPlaying
            )
        }
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
    }

    // NOTE: `MPNowPlayingInfoCenter.playbackState` is *not* used here, and
    // cannot be. It requires the restricted entitlement
    // `com.apple.mediaremote.set-playback-state`, which Apple grants by
    // exception; without it every assignment is ignored and logged as
    // "[MRNowPlaying] Ignoring setPlaybackState because application does not
    // contain entitlement ...". It was tried, and the device log is the proof.
    //
    // iOS 27 uses NowPlaying.MediaSession above. On iOS 18–26 the system
    // chooses which mixing app owns its single prominent control surface.

    func requestPrimaryIfPossible() {
#if os(iOS)
        if #available(iOS 27, *), let model = modern as? ModernNowPlaying {
            model.requestPrimaryIfPossible()
        }
#endif
    }

    /// A foreground music session can regain the system slot after the other
    /// app finishes. The system does not deliver this event to background apps,
    /// so playback's existing timer checks while BitChord is visible.
    func reclaimAfterOtherAudioStops() {
#if os(iOS)
        if #available(iOS 27, *), let model = modern as? ModernNowPlaying {
            model.reclaimAfterOtherAudioStops()
        }
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
                info[MPMediaItemPropertyTitle] = title
                info[MPMediaItemPropertyArtist] = artist
                info[MPMediaItemPropertyPlaybackDuration] = duration
                info[MPMediaItemPropertyArtwork] = item
                info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue
                info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying
                    ? Double(PlatformSettings.shared.getFloat(key: "playback_speed", default: 1))
                    : 0.0
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
    var position: Double = 0
    var rate: Double = 0
    var artworkData: Data?
    var artworkURL: String?
    private var session: MediaSession<ModernNowPlaying>?
    private var primaryRequestInFlight = false

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
            elapsedTime: position
        )
    }

    var commands: [MediaCommand] {
        [
            .play { [weak self] in self?.delegate?.onPlay?() },
            .pause { [weak self] in self?.delegate?.onPause?() },
            .togglePlayPause { [weak self] in self?.delegate?.onToggle?() },
            .next { [weak self] in self?.delegate?.onNext?() },
            .previous { [weak self] in self?.delegate?.onPrevious?() },
            .seekToPosition { [weak self] seconds in self?.delegate?.onSeek?(seconds) },
        ]
    }

    func update(title: String, artist: String, duration: Double,
                artworkData: Data?, thumbnailUrl: String?, isPlaying: Bool,
                position: Double?) {
        if self.title != title || self.artist != artist {
            self.position = position ?? 0
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
        if isPlaying { requestPrimaryIfPossible() }
    }

    func requestPrimaryIfPossible() {
        guard UIApplication.shared.applicationState == .active,
              !primaryRequestInFlight else { return }
        if session == nil { session = MediaSession(self) }
        guard let session else { return }
        guard !session.isSystemPrimary else { return }
        primaryRequestInFlight = true
        Task { @MainActor in
            defer { primaryRequestInFlight = false }
            do {
                try await session.requestToBecomeSystemPrimary()
            } catch {
                NSLog("[BitChord] Now Playing primary request failed: \(error)")
            }
        }
    }

    func reclaimAfterOtherAudioStops() {
        guard rate > 0,
              session?.isSystemPrimary != true,
              !AVAudioSession.sharedInstance().isOtherAudioPlaying else { return }
        requestPrimaryIfPossible()
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
