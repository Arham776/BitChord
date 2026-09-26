import SwiftUI
import AppKit
import BitChordShared

// Two checks on the Listen Together UI, because they are two different failures and
// only one of them is awkward to do.
//
// **The copy.** Every sentence the screen can say is a function of state in
// `PartyCopy`, and this calls each one in each state. That is the part of a screen
// that is wrong most easily and least visibly: a view that interpolated its own copy
// would have no single place to ask "what does this say when the party is full", and
// no way to find out without a window.
//
// **The layout.** Every screen and every sheet is hosted in a real view hierarchy at
// a real size and asked for the size it settles on. This is the part a compiler
// cannot see: a view that builds and collapses.
//
// The copy is checked here rather than through the rendered text because this machine
// has no window server to composite into — a hosted view comes back as a single flat
// colour, so neither its subviews nor its accessibility tree carry any words. Reading
// the words out of a picture would work and would also be absurd: it would be OCR
// asserting on strings that are already in the source, able to be wrong about both the
// spelling and the intent.
//
// Run: scripts/check-party-ui.sh

var failures = 0

func check(_ label: String, _ condition: Bool) {
    if condition {
        print("  ok  \(label)")
    } else {
        print("  XX  \(label)")
        failures += 1
    }
}

// MARK: - Building states
//
// Every Kotlin default is written out below. That is not pedantry: Kotlin's defaults
// are not bridged to Swift's synthesised defaults, so a state built here and a state
// built on a device are the same state only if every field is named. A check that
// quietly relied on a default would be checking a state the app can never be in.

@MainActor
func member(
    _ id: String,
    name: String,
    host: Bool = false,
    connected: Bool = true
) -> PartyMember {
    PartyMember(
        memberId: id,
        userId: "u-\(id)",
        displayName: name,
        avatarUrl: nil,
        isHost: host,
        connected: connected,
        joinedAtMs: 0,
        lastSeenMs: 0
    )
}

@MainActor
func track(
    _ id: String,
    title: String,
    artist: String = "",
    durationMs: Int64? = nil,
    fromAutoplay: Bool = false
) -> PartyTrack {
    PartyTrack(
        videoId: id,
        title: title,
        artist: artist,
        thumbnailUrl: nil,
        durationMs: durationMs.map { KotlinLong(value: $0) },
        fromAutoplay: fromAutoplay
    )
}

@MainActor
func partyActivity(action: String, by: String, atMs: Int64, detail: String = "") -> PartyActivity {
    PartyActivity(action: action, by: by, atMs: atMs, detail: detail)
}

@MainActor
func partyQueue(seq: Int64, index: Int32, items: [PartyTrack]) -> PartyQueue {
    PartyQueue(seq: seq, index: index, items: items)
}

@MainActor
func playback(
    seq: Int64,
    song: PartyTrack?,
    isPlaying: Bool = false,
    positionMs: Int64 = 0,
    queueSeq: Int64 = 0,
    queueIndex: Int32 = -1
) -> PartyPlayback {
    PartyPlayback(
        seq: seq,
        track: song,
        queueSeq: queueSeq,
        queueLength: 0,
        queueIndex: queueIndex,
        isPlaying: isPlaying,
        positionMs: positionMs,
        anchorMs: 0,
        effectivePositionMs: 0,
        updatedBy: nil,
        startedBy: nil,
        startedByName: nil,
        autoplayEnabled: false,
        updatedAtMs: 0
    )
}

@MainActor
func partyState(
    inParty: Bool = true,
    you: PartyMember? = nil,
    members: [PartyMember] = [],
    maxMembers: Int32 = 5,
    hostOnlyControl: Bool = false,
    nowPlaying: PartyPlayback? = nil,
    queue: PartyQueue? = nil,
    activity: PartyActivity? = nil,
    activities: [PartyActivity] = [],
    error: PartyError? = nil,
    connection: PartyConnection = PartyConnection.offline,
    clockSynced: Bool = false,
    roundTripMs: Int64 = 0,
    lastServerMs: Int64 = 0,
    needsQueueRefetch: Bool = false
) -> PartyState {
    PartyState(
        inParty: inParty,
        you: you,
        members: members,
        maxMembers: maxMembers,
        hostOnlyControl: hostOnlyControl,
        playback: nowPlaying ?? playback(seq: 0, song: nil),
        queue: queue ?? partyQueue(seq: 0, index: -1, items: []),
        activity: activity,
        activities: activities,
        error: error,
        connection: connection,
        clockSynced: clockSynced,
        roundTripMs: roundTripMs,
        lastServerMs: lastServerMs,
        needsQueueRefetch: needsQueueRefetch
    )
}

// MARK: - Layout

/// Host a view for real and report the size it settled on.
///
/// A window rather than a bare hosting view, because a `NavigationStack` will not lay
/// itself out without one and would otherwise report a size that says nothing.
@MainActor
@discardableResult
func laysOut<V: View>(_ view: V, label: String, width: CGFloat = 900, height: CGFloat = 900) -> CGSize {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: width, height: height),
        styleMask: [.titled, .resizable],
        backing: .buffered,
        defer: false
    )
    let host = NSHostingView(rootView: AnyView(view))
    host.autoresizingMask = []
    window.contentView = host
    window.setContentSize(NSSize(width: width, height: height))
    window.makeKeyAndOrderFront(nil)
    window.orderFrontRegardless()
    host.layoutSubtreeIfNeeded()
    // Pump the run loop so SwiftUI's own work — the position tick's first layout, a
    // sheet's title bar — happens before the size is read.
    let deadline = Date().addingTimeInterval(0.35)
    while Date() < deadline {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        window.display()
    }
    let size = host.fittingSize
    check("the \(label) lays out at a real size", size.width > 1 && size.height > 1)
    check(
        "the \(label) is not clipped by the window",
        size.height <= CGFloat(height) + 1 || size.width <= CGFloat(width) + 1
    )
    window.orderOut(nil)
    return size
}

@MainActor
func screen(_ store: PartyStore) -> some View {
    NavigationStack { ListenTogetherView() }
        .environment(store)
        .environment(ToastCenter())
        .environment(AppModel())
}

@MainActor
func run() {
    print("Listen Together UI check")

    // ---- Wiring. ----------------------------------------------------------

    PartySocket.register()
    check("the socket is registered with the bridge", PartySocketBridge.shared.isWired)

    let idle = PartyStore()
    idle.attach(player: nil)
    check("a store with no party is not in one", !idle.inParty)
    check("a store with no party has no code", idle.code.isEmpty)
    check("a store with no party has no host", !idle.isHost)
    check("a store with no resolved server claims nothing", idle.server == nil && !idle.serverAnswered)
    check("a store with no resolved server has no position", idle.partyPositionMs == nil)
    idle.setForCheck(partyState(inParty: false), code: "")
    check("a party that has not begun is not in one", !idle.inParty)

    // ---- Copy: the party, in every state it distinguishes. ----------------

    let sam = member("m1", name: "Sam", host: true)
    let alex = member("m2", name: "Alex")
    let robin = member("m3", name: "Robin", connected: false)
    let song = track("abc123", title: "A Song", artist: "An Artist", durationMs: 214_000)
    let next = track("def456", title: "Next Song", artist: "Other Artist")

    check(
        "a party with a song names it",
        PartyCopy.nowPlayingTitle(song) == "A Song"
    )
    check(
        "a party with no song says so",
        PartyCopy.nowPlayingTitle(nil) == "Nothing playing yet"
    )
    check(
        "a song with a blank title is still named as nothing playing",
        PartyCopy.nowPlayingTitle(track("x", title: "   ")) == "Nothing playing yet"
    )
    let detail = PartyCopy.nowPlayingDetail(
        track: song,
        positionMs: 61_500,
        connection: PartyConnection.live,
        clockSynced: true,
        roundTripMs: 12
    )
    check("the detail line names the artist", detail.contains("An Artist"))
    check("the detail line says where the party is", detail.contains("1:01") && detail.contains("3:34"))
    check("the detail line says how in step this device is", detail.contains("In sync · 12 ms"))
    check(
        "a song with no artist does not leave a dangling separator",
        !PartyCopy.nowPlayingDetail(
            track: track("x", title: "T"),
            positionMs: 0,
            connection: PartyConnection.live,
            clockSynced: true,
            roundTripMs: 1
        ).hasPrefix(" · ")
    )

    check(
        "a party with no frame yet says reconnecting",
        PartyCopy.connectionLine(
            connection: PartyConnection.connecting, clockSynced: false, roundTripMs: 0
        ) == "Reconnecting…"
    )
    check(
        "a party that is live but unmeasured does not claim to be in sync",
        PartyCopy.connectionLine(
            connection: PartyConnection.live, clockSynced: false, roundTripMs: 0
        ) == "Measuring the clock…"
    )
    check(
        "a measured party says the round trip",
        PartyCopy.connectionLine(
            connection: PartyConnection.live, clockSynced: true, roundTripMs: 12
        ) == "In sync · 12 ms round trip"
    )
    check(
        "a party that was live and is not any more says reconnecting, not in sync",
        PartyCopy.connectionLine(
            connection: PartyConnection.offline, clockSynced: true, roundTripMs: 4
        ) == "Reconnecting…"
    )

    check("the count reads as a count", PartyCopy.listeningHeader(members: 3, maxMembers: 5) == "Listening · 3 of 5")
    check("a party of one says one of five", PartyCopy.listeningHeader(members: 1, maxMembers: 5) == "Listening · 1 of 5")
    check("a full party says so in the header", PartyCopy.listeningHeader(members: 5, maxMembers: 5) == "Listening · 5 of 5")
    check(
        "the footer says how many can be in a party",
        PartyCopy.listeningFooter(maxMembers: 5).contains("5 devices")
    )
    check(
        "an away member's slot is described as held, not as gone",
        PartyCopy.awaySubtitle.contains("slot is held")
    )
    check(
        "a locked transport explains that pausing is still possible",
        PartyCopy.transportLockedFooter.contains("pause on your own device")
    )
    check("a playing party offers a pause for everyone", PartyCopy.transportTitle(isPlaying: true).hasPrefix("Pause"))
    check("a paused party offers a play for everyone", PartyCopy.transportTitle(isPlaying: false).hasPrefix("Play"))
    check("a queue with something ahead is counted", PartyCopy.queueHeader(ahead: 2) == "Up next · 2")
    check("a queue with nothing ahead is not counted", PartyCopy.queueHeader(ahead: 0) == "Up next")
    check("the log says it is this session only", PartyCopy.activityFooter.contains("session only"))
    check("leaving says the others carry on", PartyCopy.leaveSubtitle.contains("carry on"))
    check("the code footer explains the alphabet", PartyCopy.codeFooter.contains("O and I aren’t used"))
    check("no server is described without naming one", PartyCopy.serverUsingDefault == "Using default server")
    check(
        "a locked address says why it is locked",
        PartyCopy.serverLockedFooter.contains("Locked while you are in a party")
    )
    check(
        "an unlocked address says what leaving it empty does",
        PartyCopy.serverFooter.contains("Leave this empty")
    )
    check("a named host is asked about by name", PartyCopy.joinQuestion(hostName: "Sam") == "Join Sam’s party?")
    check("an unnamed host is asked about in general", PartyCopy.joinQuestion(hostName: "  ") == "Join this party?")
    check("a host that is only whitespace is unnamed", PartyCopy.joinQuestion(hostName: " ") == "Join this party?")

    // ---- Formatting. ------------------------------------------------------

    check("0 ms is 0:00", PartyFormat.elapsed(ms: 0) == "0:00")
    check("61.5 s is 1:01", PartyFormat.elapsed(ms: 61_500) == "1:01")
    check("214 s is 3:34", PartyFormat.elapsed(ms: 214_000) == "3:34")
    check("an hour is 60:00", PartyFormat.elapsed(ms: 3_600_000) == "60:00")
    check("a negative position is not a negative time", PartyFormat.elapsed(ms: -5_000) == "0:00")
    check("a blank name is nil, not a blank row", "".nonEmpty == nil && "  ".nonEmpty == nil)
    check("a real name is itself", "Sam".nonEmpty == "Sam")
    check(
        "an activity line reads as a sentence",
        PartyFormat.activityLine(partyActivity(action: "play", by: "Sam", atMs: 0, detail: "Started playback"))
            .contains("Started playback")
    )
    check(
        "an activity with no detail falls back to the action",
        PartyFormat.activityLine(partyActivity(action: "seek", by: "Sam", atMs: 0)).contains("seek")
    )
    check(
        "an activity line says who did it",
        PartyFormat.activityLine(partyActivity(action: "play", by: "Alex", atMs: 0)).contains("Alex")
    )

    // ---- The transport conversion, both ways. -----------------------------

    let sample = PartyTrack(
        videoId: "v1",
        title: "T",
        artist: "A",
        thumbnailUrl: "https://example.com/x.jpg",
        durationMs: KotlinLong(value: 100_000),
        fromAutoplay: true
    )
    let round = QueueEntry.asPartyTrack(sample)
    check("a party track survives the round trip", round.videoId == "v1" && round.title == "T")
    check("the round trip keeps the artist", round.artist == "A")
    check("the round trip keeps autoplay", round.fromAutoplay)
    check("a track back from a party is playable here", round.source == "yt:v1")

    // ---- Errors, and what is allowed to reach a screen. -------------------

    check(
        "a server's own sentence is shown as it is",
        PartyStore.describe(NSError(
            domain: "KotlinException",
            code: 0,
            userInfo: [NSLocalizedDescriptionKey: "This party is full"]
        )) == "This party is full"
    )
    let transport = PartyStore.describe(NSError(
        domain: NSURLErrorDomain,
        code: NSURLErrorCannotConnectToHost,
        userInfo: [NSURLErrorFailingURLErrorKey: URL(string: "http://192.168.0.252:8000/healthz")!]
    ))
    check("an unreachable server is named by host", transport.contains("192.168.0.252"))
    check("an unreachable server does not leak a path", !transport.contains("/healthz"))
    check("an unknown failure still has a sentence", !PartyStore.describe(NSError(domain: "x", code: 1)).isEmpty)

    // ---- Layout: every state, every sheet. -------------------------------

    laysOut(screen(PartyStore()), label: "idle screen")

    let host = PartyStore()
    host.setForCheck(
        partyState(
            you: sam,
            members: [sam, alex, robin],
            nowPlaying: playback(seq: 12, song: song, isPlaying: true, positionMs: 61_500, queueSeq: 3, queueIndex: 0),
            queue: partyQueue(seq: 3, index: 0, items: [song, next]),
            activity: partyActivity(action: "setTrack", by: "Sam", atMs: 1_700_000_000_000, detail: "Changed the song"),
            activities: [partyActivity(action: "setTrack", by: "Sam", atMs: 1_700_000_000_000, detail: "Changed the song")],
            connection: PartyConnection.live,
            clockSynced: true,
            roundTripMs: 12
        ),
        code: "ABC123"
    )
    laysOut(screen(host), label: "in-party screen as host")
    check("the host is in a party", host.inParty && host.isHost)
    check("the host may drive the music", host.state.canControl)
    check("the host's own row is marked", host.state.isMe(member: sam) && !host.state.isMe(member: alex))
    check("the code is the party's", host.code == "ABC123")

    let locked = PartyStore()
    locked.setForCheck(
        partyState(
            you: alex,
            members: [sam, alex],
            hostOnlyControl: true,
            connection: PartyConnection.live,
            clockSynced: true,
            roundTripMs: 8
        ),
        code: "XYZ789"
    )
    laysOut(screen(locked), label: "screen as a locked listener")
    check("a locked listener may not drive the music", !locked.state.canControl)
    check("a locked listener is told so", locked.state.controlsLocked)
    check("a locked listener is still in the party", locked.inParty)

    // The host is never locked out of their own party, and that has to survive a
    // reader of `controlsLocked` getting it backwards.
    let hostStillLocked = PartyStore()
    hostStillLocked.setForCheck(
        partyState(you: sam, members: [sam, alex], hostOnlyControl: true, connection: PartyConnection.live),
        code: "HOSTLK"
    )
    check("the host is never locked out", !hostStillLocked.state.controlsLocked)

    // A device not in a party is nobody's business.
    check(
        "a device with no party is not locked out of one",
        !partyState(inParty: false, hostOnlyControl: true).controlsLocked
    )

    let full = PartyStore()
    full.setForCheck(
        partyState(
            you: sam,
            members: (0..<5).map { member("m\($0)", name: "P\($0)") },
            connection: PartyConnection.live
        ),
        code: "FULL01"
    )
    laysOut(screen(full), label: "a full party")
    check("a full party has no room", !full.state.hasRoom && full.state.isFull)
    check("a full party is only full to somebody joining", full.state.isFullFor(joining: false) == false)

    let cold = PartyStore()
    cold.setForCheck(
        partyState(you: sam, members: [sam], connection: PartyConnection.connecting),
        code: "WAIT01"
    )
    laysOut(screen(cold), label: "a connecting party")

    let measuring = PartyStore()
    measuring.setForCheck(
        partyState(you: sam, members: [sam], connection: PartyConnection.live, clockSynced: false),
        code: "MEAS01"
    )
    laysOut(screen(measuring), label: "a party measuring its clock")

    let refused = PartyStore()
    refused.setForCheck(
        partyState(you: sam, members: [sam], connection: PartyConnection.live),
        code: "ERR001"
    )
    refused.failure = "This party is full"
    laysOut(screen(refused), label: "a party showing a refusal")

    let quiet = PartyStore()
    quiet.setForCheck(
        partyState(you: sam, members: [sam], connection: PartyConnection.live),
        code: "QUIET1"
    )
    laysOut(screen(quiet), label: "a party with nothing in its log")

    // The sheets, each at the size a sheet is actually presented at.
    func sheet<V: View>(_ view: V, _ label: String) {
        laysOut(
            NavigationStack { view }
                .environment(idle)
                .environment(ToastCenter())
                .environment(AppModel()),
            label: label,
            width: 460,
            height: 640
        )
    }
    sheet(CreatePartySheet(onCreated: {}), "create sheet")
    sheet(JoinPartySheet(), "join sheet")
    sheet(InviteSheet(), "invite sheet")
    sheet(PartyServerEditor(), "server editor")

    let fullPreview = PartyPreview(
        code: "FULL01",
        hostName: "Sam",
        memberCount: 5,
        maxMembers: 5,
        isFull: true,
        members: [
            PartyPreviewMember(displayName: "Sam", avatarUrl: nil, isHost: true),
            PartyPreviewMember(displayName: "Alex", avatarUrl: nil, isHost: false),
        ]
    )
    let openPreview = PartyPreview(
        code: "OPEN01",
        hostName: "",
        memberCount: 2,
        maxMembers: 5,
        isFull: false,
        members: [PartyPreviewMember(displayName: "Sam", avatarUrl: nil, isHost: true)]
    )
    sheet(JoinConfirmSheet(preview: fullPreview, server: nil), "confirm sheet for a full party")
    sheet(JoinConfirmSheet(preview: openPreview, server: nil), "confirm sheet for an open party")
    sheet(
        JoinConfirmSheet(preview: openPreview, server: "http://192.168.0.252:8000"),
        "confirm sheet for an invite naming a server"
    )

    // The code field, at every length it can be, including the one where there is
    // no character to show and a caret has to stand in for it.
    for length in 0...6 {
        laysOut(
            Form { PartyCodeField(code: .constant(String(repeating: "A", count: length))) {} },
            label: "code field with \(length) characters",
            width: 440,
            height: 240
        )
    }

    print("")
    print(failures == 0 ? "PASS" : "FAILURES: \(failures)")
    exit(failures == 0 ? 0 : 1)
}

@main
enum CheckPartyUI {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.activate(ignoringOtherApps: true)
        MainActor.assumeIsolated { run() }
    }
}
