import AVFoundation
import NowPlaying
import Observation
import SwiftUI

/// A real, audible local player with no BitChord engine, shared library, queue,
/// artwork downloader, MediaPlayer publisher, or remote media extension.
@main
struct ProbeApp: App {
    @State private var model = ProbePlayer()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            VStack(spacing: 20) {
                Text("Now Playing API reproduction").font(.title2)
                Text(model.exclusive ? "A quiet tone uses exclusive playback." : "A quiet tone uses playback + mixWithOthers.")
                Button(model.playing ? "Pause" : "Play mixed tone") {
                    Task {
                        if model.playing { model.pause() }
                        else { await model.play() }
                    }
                }.buttonStyle(.borderedProminent)
                Button("Stop") { model.stop() }
                Text(model.status).font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                Spacer()
            }.padding()
                .task {
                    if ProcessInfo.processInfo.arguments.contains("--play-mixed-tone")
                        || ProcessInfo.processInfo.arguments.contains("--state-sync") {
                        await model.play()
                        if ProcessInfo.processInfo.arguments.contains("--state-sync") {
                            try? await Task.sleep(for: .seconds(4))
                            model.pause()
                        }
                    }
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        Task { await model.requestProminence() }
                    }
                }
        }
    }
}

@Observable @MainActor
final class ProbePlayer: MediaSessionRepresentable {
    let id = "mixing-reproduction-\(UUID().uuidString)"
    var playing = false
    var elapsed: Double = 0
    var timestamp = Date()
    var status = "Not started"
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var session: MediaSession<ProbePlayer>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var promoting = false
    private let usesGenericContent = ProcessInfo.processInfo.arguments.contains("--generic-content")
    let exclusive = ProcessInfo.processInfo.arguments.contains("--exclusive")

    var content: (any MediaContentRepresentable)? {
        guard player != nil else { return nil }
        if usesGenericContent {
            return GenericContent(id: "test-tone-220", title: "Mixing test tone",
                                  subtitle: "NowPlaying API reproduction", type: .audio,
                                  duration: .finite(8), artwork: nil)
        }
        return MusicContent(id: "test-tone-220", songTitle: "Mixing test tone",
                            artistName: "NowPlaying API reproduction", albumName: "",
                            type: .audio, duration: .finite(8), artwork: nil)
    }

    var playbackSnapshot: MediaPlaybackSnapshot? {
        guard player != nil else { return nil }
        return MediaPlaybackSnapshot(state: playing ? .playing() : .paused,
                                     elapsedTime: elapsed, timestamp: timestamp)
    }

    var commands: [MediaCommand] { [
        .play { self.record("native play before=\(self.playing)"); await self.play() },
        .pause { self.record("native pause before=\(self.playing)"); self.pause() },
        .seekToPosition { seconds in
            self.player?.currentTime = min(max(seconds, 0), 8)
            self.elapsed = self.player?.currentTime ?? 0
            self.timestamp = Date()
            self.record("native seek \(seconds)")
        },
    ] }

    func play() async {
        generation += 1
        let intent = generation
        do {
            let options: AVAudioSession.CategoryOptions = exclusive ? [] : [.mixWithOthers]
            try await Task.detached {
                let audio = AVAudioSession.sharedInstance()
                try audio.setCategory(.playback, mode: .default, options: options)
                try audio.setActive(true)
                NSLog("[NowPlayingProbe] activation category=%@ options=%lu otherAudio=%d",
                      audio.category.rawValue, audio.categoryOptions.rawValue, audio.isOtherAudioPlaying)
            }.value
            guard intent == generation else { return }
            if player == nil {
                player = try AVAudioPlayer(data: Self.tone())
                player?.numberOfLoops = -1
                player?.volume = 0.15
                player?.prepareToPlay()
            }
            if session == nil { session = MediaSession(self) }
            guard let session, player?.play() == true else {
                throw NSError(domain: "NowPlayingProbe", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "AVAudioPlayer did not start"])
            }
            elapsed = player?.currentTime ?? 0
            timestamp = Date()
            playing = true
            record("playing before publication content=\(usesGenericContent ? "GenericContent" : "MusicContent")")
            observe(session)
            if !session.isApplicationPrimary {
                guard session.canBecomeApplicationPrimary else {
                    record("publication ineligible")
                    return
                }
                try await session.requestToBecomeApplicationPrimary()
            }
            guard intent == generation, playing, self.session === session else { return }
            record("publication completed")
            // Also test after the foreground launch transition has settled.
            // This is a fixed probe delay, not a periodic takeover loop.
            try await Task.sleep(for: .milliseconds(300))
            guard intent == generation, playing, self.session === session else { return }
            await requestProminence()
        } catch { record("play/publication error \(error)") }
    }

    func requestProminence() async {
        guard playing, let session, session.isApplicationPrimary,
              !session.isSystemPrimary, !promoting else { return }
        guard UIApplication.shared.applicationState != .background else {
            record("prominence deferred until foreground")
            return
        }
        let intent = generation
        promoting = true
        defer { promoting = false }
        record("prominence requested")
        do {
            try await session.requestToBecomeSystemPrimary()
            guard intent == generation, playing, self.session === session else { return }
            record("prominence completed")
        } catch {
            guard intent == generation, playing, self.session === session else { return }
            record("prominence error \(error)")
        }
    }

    func pause() {
        generation += 1
        player?.pause()
        elapsed = player?.currentTime ?? 0
        timestamp = Date()
        playing = false
        record("pause")
    }

    func stop() {
        pause()
        player?.stop()
        player = nil
        session = nil
        record("stopped")
    }

    private func record(_ event: String) {
        status = "\(event)\neligible=\(session?.canBecomeApplicationPrimary.description ?? "none") "
            + "applicationPrimary=\(session?.isApplicationPrimary.description ?? "none") "
            + "systemPrimary=\(session?.isSystemPrimary.description ?? "none") "
            + "appState=\(UIApplication.shared.applicationState.rawValue)"
        NSLog("[NowPlayingProbe] %@", status)
    }

    private func observe(_ observed: MediaSession<ProbePlayer>) {
        guard session === observed else { return }
        withObservationTracking {
            _ = observed.canBecomeApplicationPrimary
            _ = observed.isApplicationPrimary
            _ = observed.isSystemPrimary
        } onChange: { [weak self, weak observed] in
            Task { @MainActor in
                guard let self, let observed, self.session === observed else { return }
                self.record("status changed")
                self.observe(observed)
            }
        }
    }

    nonisolated private static func tone() -> Data {
        let frames = 44_100 * 8
        var data = Data()
        data.reserveCapacity(44 + frames * 2)
        func word<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: "RIFF".utf8)
        word(UInt32(36 + frames * 2))
        data.append(contentsOf: "WAVEfmt ".utf8)
        word(UInt32(16)); word(UInt16(1)); word(UInt16(1))
        word(UInt32(44_100)); word(UInt32(88_200)); word(UInt16(2)); word(UInt16(16))
        data.append(contentsOf: "data".utf8)
        word(UInt32(frames * 2))
        for frame in 0..<frames {
            word(Int16(sin(Double(frame) * 220 * 2 * .pi / 44_100) * 8_000))
        }
        return data
    }
}
