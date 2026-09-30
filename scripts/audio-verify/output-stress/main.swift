import Foundation

final class StressRecorder: EngineCallback, @unchecked Sendable {
    let lock=NSLock()
    var failures:[String]=[]
    func onStateChanged(state: PlaybackState) {}
    func onTrackEnded(reason: TrackEndReason, source: String) {lock.withLock {failures.append("Unexpected EOF: \(reason)")}}
    func onError(message: String) {lock.withLock {failures.append(message)}}
    func onHandoff(info: TrackInfoRec) {}
    func onDurationChanged(seconds: Double) {}
}
let duration=Double(CommandLine.arguments[3])!
let engine=PlayerEngine()
let recorder=StressRecorder()
engine.registerCallback(callback:recorder)
// Exercise DSP and the physical callback while keeping the test inaudible.
engine.setVolume(gain:0)
try engine.start(rate:nil,channels:nil)
try engine.setSoundMode(mode:.enhanced)
try engine.setLoudnessMode(mode:.off)
try engine.setSpatialEnabled(enabled:false)
_ = try engine.loadTrack(request:LoadRequest(source:CommandLine.arguments[1],title:"Output stress fixture",artist:"Validation",startSeconds:0,plan:nil,headers:nil,claimedKbps:0,loudnessDb:nil,durationSeconds:nil))
Thread.sleep(forTimeInterval:10)
let before=engine.outputHealth()
let initialDevice=engine.outputDevice()
let initialPosition=engine.positionSeconds()
var routeEvents:[[String:Any]]=[]
var lastRebuilds=before.outputRebuilds
var nextCheckpoint=60.0
let start=Date()
var queueMinimum=UInt64.max
while Date().timeIntervalSince(start)<duration {
    Thread.sleep(forTimeInterval:5)
    let health=engine.outputHealth()
    queueMinimum=min(queueMinimum,health.bufferedFrames)
    let elapsed=Date().timeIntervalSince(start)
    if health.outputRebuilds != lastRebuilds {
        routeEvents.append(["seconds":elapsed,"device":engine.outputDevice().name,"rebuilds":health.outputRebuilds])
        lastRebuilds=health.outputRebuilds
    }
    if elapsed>=nextCheckpoint {
        let checkpoint:[String:Any]=["elapsed_seconds":elapsed,"device":engine.outputDevice().name,"queue_frames":health.bufferedFrames,"underruns":health.callbackUnderruns-before.callbackUnderruns,"xruns":health.outputXruns-before.outputXruns,"position_seconds":engine.positionSeconds(),"route_events":routeEvents]
        try JSONSerialization.data(withJSONObject:checkpoint,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[2]+".progress"),options:.atomic)
        nextCheckpoint+=60
    }
}
let after=engine.outputHealth()
let nerd=engine.nerdStats()
let device=engine.outputDevice()
let errors=recorder.lock.withLock {recorder.failures}
let underruns=after.callbackUnderruns-before.callbackUnderruns
let xruns=after.outputXruns-before.outputXruns
let report:[String:Any]=[
    "duration_seconds":Date().timeIntervalSince(start),"warmup_seconds":10,
    "callback_underruns":underruns,"device_xruns":xruns,"minimum_sampled_queue_frames":queueMinimum,
    "output_rebuilds":after.outputRebuilds-before.outputRebuilds,
    "initial_device":initialDevice.name,"device":device.name,"route_events":routeEvents,
    "initial_position_seconds":initialPosition,"final_position_seconds":engine.positionSeconds(),"negotiated_rate":device.sampleRate,"active_stages":nerd.activeStages,
    "core_revision":nerd.buildRevision,"protection_interventions":nerd.protectionInterventions,
    "application_gain":0,"errors":errors,"passed":underruns==0 && xruns==0 && errors.isEmpty,
    "scope":"macOS physical output, local adequate source, concurrent compiler load; inaudible; no listening claim"
]
try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[2]))
try engine.stop()
print("Stress complete: \(underruns) underruns, \(xruns) xruns, \(errors.count) errors")
exit(underruns==0 && xruns==0 && errors.isEmpty ? 0 : 1)
