import Foundation
import AVFoundation

@main struct Verify {
    static func main() async throws {
        _ = await HeadphoneRouting.shared.acquire(allowSwitching: true)
        defer { Task { await HeadphoneRouting.shared.release() } }
        try await Task.detached {
            let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
            defer { try? FileManager.default.removeItem(at: path) }
            let frames = 48000 * 3
            var data = Data()
            func word<T: FixedWidthInteger>(_ value: T) {
                var little = value.littleEndian
                withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
            }
            data.append(Data("RIFF".utf8)); word(UInt32(36 + frames * 4))
            data.append(Data("WAVEfmt ".utf8)); word(UInt32(16)); word(UInt16(1)); word(UInt16(2))
            word(UInt32(48000)); word(UInt32(192000)); word(UInt16(4)); word(UInt16(16))
            data.append(Data("data".utf8)); word(UInt32(frames * 4))
            for n in 0..<frames {
                let sample = Int16(sin(Double(n) * 2 * .pi * 440 / 48000) * 1000)
                word(sample); word(sample)
            }
            try data.write(to: path)
            let engine = PlayerEngine()
            try engine.start(rate: nil, channels: nil)
            defer { try? engine.stop() }
            try engine.setSleepGain(gain: 0.05)
            _ = try engine.loadTrack(request: LoadRequest(source: path.path, title: "Routing fixture", artist: "Verification",
                startSeconds: 0, plan: nil, headers: nil, claimedKbps: 0, loudnessDb: nil, durationSeconds: 3))
            try await Task.sleep(for: .milliseconds(250))
            let start = engine.positionSeconds()
            try await Task.sleep(for: .milliseconds(400))
            let playing = engine.positionSeconds()
            guard playing > start + 0.2 else { fatalError("Output callback did not advance") }
            try engine.pause()
            try await Task.sleep(for: .milliseconds(100))
            let paused = engine.positionSeconds()
            try await Task.sleep(for: .milliseconds(150))
            guard abs(engine.positionSeconds() - paused) < 0.05 else { fatalError("Pause did not hold") }
            try engine.play()
            try await Task.sleep(for: .milliseconds(300))
            guard engine.positionSeconds() > paused + 0.15 else { fatalError("Resume did not advance") }
            let output = engine.outputDevice()
            print("PASS arbitrated native playback, pause and resume; output=\(output)")
        }.value
        await HeadphoneRouting.shared.release()
    }
}
