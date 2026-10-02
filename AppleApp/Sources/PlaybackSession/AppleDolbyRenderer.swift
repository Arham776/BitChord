import Foundation
import AVFoundation
import AudioToolbox

/// Preserve E-AC-3/JOC for Apple's system renderer instead of downmixing it in Rust.
/// No account headers are handed to AVFoundation's automatic redirect handling.
@MainActor
final class AppleDolbyRenderer {
    static var available: Bool { AVURLAsset.isPlayableExtendedMIMEType("audio/mp4; codecs=\"ec-3\"") }
    private var preparation: UInt64 = 0
    private(set) var player: AVPlayer?
    private var endObserver: NSObjectProtocol?
    private var failureObserver: NSObjectProtocol?
    private var observation: NSKeyValueObservation?
    private(set) var info: TrackInfoRec?
    var onEnd: (() -> Void)?
    var onFailure: (() -> Void)?
    var volume: Float = 1 { didSet { player?.volume = volume } }
    var rate: Float = 1
    var position: Double { player.map { max(0, CMTimeGetSeconds($0.currentTime())) } ?? 0 }
    var duration: Double { info?.durationSeconds ?? 0 }
    var progressing: Bool { player?.timeControlStatus == .playing }

    enum Failure: LocalizedError {
        case unavailable, credentials, format
        var errorDescription: String? {
            switch self {
            case .unavailable: "Apple's Dolby playback renderer is unavailable for this source."
            case .credentials: "This Dolby source requires an authenticated transport."
            case .format: "The source did not contain playable Dolby audio."
            }
        }
    }

    func prepare(source: String, title: String, artist: String, codec: String?, headers: [String: String], startAt: Double, claimedKbps: UInt32) async throws -> TrackInfoRec {
        stop()
        let revision = preparation
        guard headers.isEmpty else { throw Failure.credentials }
        let url = source.hasPrefix("http") ? URL(string: source) : URL(fileURLWithPath: source)
        guard let url, url.user == nil, url.password == nil,
              url.isFileURL || url.scheme == "https" else { throw Failure.unavailable }
        let asset = AVURLAsset(url: url)
        guard try await asset.load(.isPlayable) else { throw Failure.unavailable }
        guard preparation == revision else { throw CancellationError() }
        let item = AVPlayerItem(asset: asset)
        let instance = AVPlayer(playerItem: item)
        instance.volume = volume
        instance.automaticallyWaitsToMinimizeStalling = true
        player = instance
        if let group = try await asset.loadMediaSelectionGroup(for: .audible),
           let option = group.options.first(where: { option in
               option.mediaSubTypes.contains { $0.uint32Value == kAudioFormatEnhancedAC3 }
           }) {
            item.select(option, in: group)
        }
        for _ in 0..<150 {
            try Task.checkCancellation()
            guard preparation == revision else { throw CancellationError() }
            if item.status != .unknown { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard preparation == revision else { throw CancellationError() }
        guard item.status == .readyToPlay, player === instance else { throw Failure.unavailable }
        var tracks = try await asset.loadTracks(withMediaType: .audio)
        if tracks.isEmpty {
            instance.volume = 0
            instance.play()
            for _ in 0..<100 {
                try Task.checkCancellation()
            guard preparation == revision else { throw CancellationError() }
                tracks = item.tracks.compactMap { $0.assetTrack }.filter { $0.mediaType == .audio }
                if !tracks.isEmpty { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            instance.pause()
            await instance.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
            instance.volume = volume
        }
        NSLog("[BitChord] Apple audio asset track count=%d", tracks.count)
        var format: AudioStreamBasicDescription?
        var bitrate = claimedKbps
        for track in tracks {
            let descriptions = try await track.load(.formatDescriptions)
            for description in descriptions {
                if let value = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee {
                    NSLog("[BitChord] Apple audio asset format id=%u channels=%u rate=%.0f", value.mFormatID, value.mChannelsPerFrame, value.mSampleRate)
                }
                if let value = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
                   value.mFormatID == kAudioFormatEnhancedAC3 || value.mFormatID == kAudioFormatAC3 {
                    format = value
                    bitrate = UInt32(max(0, try await track.load(.estimatedDataRate)) / 1000)
                    break
                }
            }
            if format != nil { break }
        }
        guard preparation == revision else { throw CancellationError() }
        guard let format else { throw Failure.format }
        let seconds = CMTimeGetSeconds(item.duration)
        let isDeclaredAtmos = ["eac3-joc", "ec3-joc", "dolby-atmos"].contains(codec?.lowercased() ?? "")
        let result = TrackInfoRec(title: title, artist: artist, source: source,
            durationSeconds: seconds.isFinite ? max(0, seconds) : 0,
            codec: isDeclaredAtmos && format.mFormatID == kAudioFormatEnhancedAC3 ? "EAC3-JOC" : (format.mFormatID == kAudioFormatEnhancedAC3 ? "EAC3" : "AC3"),
            sampleRate: UInt32(format.mSampleRate), bitDepth: 0, channels: format.mChannelsPerFrame, kbps: bitrate)
        info = result
        if startAt > 0 { await instance.seek(to: CMTime(seconds: startAt, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self, weak instance] _ in
            Task { @MainActor in guard self?.player === instance else { return }; self?.onEnd?() }
        }
        failureObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self, weak instance] _ in
            Task { @MainActor in guard self?.player === instance else { return }; self?.onFailure?() }
        }
        observation = item.observe(\.status, options: [.new]) { [weak self, weak instance] item, _ in
            guard item.status == .failed else { return }
            Task { @MainActor in guard self?.player === instance else { return }; self?.onFailure?() }
        }
        return result
    }
    func play() { player?.playImmediately(atRate: rate) }
    func pause() { player?.pause() }
    func seek(_ seconds: Double) { player?.seek(to: CMTime(seconds: max(0, seconds), preferredTimescale: 600)) }
    func stop() {
        preparation &+= 1
        player?.pause(); player?.replaceCurrentItem(with: nil); player = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
        endObserver = nil; failureObserver = nil; observation = nil; info = nil
    }
    var nerd: NerdStatsRec? {
        guard let info else { return nil }
        return NerdStatsRec(codec: info.codec, sampleRate: info.sampleRate, bitDepth: 0,
            channels: info.channels, kbps: info.kbps, loudnessGainDb: nil, swapCorrelation: nil,
            activeStages: ["Apple system rendering"], converterDelayFrames: 0,
            protectionReductionDb: 0, protectionInterventions: 0, buildRevision: "AVFoundation",
            decoderImplementation: "Apple AVFoundation", decodedLayout: "\(info.channels) channels",
            queuedTargetMs: 0, loudnessOrigin: "System controlled")
    }
}
