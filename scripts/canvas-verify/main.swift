import AVFoundation
import Foundation
import BitChordShared

// The canvas cache's logging dependency; errors are printed with host/status only.
final class PlaybackDebugLog: @unchecked Sendable {
    static let shared = PlaybackDebugLog()
    func record(_ value: String) { print(value) }
}

private final class CanvasResult: CanvasBridgeCanvasCallback {
    let callback: (String?) -> Void
    init(_ callback: @escaping (String?) -> Void) { self.callback = callback }
    func onResult(json: String?) { callback(json) }
}

@main struct CanvasVerification {
    @MainActor static func main() async throws {
        var failures: [String] = []
        func check(_ condition: Bool, _ name: String) {
            print("\(condition ? "PASS" : "FAIL"): \(name)")
            if !condition { failures.append(name) }
        }
        var clips: [URL] = []
        for (title, artist, album) in [
            ("Starboy", "The Weeknd, Daft Punk", "Starboy"),
            ("Starboy (feat. Daft Punk)", "The Weeknd", "Starboy"),
            ("Blinding Lights", "The Weeknd", "After Hours"),
        ] {
            let json: String? = await withCheckedContinuation { continuation in
                CanvasBridge.shared.lookup(title: title, artist: artist, album: album,
                    callback: CanvasResult { continuation.resume(returning: $0) })
            }
            let payload = json.flatMap { $0.data(using: .utf8) }
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let url = (payload?["url"] as? String).flatMap(URL.init(string:))
            check(url != nil, "live lookup: \(title) / \(artist)")
            if let url {
                print("  provider=\(payload?["source"] ?? "unknown") host=\(url.host ?? "local")")
                clips.append(url)
            }
        }
        guard let starboy = clips.first else { exit(1) }
        check(CanvasMediaRequest.download(starboy).value(forHTTPHeaderField: "User-Agent") == CanvasMediaRequest.userAgent
            && !CanvasMediaRequest.download(starboy).httpShouldHandleCookies, "public media request uses browser identity without account cookies")
        // The community host ignores Range. Confirm this limitation so cache
        // recovery cannot depend on streaming the same MP4 directly.
        let remote = CanvasMediaRequest.asset(starboy)
        do {
            let remoteTracks = try await remote.loadTracks(withMediaType: .video)
            check(!remoteTracks.isEmpty, "Starboy remote server supports video range requests")
        } catch {
            let underlying = (error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError
            check(underlying?.code == -12939, "Starboy host requires a complete cached movie because it ignores ranges")
        }
        async let first = CanvasFileCache.shared.cachedFile(for: starboy)
        async let duplicate = CanvasFileCache.shared.cachedFile(for: starboy)
        let (local, second) = await (first, duplicate)
        check(local.isFileURL && local == second, "duplicate clip requests share a playable disk file")
        let asset = CanvasMediaRequest.asset(local)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let playable = try await asset.load(.isPlayable)
        check(!tracks.isEmpty && playable, "cached Starboy movie decodes as video")
        let player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        player.isMuted = true
        player.volume = 0
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        player.currentItem!.add(output)
        player.play()
        var rendered = false
        for _ in 0..<50 {
            try await Task.sleep(for: .milliseconds(100))
            if output.copyPixelBuffer(forItemTime: player.currentTime(), itemTimeForDisplay: nil) != nil {
                rendered = true
                break
            }
        }
        player.pause()
        player.replaceCurrentItem(with: nil)
        check(rendered, "muted native player produces an actual Starboy video frame")
        for clip in clips where ["m3u", "m3u8"].contains(clip.pathExtension.lowercased()) {
            let cached = await CanvasFileCache.shared.cachedFile(for: clip)
            check(cached == clip && !cached.isFileURL, "HLS remains a network playlist")
            // HLS tracks are populated as the player reads media segments;
            // loading the master playlist alone can report an empty track list.
            let item = AVPlayerItem(asset: CanvasMediaRequest.asset(clip))
            let hlsPlayer = AVPlayer(playerItem: item)
            hlsPlayer.isMuted = true
            hlsPlayer.volume = 0
            let frames = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            item.add(frames)
            hlsPlayer.play()
            var hlsFrame = false
            for _ in 0..<100 {
                try await Task.sleep(for: .milliseconds(100))
                if frames.copyPixelBuffer(forItemTime: hlsPlayer.currentTime(), itemTimeForDisplay: nil) != nil {
                    hlsFrame = true
                    break
                }
                if item.status == .failed { break }
            }
            if let error = item.error { print("  HLS player error: \(error.localizedDescription)") }
            hlsPlayer.pause()
            hlsPlayer.replaceCurrentItem(with: nil)
            check(hlsFrame, "Apple motion HLS produces an actual video frame through the same media policy")
        }
        await CanvasFileCache.shared.invalidate(starboy)
        check(!FileManager.default.fileExists(atPath: local.path), "failed cached clips can be invalidated for a fresh download")
        print("Canvas verification: \(failures.isEmpty ? "passed" : "failed")")
        if !failures.isEmpty { exit(1) }
    }
}
