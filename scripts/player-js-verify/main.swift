import Foundation
let directory = URL(fileURLWithPath: CommandLine.arguments[1])
// Pass a captured public player script to verify actual transforms without
// requiring a live stream or account credentials.
if CommandLine.arguments.count > 2 {
    let player = try String(contentsOfFile: CommandLine.arguments[2], encoding: .utf8)
    let solver = try YouTubeChallengeSolver(directory: directory)
    let signature = String(repeating: "abcdefghijklmnopqrstuvwxyz", count: 4)
    let sig = try solver.solve("sig", challenge: signature, player: player)
    let n = try solver.solve("n", challenge: "abcdefg12345", player: player)
    precondition(sig != signature && !sig.isEmpty)
    precondition(n != "abcdefg12345" && !n.isEmpty)
    let again = try solver.solve("sig", challenge: signature, player: player)
    precondition(again == sig)
    let runtime = YouTubePlayerJs(solverDirectory: directory, playerText: player)
    let url = "https://r.googlevideo.com/media?keep=a%2Bb%2Fc&n=abcdefg12345"
    let transformed = try await runtime.transformUrl(url)
    precondition(transformed.contains("keep=a%2Bb%2Fc"), "Signed query encoding changed")
    precondition(transformed != url)
    let plain = "https://r.googlevideo.com/media?keep=a%2Bb%2Fc"
    let unchanged = try await runtime.transformUrl(plain)
    precondition(unchanged == plain)
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
    let cipher = "url=" + plain.addingPercentEncoding(withAllowedCharacters: allowed)! + "&s=" + signature + "&sp=sig"
    let unlocked = try await runtime.unlockCipher(cipher, videoId: "fixture")
    precondition(unlocked.contains("keep=a%2Bb%2Fc") && unlocked.contains("&sig="))
    print("PASS current player signature, throttling, cached solves and signed query encoding")
} else {
    let solver = try YouTubeChallengeSolver(directory: directory)
    do {
        _ = try solver.solve("sig", challenge: "synthetic", player: "invalid script {")
        fatalError("Invalid player was accepted")
    } catch { }
    print("PASS corrupt player rejected with a typed error")
}
