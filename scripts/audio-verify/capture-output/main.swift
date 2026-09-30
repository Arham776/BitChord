import Foundation

final class CaptureRecorder: EngineCallback, @unchecked Sendable {
    let lock = NSLock()
    var errors: [String] = []
    func onStateChanged(state: PlaybackState) {}
    func onTrackEnded(reason: TrackEndReason, source: String) {}
    func onError(message: String) { lock.withLock { errors.append(message) } }
    func onHandoff(info: TrackInfoRec) {}
    func onDurationChanged(seconds: Double) {}
}
let source = CommandLine.arguments[1]
let directory = CommandLine.arguments[2]
let reportPath = CommandLine.arguments[3]
let engine = PlayerEngine()
let recorder = CaptureRecorder()
engine.registerCallback(callback: recorder)
engine.setVolume(gain: 0)
try engine.start(rate: nil, channels: nil)
try engine.setSoundMode(mode: .enhanced)
_ = try engine.loadTrack(request: LoadRequest(source: source, title: "Capture continuity fixture", artist: "Validation", startSeconds: 0, plan: nil, headers: nil, claimedKbps: 0, loudnessDb: nil, durationSeconds: nil))
Thread.sleep(forTimeInterval: 6)
let before = engine.outputHealth()
let startPosition = engine.positionSeconds()
try engine.startDiagnosticCapture(directory: directory, seconds: 30)
Thread.sleep(forTimeInterval: 32)
let finishStart = Date()
try engine.finishDiagnosticCapture()
let finishSeconds = Date().timeIntervalSince(finishStart)
let after = engine.outputHealth()
let endPosition = engine.positionSeconds()
let errors = recorder.lock.withLock { recorder.errors }
let captureURL = URL(fileURLWithPath: directory).appendingPathComponent("capture.json")
let metadata = try JSONSerialization.jsonObject(with: Data(contentsOf: captureURL)) as! [String: Any]
let underruns = after.callbackUnderruns - before.callbackUnderruns
let xruns = after.outputXruns - before.outputXruns
var stageFrames: [String: Int] = [:]
var stageLengthsMatch = true
for stage in ["decoder", "voice", "protected"] {
    let url = URL(fileURLWithPath: directory).appendingPathComponent(stage + ".wav")
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    let bytes = (attributes[.size] as! NSNumber).intValue
    let rate = (metadata[stage == "decoder" ? "decoded_rate" : "output_rate"] as! NSNumber).intValue
    stageFrames[stage] = (bytes - 44) / 8
    stageLengthsMatch = stageLengthsMatch && bytes == 44 + 30 * rate * 8
}
let fingerprint = metadata["source_sha256"] as? String
let fingerprintsMatch = fingerprint != nil && fingerprint == metadata["source_sha256_at_start"] as? String
let passed = underruns == 0 && xruns == 0 && errors.isEmpty && finishSeconds < 5 && endPosition - startPosition > 31 && stageLengthsMatch && fingerprintsMatch
let report: [String: Any] = [
    "passed": passed, "callback_underruns": underruns, "device_xruns": xruns,
    "finish_seconds": finishSeconds, "initial_position_seconds": startPosition,
    "final_position_seconds": endPosition, "errors": errors,
    "core_revision": engine.nerdStats().buildRevision,
    "device": engine.outputDevice().name, "application_gain": 0,
    "encoded_bytes": metadata["encoded_bytes_at_finish"] ?? NSNull(),
    "stage_frames": stageFrames, "source_fingerprints_match": fingerprintsMatch,
    "capture_limit_seconds": metadata["capture_limit_seconds"] ?? NSNull(),
    "scope": "30-second three-stage capture and whole-file hashes during physical Enhanced playback; inaudible; no listening claim"
]
try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: reportPath))
try engine.stop()
print("Capture continuity: \(underruns) underruns, \(xruns) xruns; finish \(finishSeconds) seconds")
exit(passed ? 0 : 1)
