import Foundation

let engine = PlayerEngine()
engine.setVolume(gain: 0)
try engine.start(rate: nil, channels: nil)
defer { try? engine.stop() }
for path in CommandLine.arguments.dropFirst() {
    let format = try engine.probeAudioSource(source: path, headers: nil)
    let track = try engine.loadTrack(request: LoadRequest(source: path, title: "Hi-Res fixture", artist: "BitChord",
        startSeconds: 0, plan: nil, headers: nil, claimedKbps: 0, loudnessDb: nil, durationSeconds: nil))
    guard format.losslessPcm, format.sampleRate == 96_000, format.bitDepth == 24,
          track.sampleRate == 96_000, track.bitDepth == 24, track.channels == 2 else {
        fatalError("Hi-Res decoding mismatch: \(format) / \(track)")
    }
    print("PASS \(track.codec): \(track.bitDepth)-bit / \(track.sampleRate) Hz / \(track.channels) channels")
}
