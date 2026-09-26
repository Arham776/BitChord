import Foundation

// Engine output, on this machine, with this machine's real audio device.
//
// A fixture cannot check any of this. Every claim the app makes about sound —
// that the ring fills, that the playhead moves at the right rate, that a seek
// lands — is a claim about a thread talking to a callback, and the only way to
// know is to run it. That standard is what found the activation race (a
// RemoteIO unit started before the session was up never gets pulled, so the
// track downloads in silence) and the main-thread seek.
//
// Each check names the failure it exists to catch, because "it works" is not a
// thing this file can conclude on its own.

var failures = 0
var checks = 0

func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    checks += 1
    if ok {
        print("  ok   \(label)\(detail.isEmpty ? "" : " — \(detail)")")
    } else {
        failures += 1
        print("  FAIL \(label)\(detail.isEmpty ? "" : " — \(detail)")")
    }
}

final class Recorder: EngineCallback, @unchecked Sendable {
    private let lock = NSLock()
    private var states: [PlaybackState] = []
    private var errors: [String] = []
    private var durations: [Double] = []
    private var ended = 0

    func onStateChanged(state: PlaybackState) { lock.withLock { states.append(state) } }
    func onTrackEnded(reason: TrackEndReason) { lock.withLock { ended += 1 } }
    func onError(message: String) { lock.withLock { errors.append(message) } }
    func onHandoff(info: TrackInfoRec) {}
    func onDurationChanged(seconds: Double) { lock.withLock { durations.append(seconds) } }

    var errorList: [String] { lock.withLock { errors } }
    var durationList: [Double] { lock.withLock { durations } }
    var stateList: [PlaybackState] { lock.withLock { states } }
}

func makeWav(_ path: String, seconds: Double, hz: Double) {
    let rate = 44_100.0
let frames = Int(rate * seconds)
    let channels = 2
    let bits = 16
    let byteRate = Int(rate) * channels * bits / 8
    let dataBytes = frames * channels * bits / 8

    func le32(_ v: Int) -> [UInt8] {
        [UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 24) & 0xff)]
    }
    func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xff), UInt8((v >> 8) & 0xff)] }

    var bytes: [UInt8] = []
    bytes += Array("RIFF".utf8)
    bytes += le32(36 + dataBytes)
    bytes += Array("WAVEfmt ".utf8)
    bytes += le32(16)
    bytes += le16(1)             // PCM
    bytes += le16(channels)
    bytes += le32(Int(rate))
    bytes += le32(Int(byteRate))
    bytes += le16(channels * bits / 8)
    bytes += le16(bits)
    bytes += Array("data".utf8)
    bytes += le32(dataBytes)

    var sample = 0.0
    let step = 2 * Double.pi * hz / Double(rate)
    for _ in 0..<frames {
        let value = Int(sin(sample) * 20_000)
        sample += step
        let v = UInt16(bitPattern: Int16(value))
        bytes += le16(Int(v))
        bytes += le16(Int(v))
    }
    try? Data(bytes).write(to: URL(fileURLWithPath: path))
}

/// A position read at a moment, so the harness can prove the playhead moved
/// *while* something else was happening.
func readPosition(after engine: PlayerEngine, _ seconds: Double) -> Double {
    Thread.sleep(forTimeInterval: seconds)
    return engine.positionSeconds()
}

let tmp = NSTemporaryDirectory() + "bitchord-engine-verify"
try? FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
let wav = tmp + "/tone.wav"
makeWav(wav, seconds: 6.0, hz: 440)

print("engine: real output device, real mixer thread")
let engine = PlayerEngine()
let rec = Recorder()
engine.registerCallback(callback: rec)

do {
    // 1. The device's own figures, exactly what macOS has no opinion about.
    try engine.start(rate: nil, channels: nil)
    check("start opens the output", true)
} catch {
    check("start opens the output", false, "\(error)")
    exit(1)
}

// 2. A load must come back with a decoded duration, which is the first proof
//    that bytes actually reached a decoder.
var loaded: TrackInfoRec?
do {
    loaded = try engine.loadTrack(request: LoadRequest(
        source: wav, title: "tone", artist: "harness",
        startSeconds: 0, plan: nil, headers: nil, claimedKbps: 0
    ))
    check("load reports the decoded duration", loaded!.durationSeconds > 5.5,
          "\(String(format: "%.2f", loaded!.durationSeconds))s")
    check("load reports the source rate", loaded!.sampleRate == 44_100,
          "\(loaded!.sampleRate) Hz")
} catch {
    check("load decodes the file", false, "\(error)")
    exit(1)
}

// 3. The playhead must advance on its own. This is the check that would have
//    caught the activation race: a unit the daemon never pulls leaves the
//    position pinned at zero forever while everything above reports success.
let first = readPosition(after: engine, 0.6)
let second = readPosition(after: engine, 0.6)
check("playhead advances", second > first && first > 0,
      "\(String(format: "%.3f", first)) -> \(String(format: "%.3f", second))")
check("playhead advances at roughly real time",
      abs((second - first) - 0.6) < 0.25,
      String(format: "%.3fs of audio in 0.600s of wall clock", second - first))

// 4. Seek used to block the calling thread on the mixer for up to fifteen
//    seconds. It must now return promptly, and the position must still land.
let before = engine.positionSeconds()
let seekStart = Date()
engine.seek(seconds: 4.0)
let elapsed = Date().timeIntervalSince(seekStart)
check("seek returns without waiting for the mixer", elapsed < 0.05,
      String(format: "%.1f ms", elapsed * 1000))
let after = readPosition(after: engine, 0.4)
check("seek moved the playhead", after > 3.8, "-> \(String(format: "%.2f", after))s (was \(String(format: "%.2f", before))s)")

// 5. A seek with nothing loaded has to say so rather than fail silently. This
//    is what the event replaced the blocking handshake with.
let idle = PlayerEngine()
let idleRec = Recorder()
idle.registerCallback(callback: idleRec)
try? idle.start(rate: nil, channels: nil)
idle.seek(seconds: 3.0)
Thread.sleep(forTimeInterval: 0.5)
check("a seek with nothing playing is reported, not dropped",
      idleRec.errorList.contains { $0.contains("nothing playing") },
      idleRec.errorList.joined(separator: " | "))

// 6. A second start must be a no-op, and must honour an explicit format when
//    the platform has one. 48 kHz/2 is what the Mac's device reports, so asking
//    for it exercises the override path end to end.
do {
    try engine.start(rate: 48_000, channels: 2)
    check("a repeated start is a no-op", true)
} catch {
    check("a repeated start is a no-op", false, "\(error)")
}

// 7. The audio pipeline panel reads this, and a panel that reports a device the
//    engine did not open would be worse than no panel. So the honest answer
//    before anything is open has to be "not open" — checked on a *fresh*
//    engine, since the idle one above did start (it is how the seek-with-
//    nothing-playing check gets a running mixer to refuse against).
let never = PlayerEngine()
let neverDevice = never.outputDevice()
check("an engine that was never started says so", !neverDevice.started,
      "started=\(neverDevice.started) name=\(neverDevice.name.isEmpty ? "<none>" : neverDevice.name)")
check("an engine that was never started has no rate to report",
      neverDevice.sampleRate == 0, "\(neverDevice.sampleRate)")

let device = engine.outputDevice()
check("a started engine reports its device", device.started && !device.name.isEmpty,
      "\(device.name) at \(device.sampleRate) Hz / \(device.channels) ch")
check("the reported rate is the rate it is playing at",
      device.sampleRate == 48_000, "\(device.sampleRate) Hz")
check("the reported rate is not the source rate",
      device.sampleRate != 44_100,
      "source is 44100, output is \(device.sampleRate) — the resampler is real")
check("a started engine reports its channel count", device.channels > 0, "\(device.channels)")

// 8. The readout has to be stable while nothing is changing, or the panel would
//    flicker values nobody touched. Read twice across a short gap.
let again = engine.outputDevice()
check("the readout is stable between reads",
      again.name == device.name && again.sampleRate == device.sampleRate
          && again.channels == device.channels,
      "\(again.name) \(again.sampleRate) Hz / \(again.channels) ch")

print(failures == 0 ? "\nall \(checks) checks passed" : "\n\(failures) of \(checks) checks FAILED")
exit(failures == 0 ? 0 : 1)
