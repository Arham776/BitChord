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
    func onTrackEnded(reason: TrackEndReason, source: String) { lock.withLock { ended += 1 } }
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
engine.setVolume(gain: 0.01)

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
        startSeconds: 0, plan: nil, headers: nil, claimedKbps: 0, loudnessDb: nil,
        durationSeconds: nil
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
let firstHealth = engine.outputHealth()
let second = readPosition(after: engine, 0.6)
let secondHealth = engine.outputHealth()
print("  playback counters: queued=\(firstHealth.bufferedFrames)→\(secondHealth.bufferedFrames), underruns=\(firstHealth.callbackUnderruns)→\(secondHealth.callbackUnderruns), rebuilds=\(secondHealth.outputRebuilds), peak=\(secondHealth.outputPeak)")
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

// 6. A second start is a no-op; it retains the already negotiated format.
do {
    try engine.start(rate: 48_000, channels: 2)
    check("a repeated start is a no-op", true)
} catch {
    check("a repeated start is a no-op", false, "\(error)")
}
let rebuildsBeforeNoOp = engine.outputHealth().outputRebuilds
do {
    try engine.setPreferUsbDac(enabled: false)
    Thread.sleep(forTimeInterval: 0.35)
    check("an unchanged USB preference does not rebuild output",
          engine.outputHealth().outputRebuilds == rebuildsBeforeNoOp,
          "rebuilds=\(engine.outputHealth().outputRebuilds)")
} catch {
    check("an unchanged USB preference does not rebuild output", false, "\(error)")
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
check("the negotiated rate is valid", device.sampleRate >= 8_000 && device.sampleRate <= 384_000, "\(device.sampleRate) Hz")
check("converter activation agrees with negotiated rates",
      engine.nerdStats().activeStages.contains("Rate conversion (libsoxr HQ)") == (device.sampleRate != 44_100),
      "source is 44100, negotiated output is \(device.sampleRate)")
check("a started engine reports its channel count", device.channels > 0, "\(device.channels)")

// 8. The readout has to be stable while nothing is changing, or the panel would
//    flicker values nobody touched. Read twice across a short gap.
let again = engine.outputDevice()
check("the readout is stable between reads",
      again.name == device.name && again.sampleRate == device.sampleRate
          && again.channels == device.channels,
      "\(again.name) \(again.sampleRate) Hz / \(again.channels) ch")

// 9. Output precision: the default opens the unit as int16, and FLOAT_32
//    rebuilds it as float. The readout names what was actually opened — the
//    setting is the request, this is the answer.
check("the default output has a supported PCM format", ["PCM_16", "FLOAT_32"].contains(device.sampleFormat), device.sampleFormat)
do {
    try engine.setOutputPcmMode(mode: "FLOAT_32")
    Thread.sleep(forTimeInterval: 1.0)
    let float = engine.outputDevice()
    check("FLOAT_32 rebuilds the unit as float", float.sampleFormat == "FLOAT_32", float.sampleFormat)
    try engine.setOutputPcmMode(mode: "PCM_16")
    Thread.sleep(forTimeInterval: 1.0)
    let back = engine.outputDevice()
    check("PCM_16 uses a supported device format", ["PCM_16", "FLOAT_32"].contains(back.sampleFormat), back.sampleFormat)
} catch {
    check("PCM mode switching rebuilds the unit", false, "\(error)")
}

// 10. Loudness: a load carrying a figure reports the correction upstream
//     would apply (-loudnessDb clamped to -15...0 dB); a load without one
//     reports none; the switch reports off without a reload.
do {
    try engine.setSoundMode(mode: .transparent)
    try engine.setLoudnessMode(mode: .track)
    try engine.loadTrack(request: LoadRequest(
        source: wav, title: "transparent", artist: "harness",
        startSeconds: 0, plan: nil, headers: nil, claimedKbps: 0, loudnessDb: 7.0,
        durationSeconds: nil
    ))
    Thread.sleep(forTimeInterval: 0.1)
    let transparent = engine.nerdStats()
    check("Transparent bypasses selected normalization", transparent.loudnessGainDb == nil)
    check("Transparent has no clarity or protection stage", !transparent.activeStages.contains { $0.contains("clarity") || $0.contains("True-peak") })
    try engine.setSoundMode(mode: .enhanced)
    try engine.setLoudnessMode(mode: .track)
    try engine.loadTrack(request: LoadRequest(
        source: wav, title: "tone", artist: "harness",
        startSeconds: 0, plan: nil, headers: nil, claimedKbps: 0, loudnessDb: -7.0,
        durationSeconds: nil
    ))
    let nerd = engine.nerdStats()
    check("a figured load reports the clamped correction",
          nerd.loudnessGainDb == 0.0, "\(nerd.loudnessGainDb.map { "\($0)" } ?? "nil") dB")
    try engine.setLoudnessEnabled(enabled: false)
    // The toggle travels to the mixer thread as a command (the same async
    // path as volume and skip-silence), so the readout follows it within a
    // loop turn — not within the call.
    Thread.sleep(forTimeInterval: 0.3)
    let off = engine.nerdStats()
    check("the switch reports off without a reload", off.loudnessGainDb == nil,
          "\(off.loudnessGainDb.map { "\($0)" } ?? "nil")")
    try engine.setLoudnessEnabled(enabled: true)
    Thread.sleep(forTimeInterval: 0.3)
    let on = engine.nerdStats()
    check("re-enabling restores the correction", on.loudnessGainDb == 0.0,
          "\(on.loudnessGainDb.map { "\($0)" } ?? "nil") dB")
    try engine.loadTrack(request: LoadRequest(
        source: wav, title: "tone", artist: "harness",
        startSeconds: 0, plan: nil, headers: nil, claimedKbps: 0, loudnessDb: nil,
        durationSeconds: nil
    ))
    let bare = engine.nerdStats()
    check("a figureless load reports no correction", bare.loudnessGainDb == nil,
          "\(bare.loudnessGainDb.map { "\($0)" } ?? "nil")")
} catch {
    check("loudness correction is reported", false, "\(error)")
}

// 11. Route preference and analysis tier: neither may throw, and the tier
//     setter is read back through planning rather than a getter (there is no
//     getter — the plan is the answer).
do {
    try engine.setPreferUsbDac(enabled: true)
    check("preferring USB without a DAC keeps the default",
          !engine.outputDevice().name.isEmpty, engine.outputDevice().name)
    try engine.setPreferUsbDac(enabled: false)
    engine.setAutomixPerformance(mode: "EFFICIENT")
    engine.setAutomixPerformance(mode: "BALANCED")
    check("route and tier setters hold", true)
} catch {
    check("route and tier setters hold", false, "\(error)")
}

// 12. What the planner hands the mixer, read back through the same plan the
//     engine renders from.
//
//     These are the claims a listener makes about Automix: that the next record
//     starts at the top of its own intro rather than at its drop, that the
//     blend is an arrival rather than a swap, and that the tempo match does not
//     come with a pitch bend. The first is a planner property, so it is
//     assertable here; the other two are render properties the Rust tests
//     measure on the sample level, and what this checks is that a plan
//     describing them can still be built and round-tripped over the FFI
//     boundary — a field the Swift side sets has to reach the mixer intact, and
//     a record that quietly loses one is invisible everywhere else.
do {
    let cue = engine.planAutomix(
        outgoingPath: wav, incomingPath: wav,
        outgoingText: "out", incomingText: "in",
        albumSequential: false, crossfadeSeconds: 8,
        outgoingDurationSeconds: 0, incomingDurationSeconds: 0,
        outgoingHeaders: [:], incomingHeaders: [:])
    check("a plan comes back for a real pair", true,
          "style=\(cue.style) cue=\(String(format: "%.2f", cue.cueSeconds))s "
          + "fade=\(String(format: "%.2f", cue.fadeSeconds))s "
          + "bed=\(String(format: "%.2f", cue.bedFraction)) "
          + "dip=\(String(format: "%.2f", cue.dipDepth)) "
          + "rate=\(String(format: "%.4f", cue.playbackRate))")
    // The bound the minute-long skip violated, restated on the Swift side so a
    // planner that drifted would be caught here as well as in Rust.
    check("the mix-in point is near the top of the incoming record",
          cue.cueSeconds >= 0 && cue.cueSeconds <= 8.0,
          "cue=\(String(format: "%.2f", cue.cueSeconds))s")
    check("the dip depth is a usable fraction",
          cue.dipDepth >= 0 && cue.dipDepth <= 1,
          "dip=\(String(format: "%.2f", cue.dipDepth))")
    check("a plain crossfade asks for no bed",
          cue.style == .equalPower ? cue.bedFraction == 0 && cue.dipDepth == 0 : true,
          "style=\(cue.style) bed=\(String(format: "%.2f", cue.bedFraction))")
    // The tempo match must be a real ratio, and never the 2× a clamped
    // half/double-tempo read would produce.
    check("the tempo match is a ratio, not an octave",
          cue.playbackRate > 0.5 && cue.playbackRate < 2.0,
          "rate=\(String(format: "%.4f", cue.playbackRate))")
} catch {
    check("a plan comes back for a real pair", false, "\(error)")
}

// A selected load is silent until the controller commits it. Output rebuilds
// must never restore an old playing state over a newer pause.
do {
    try engine.pause()
    _ = try engine.loadTrackPaused(request: LoadRequest(
        source: wav, title: "selected", artist: "harness",
        startSeconds: 0, plan: nil, headers: nil, claimedKbps: 0,
        loudnessDb: nil, durationSeconds: nil
    ))
    Thread.sleep(forTimeInterval: 0.2)
    check("uncommitted selection stays muted", engine.outputHealth().outputPeak == 0)
    try engine.prepareTrackOutput(
        sourceRate: 44_100, sourceChannels: 2, sourceBitDepth: 16,
        codec: "PCM", losslessPcm: true, matchSourceRate: false,
        sessionRate: nil, sessionChannels: nil
    )
    Thread.sleep(forTimeInterval: 0.2)
    check("output preparation preserves pause", engine.outputHealth().outputPeak == 0)
    try engine.play()
    let outputDeadline = Date().addingTimeInterval(3)
    while engine.outputHealth().outputPeak == 0, Date() < outputDeadline {
        Thread.sleep(forTimeInterval: 0.02)
    }
    check("committing the selection releases audio", engine.outputHealth().outputPeak > 0)
    let rebuilding = DispatchGroup()
    for _ in 0..<3 {
        rebuilding.enter()
        DispatchQueue.global().async {
            try? engine.prepareTrackOutput(
                sourceRate: 44_100, sourceChannels: 2, sourceBitDepth: 16,
                codec: "PCM", losslessPcm: true, matchSourceRate: false,
                sessionRate: nil, sessionChannels: nil
            )
            rebuilding.leave()
        }
    }
    try engine.pause()
    check("concurrent output preparations finish", rebuilding.wait(timeout: .now() + 15) == .success)
    Thread.sleep(forTimeInterval: 0.2)
    check("pause wins concurrent output rebuilds", engine.outputHealth().outputPeak == 0)
    do {
        _ = try engine.swapSourceIfCurrent(
            request: LoadRequest(
                source: wav, title: "obsolete", artist: "harness",
                startSeconds: 0, plan: nil, headers: nil, claimedKbps: 0,
                loudnessDb: nil, durationSeconds: nil
            ), crossfadeSeconds: 0.1, expectedSource: wav + ".obsolete"
        )
        check("superseded quality swap is rejected", false)
    } catch {
        check("superseded quality swap is rejected", true)
    }
} catch {
    check("transport regression checks complete", false, "\(error)")
}

print(failures == 0 ? "\nall \(checks) checks passed" : "\n\(failures) of \(checks) checks FAILED")
exit(failures == 0 ? 0 : 1)
