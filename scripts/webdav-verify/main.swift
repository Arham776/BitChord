import Foundation
import BitChordShared

// The remote library, checked against a real WebDAV server.
//
// The same reasoning as the party harness. Every parser above is tested against
// fixtures built in the shape of the wire format, and a fixture cannot tell you
// that a client and a server disagree about a header — so this drives the shipped
// bridge against a server that sends real multistatus responses, real byte ranges
// and a real 401, and that deliberately contains:
//
//   * three href shapes in one listing (absolute on another host, root-relative,
//     relative), because a client that only handles the RFC's example reads a real
//     share as empty
//   * a name with a space and one with a non-ASCII character, percent-escaped
//   * a file at the root of a share and a file that is not audio
//   * a picture that must lose to `cover.jpg` and one that must not be fetched
//     with the share's credential
//
// Run: scripts/check-webdav.sh

let base = ProcessInfo.processInfo.environment["WEBDAV_URL"] ?? "http://localhost:8081/Music"
let user = "listener"
let secret = "correct-horse"

var checks = 0
var failures: [String] = []

func check(_ what: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    checks += 1
    if ok {
        print("  ok  \(what)")
    } else {
        let extra = detail()
        failures.append(what)
        print("  FAIL  \(what)\(extra.isEmpty ? "" : " — \(extra)")")
    }
}

func checkEqual<T: Equatable>(_ what: String, _ got: T, _ want: T) {
    check(what, got == want, "got \(got), wanted \(want)")
}

// ---- Bridging the suspending calls -----------------------------------------

enum HarnessError: Error { case noValue }

func test(url: String, username: String, password: String?) async throws -> String {
    try await withCheckedThrowingContinuation { c in
        WebDavBridge.shared.test(url: url, username: username, password: password) { _, error in
            if let error { c.resume(throwing: error) } else { c.resume(returning: "") }
        }
    }
}

func library() async throws -> [Song] {
    try await withCheckedThrowingContinuation { c in
        WebDavBridge.shared.library { songs, error in
            if let error { c.resume(throwing: error) }
            else if let songs { c.resume(returning: songs) }
            else { c.resume(throwing: HarnessError.noValue) }
        }
    }
}

func coverImage(_ url: String) async throws -> CoverImage? {
    try await withCheckedThrowingContinuation { c in
        WebDavBridge.shared.coverImage(fileUrl: url) { image, error in
            if let error { c.resume(throwing: error) }
            else { c.resume(returning: image) }
        }
    }
}

func embeddedCover(_ url: String) async throws -> CoverImage? {
    try await withCheckedThrowingContinuation { c in
        WebDavBridge.shared.embeddedCover(fileUrl: url) { image, error in
            if let error { c.resume(throwing: error) }
            else { c.resume(returning: image) }
        }
    }
}

func describe(_ error: Error) -> String {
    let ns = error as NSError
    if ns.domain == "KotlinException" {
        return ns.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return ns.localizedDescription
}

func sha16(_ data: Data) -> String {
    // A short digest rather than the whole file, and rather than the length: two
    // pictures of the same size with different bytes is exactly the mistake a
    // ranged read can make.
    var accumulator: UInt64 = 1469598103934665603
    for byte in data.prefix(64) {
        accumulator = (accumulator ^ UInt64(byte)) &* 1099511628211
    }
    return String(accumulator, radix: 16)
}

let embeddedMark = Array("embedded-cover".utf8)
let filedMark = Array("filed-cover".utf8)

func mark(_ data: Data, _ text: [UInt8]) -> String {
    let bytes = [UInt8](data)
    guard bytes.count >= text.count else { return "short (\(bytes.count))" }
    let window = Array(bytes[4..<(4 + text.count)])
    return window == text ? "ok" : "wrong bytes"
}

// ---- The run ----------------------------------------------------------------

let storedUrl = WebDavBridge.shared.url()
let storedUser = WebDavBridge.shared.username()
let hadPassword = WebDavBridge.shared.hasPassword()

func restore() {
    WebDavBridge.shared.save(url: storedUrl, username: storedUser, password: hadPassword ? nil : "")
}

// ---- Testing the address and the credential --------------------------------

do {
    let said = try await test(url: base, username: user, password: secret)
    check("a share that answers is a share that works", said.isEmpty || said == base, said)
} catch {
    check("a share that answers is a share that works", false, describe(error))
}

do {
    _ = try await test(url: base, username: user, password: "wrong")
    check("a wrong password is refused in a sentence a person can act on", false, "it succeeded")
} catch {
    let said = describe(error)
    check(
        "a wrong password is refused in a sentence a person can act on",
        said.contains("password") || said.contains("401"),
        said
    )
    check("a refusal does not leak the raw error", !said.contains("Kotlin"), said)
}

do {
    _ = try await test(url: "not a url", username: user, password: secret)
    check("an address that is not one is refused before a request", false, "it succeeded")
} catch {
    check("an address that is not one is refused before a request", true)
}

// ---- Saving it, and reading the share back ---------------------------------

WebDavBridge.shared.save(url: base, username: user, password: secret)
checkEqual("the saved address is normalized", WebDavBridge.shared.url(), base)
checkEqual("the saved account is remembered", WebDavBridge.shared.username(), user)
check("a saved password is remembered as a fact, not as a value", WebDavBridge.shared.hasPassword())
check("a saved share is configured", WebDavBridge.shared.isConfigured())
check("a saved address with a scheme keeps it", !WebDavBridge.shared.url().hasPrefix("https://http"))

WebDavBridge.shared.save(url: "cloud.example.com/dav", username: "", password: nil)
checkEqual(
    "an address with no scheme gains the secure one, as upstream does",
    WebDavBridge.shared.url(),
    "https://cloud.example.com/dav"
)
WebDavBridge.shared.save(url: base, username: user, password: nil)

// ---- The listing -----------------------------------------------------------

var songs: [Song] = []
do {
    songs = try await library()
    check("the share lists without being asked twice for anything", !songs.isEmpty)
} catch {
    check("the share lists", false, describe(error))
}

let byTitle = Dictionary(uniqueKeysWithValues: songs.map { ($0.title, $0) })

if let time = byTitle["Time"] {
    checkEqual("a display name beats the name in the address", time.artist, "01")
    checkEqual("the album is the folder the file is in", time.albumName ?? "", "The Dark Side of the Moon")
    checkEqual("the extension is not part of the title", time.title, "Time")
} else {
    check("a track from the album is listed", false, songs.map(\.title).joined(separator: ", "))
}

if let joga = songs.first(where: { $0.title == "Jóga" }) {
    checkEqual("a non-ASCII name survives the round trip", joga.artist, "Björk")
    // Directly in the configured root, so the album is that root's own folder name.
    // Upstream's rule: the album is the parent directory, and a file in the root of a
    // share is in a folder — it just happens to be the one being pointed at.
    checkEqual("a file in the share's root is named for the root folder", joga.albumName ?? "", "Music")
    check(
        "an absolute href on another host is kept as the server gave it",
        (joga.localPath ?? "").hasPrefix("http://127.0.0.1:"),
        joga.localPath ?? "nil"
    )
} else {
    check("a non-ASCII track is listed", false, songs.map(\.title).joined(separator: ", "))
}

check("a file that is not audio is not listed", !songs.contains { $0.title.contains("Money") })
check("a folder is not a track", !songs.contains { $0.title == "Pink Floyd" })

if let time = songs.first(where: { $0.title == "Time" }) {
    check("a track's id says where the file lives", time.videoId.hasPrefix("webdav:http"), time.videoId)
    check(
        "a track's id is the address it plays from",
        WebDavBridge.shared.fileUrlOf(videoId: time.videoId) == time.localPath
    )
    check("a track's id is recognisable as ours", WebDavBridge.shared.isRemoteId(videoId: time.videoId))
    check("a YouTube id is not one of ours", !WebDavBridge.shared.isRemoteId(videoId: "dQw4w9WgXcQ"))
    check(
        "a track's play address is the server's own",
        (time.localPath ?? "").hasPrefix(base) || (time.localPath ?? "").contains("Time.flac"),
        time.localPath ?? "nil"
    )
}

// ---- The cover filed beside the track --------------------------------------

let timeSong = songs.first { $0.title == "Time" }
checkEqual(
    "a picture named cover wins over one named IMG_1234",
    timeSong?.thumbnailUrl?.contains("cover.jpg") == true,
    true
)

if let cover = timeSong?.thumbnailUrl {
    do {
        let image = try await coverImage(cover)
        check("a filed cover fetches with the share's credential", image != nil)
        checkEqual("a filed cover knows what it is", image?.mime ?? "", "image/jpeg")
        checkEqual("the bytes are the file's own", mark(image?.bytes as Data? ?? Data(), filedMark), "ok")
    } catch {
        check("a filed cover fetches with the share's credential", false, describe(error))
    }
}

// ---- The cover inside the file ---------------------------------------------

if let fileUrl = timeSong?.localPath {
    do {
        let image = try await embeddedCover(fileUrl)
        check("a cover inside the file is found through ranged reads", image != nil)
        checkEqual("an embedded cover knows what it is", image?.mime ?? "", "image/jpeg")
        checkEqual("the embedded bytes are the tag's own", mark(image?.bytes as Data? ?? Data(), embeddedMark), "ok")
    } catch {
        check("a cover inside the file is found through ranged reads", false, describe(error))
    }
    // The same file again, which is the cache's whole reason to exist.
    do {
        let again = try await embeddedCover(fileUrl)
        check("a second read of the same cover gives the same picture", again?.bytes as Data? == (try? await embeddedCover(fileUrl))?.bytes as Data?)
    } catch {
        check("a second read of the same cover gives the same picture", false, describe(error))
    }
}

// A file with no picture in it: a .txt is not audio, so the closest thing is a
// file that exists and is not one of the fixtures' tagged FLACs.
do {
    let image = try await embeddedCover(base + "/02%20-%20Money.txt")
    check("a file with no tag has no cover, and does not fail", image == nil)
} catch {
    check("a file with no tag has no cover, and does not fail", false, describe(error))
}

// ---- Where the credential may and may not go -------------------------------

// ---- Where the credential may and may not go -------------------------------
//
// The one that matters, and the reason the fixture serves two names for itself:
// the share is reached as `localhost` and one entry in its own listing points at
// `127.0.0.1`, which is the same server on the same machine and a different
// host as far as a credential rule goes. The server demands a password, so a
// fetch that arrives without one is *observably* a fetch with no credential —
// not a claim about a dictionary that nobody checked.

let foreignCover = base.replacingOccurrences(of: "localhost", with: "127.0.0.1") + "/foreign.jpg"
let foreignTrack = base.replacingOccurrences(of: "localhost", with: "127.0.0.1")
    + "/Bj%C3%B6rk%20-%20J%C3%B3ga.flac"

check(
    "a file on another host name is given nothing, even on the same machine",
    WebDavBridge.shared.playbackHeaders(fileUrl: foreignTrack).isEmpty
)
check(
    "and the same rule says so when asked directly",
    WebDavAuth.shared.authorizes(requestUrl: base + "/x.flac")
        && !WebDavAuth.shared.authorizes(requestUrl: foreignTrack)
)
check(
    "a port does not make a different host",
    WebDavAuth.shared.headerFor(requestUrl: base.replacingOccurrences(of: ":8081", with: ":8082")) != nil
)

do {
    let image = try await coverImage(foreignCover)
    check(
        "a cover on another host is fetched without the share's password, and refused",
        image == nil
    )
} catch {
    check("a cover on another host is fetched without the share's password, and refused", false, describe(error))
}

do {
    let image = try await embeddedCover(foreignTrack)
    check(
        "a track on another host has no cover rather than the password handed over",
        image == nil
    )
} catch {
    check("a track on another host has no cover rather than the password handed over", false, describe(error))
}

let logPath = "/tmp/bitchord-webdav-requests.log"
if let log = try? String(contentsOfFile: logPath, encoding: .utf8) {
    let refused = log.split(separator: "\n").filter { $0.contains("401") }
    check(
        "and the server saw the refusals, which is the proof",
        refused.count >= 2,
        "\(refused.count) refused requests in the log"
    )
} else {
    check("and the server saw the refusals, which is the proof", false, "no request log at \(logPath)")
}

// ---- A share that refuses ---------------------------------------------------

WebDavBridge.shared.save(url: base, username: user, password: "wrong")
do {
    _ = try await library()
    check("a share that refuses does not read as an empty share", false, "it listed")
} catch {
    let said = describe(error)
    check("a share that refuses does not read as an empty share", !said.isEmpty, said)
    check("a refused listing says why, not that it is empty", !said.lowercased().contains("no audio"), said)
}

// ---- Forgetting -------------------------------------------------------------

WebDavBridge.shared.forget()
check("forgetting empties the address", WebDavBridge.shared.url().isEmpty)
check("forgetting empties the account", WebDavBridge.shared.username().isEmpty)
check("forgetting empties the password", !WebDavBridge.shared.hasPassword())
check("a forgotten share is not configured", !WebDavBridge.shared.isConfigured())
check("a forgotten share authorizes nothing", !WebDavAuth.shared.authorizes(requestUrl: base + "/x.flac"))

restore()
check("the harness leaves the settings as it found them", WebDavBridge.shared.url() == storedUrl)

// ---- Report -----------------------------------------------------------------

print("")
if failures.isEmpty {
    print("PASS  \(checks) checks")
} else {
    print("FAIL  \(failures.count) of \(checks) checks")
    failures.forEach { print("  · \($0)") }
    exit(1)
}
