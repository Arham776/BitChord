import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif
import MediaPlayer
import BitChordShared

/// Lock-screen / media-key / Bluetooth controls (spec §3.2 NowPlayingController).
/// MPNowPlayingInfoCenter + MPRemoteCommandCenter work identically on macOS
/// and iOS for an audio app.
@MainActor
final class NowPlayingController {
    private var artwork: MPMediaItemArtwork?
    private var lastURL: String?
    private var handlers: [Any] = []

    init() {
        let center = MPRemoteCommandCenter.shared()
        handlers.append(center.playCommand.addTarget { [weak self] _ in
            self?.onPlay?()
            return .success
        })
        handlers.append(center.pauseCommand.addTarget { [weak self] _ in
            self?.onPause?()
            return .success
        })
        handlers.append(center.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.onToggle?()
            return .success
        })
        handlers.append(center.nextTrackCommand.addTarget { [weak self] _ in
            self?.onNext?()
            return .success
        })
        handlers.append(center.previousTrackCommand.addTarget { [weak self] _ in
            self?.onPrevious?()
            return .success
        })
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let position = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime else {
                return .commandFailed
            }
            self?.onSeek?(position)
            return .success
        }
    }

    var onPlay: (() -> Void)?
    var onPause: (() -> Void)?
    var onToggle: (() -> Void)?
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onSeek: ((Double) -> Void)?

    func update(title: String, artist: String, duration: Double,
                artworkData: Data?, thumbnailUrl: String?, isPlaying: Bool) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: artist,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(PlatformSettings.shared.getFloat(key: "playback_speed", default: 1)) : 0.0,
        ]
        if let artwork = resolvedArtwork(data: artworkData, url: thumbnailUrl) {
            info[MPMediaItemPropertyArtwork] = artwork
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    func update(position: Double) {
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = position
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    func updateRate(_ rate: Double) {
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyPlaybackRate] = rate
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func resolvedArtwork(data: Data?, url: String?) -> MPMediaItemArtwork? {
        // Never fetch remote URLs here — `Data(contentsOf:)` on the main thread
        // triggers the sync-loading warning. Embedded bytes or a prior cache hit
        // only; ArtworkView loads thumbnails asynchronously for the UI.
#if os(iOS)
        guard let data, let image = UIImage(data: data) else { return artwork }
        let size = image.size
        lastURL = url
        let item = MPMediaItemArtwork(boundsSize: size) { _ in image }
        artwork = item
        return item
#else
        guard let data, let image = NSImage(data: data) else { return artwork }
        let size = image.size
        lastURL = url
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
}

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
        #if DEBUG
        // Dev builds carry no provisioning for the App Group, and cfprefsd
        // hangs indefinitely on writes to an unprovisioned suite — skip
        // publishing entirely (the widget renders its placeholder).
        return
        #else
        let title = entry.title
        let artist = entry.artist
        let artwork = entry.artworkData
        let artworkURL = Self.artworkFileURL()
        DispatchQueue.global(qos: .utility).async {
            guard let defaults = UserDefaults(suiteName: "group.com.example.bitchord") else {
                return
            }
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
        #endif
    }

    nonisolated private static func artworkFileURL() -> URL? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.example.bitchord"
        ) else { return nil }
        return container.appendingPathComponent("widget-artwork.jpg")
    }
}
