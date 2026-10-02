import Foundation
import AVFoundation

let renderer = AppleDolbyRenderer()
let source = CommandLine.arguments[1]
var checks: [String: Bool] = [:]
do {
    renderer.volume = 0
    let info = try await renderer.prepare(source: source, title: "Apple Dolby validation", artist: "Apple", codec: "eac3-joc", headers: [:], startAt: 0, claimedKbps: 0)
    renderer.play()
    try await Task.sleep(for: .seconds(3))
    let progressed = renderer.position
    checks["real_audio_progress"] = progressed > 0.5
    checks["actual_dolby_format"] = info.codec == "EAC3-JOC" && info.channels > 2
    renderer.pause()
    let paused = renderer.position
    try await Task.sleep(for: .seconds(1))
    checks["stable_pause"] = abs(renderer.position - paused) < 0.1
    renderer.play()
    try await Task.sleep(for: .seconds(2))
    checks["resume_progress"] = renderer.position > paused + 0.5
    renderer.seek(10)
    try await Task.sleep(for: .seconds(1))
    checks["seek"] = renderer.position > 9
    renderer.stop()
    checks["stop_releases_player"] = renderer.player == nil
    do {
        _ = try await renderer.prepare(source: source, title: "Credential guard", artist: "", codec: "eac3", headers: ["Authorization": "synthetic-secret"], startAt: 0, claimedKbps: 0)
        checks["credentials_rejected"] = false
    } catch AppleDolbyRenderer.Failure.credentials { checks["credentials_rejected"] = true }
    print("Actual source: \(info.codec) · \(info.sampleRate) Hz · \(info.channels) channels")
} catch { print("FAIL Dolby playback: \(error.localizedDescription)"); checks["playable"] = false }
for (name, passed) in checks.sorted(by: { $0.key < $1.key }) { print("\(passed ? "PASS" : "FAIL") \(name)") }
exit(checks.values.allSatisfy { $0 } ? 0 : 1)
