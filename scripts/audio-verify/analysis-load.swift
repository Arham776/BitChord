import Foundation
@main struct AnalysisLoad {
static func main() throws {
let source=CommandLine.arguments[1]
let seconds=Double(CommandLine.arguments[2])!
let end=Date().addingTimeInterval(seconds)
let engine=PlayerEngine()
var passes=0
while Date()<end {
    let start=Date()
    let result=try engine.measureLoudness(source:source)
    passes+=1
    print("Measurement \(passes): \(result.trackLufs) LUFS, \(Date().timeIntervalSince(start)) seconds")
    Thread.sleep(forTimeInterval:1)
}
print("Completed \(passes) full-source production loudness measurements")

}
}
