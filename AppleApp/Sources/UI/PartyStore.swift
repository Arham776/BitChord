import SwiftUI
import Observation
import BitChordShared

/// What the Listen Together screen reads, as one observable value.
///
/// # Why this exists rather than the views calling the coordinator
///
/// `PartyCoordinator` publishes its state through a callback, because a Kotlin
/// `StateFlow` is not something a SwiftUI view can observe: it is not an
/// `Observable`, and there is no subscription a view can make. So the one owner
/// pushes, this stores, and the views read a property that Observation can see
/// change. The same shape as every other Kotlin-to-Swift bridge in this app.
///
/// This is the *only* place a `PartyState` becomes a Swift value, which is what makes
/// the two sides impossible to disagree about: there is one copy, and the player
/// binding reads the same coordinator.
@MainActor
@Observable
final class PartyStore {

    /// The party, as this device understands it.
    ///
    /// Seeded from the coordinator rather than defaulted to a fresh `PartyState`, so
    /// a screen that appears after a party is already live shows the party instead of
    /// an empty one for a frame. Kotlin's defaults are not bridged to Swift
    /// synthesised defaults, so this is the real value read at construction.
    private(set) var state: PartyState = PartyCoordinator.shared.session.current

    /// Which server answered, and how fast. Drives the line under the address.
    ///
    /// Nil until something has been resolved, rather than a fabricated "unconfigured"
    /// answer: nothing has been probed yet, and a connection state that claims to
    /// know would be the one thing on this screen making a statement it cannot back.
    private(set) var server: ServerChoice?

    /// Whether a call to the server is in flight. Every button that reaches the
    /// server is disabled on this, because a button that appears to work and does
    /// nothing is worse than one that is briefly greyed.
    private(set) var busy = false

    /// Why the last attempt from a sheet did not work.
    ///
    /// Held here rather than read off `state.error` because a sheet covers the bottom
    /// of the screen and a line of red *underneath* it is a line nobody sees. This is
    /// why "no party with that code" used to read as a button that did nothing.
    var failure: String?

    /// A party that has been looked up and is waiting to be joined.
    ///
    /// The lookup and the join are two steps on purpose — what the listener agrees to
    /// is the same picture whether they typed the code or tapped a link — and this is
    /// what carries the picture from the first step to the second, across a sheet
    /// boundary. Nil once it has been shown.
    var pendingPreview: PartyPreview?

    /// The signed-in account's face, for the landing page and the join sheet.
    private(set) var avatarUrl: String?

    /// The binding to this device's player.
    ///
    /// Held here rather than started by each view, because membership is what starts
    /// it and membership is not a view's business: a party that ended because the
    /// screen was dismissed would be the worst of both features.
    @ObservationIgnored private var playerBinding: PartySync?

    /// Whether a server has been resolved and answered.
    var serverAnswered: Bool {
        guard let server else { return false }
        return server.connection is ServerConnectionCustomOnline
            || server.connection is ServerConnectionDefaultOnline
    }

    /// Install a state directly, for a check that needs a party that does not exist.
    ///
    /// Narrow on purpose. The real state arrives through [install]'s callback, and
    /// every screen reads it from there; this exists so a check can put the screen in
    /// a state a real server is slow to produce — a full party, a refused one, an
    /// unmeasured clock — without waiting for one.
    ///
    /// The latch matters and is the whole reason this is a method rather than a plain
    /// property write. A screen's `.task` calls `syncFromCoordinator()` when it
    /// appears, which is right in the app and wrong here: it would read the real
    /// coordinator — empty, because this check never joined a party — and wipe the
    /// state that was just installed. So once a state is installed this one sticks
    /// until it is replaced, and the screen renders the state the check asked for.
    func setForCheck(_ state: PartyState, code: String) {
        self.state = state
        self.checkCode = code
        self.checkStateInstalled = true
    }

    @ObservationIgnored private var checkCode = ""
    @ObservationIgnored private var checkStateInstalled = false

    /// Registered once. See `install`.
    private static var installed = false

    // MARK: - Wiring

    /// Hand the party a player to follow, or take it away with nil.
    func attach(player: PartySync?) {
        playerBinding = player
        reconcilePlayerBinding()
    }

    /// Start or stop following, to match the party.
    ///
    /// Driven by membership rather than by a frame, and checked on every publish,
    /// because a session ends in three ways — the listener leaves, the server sends a
    /// `bye`, and the process starts — and only the first two of those are visible
    /// from here.
    private func reconcilePlayerBinding() {
        if PartyCoordinator.shared.membership != nil {
            playerBinding?.start()
        } else {
            playerBinding?.stop()
        }
    }

    /// Attach the store to the coordinator, once per process.
    ///
    /// The platform pieces the coordinator cannot supply for itself — the monotonic
    /// clock, and somewhere to push state — are set here rather than in the app's
    /// launch task, so that nothing which reaches the coordinator before this runs
    /// can read a clock of zero and believe it.
    static func install() {
        guard !installed else { return }
        installed = true
        PartyCoordinator.shared.localNowMs = { KotlinLong(value: PartySocket.localNowMs()) }
        PartyCoordinator.shared.onStateChanged = { newState in
            // The socket already runs off the main thread, so this is where the hop
            // belongs rather than a `Task` per frame in the bridge.
            Task { @MainActor in
                shared.state = newState
                shared.reconcilePlayerBinding()
            }
        }
        shared.syncFromCoordinator()
    }

    static let shared = PartyStore()

    /// Pull everything the coordinator holds, for a screen that has just appeared.
    func syncFromCoordinator() {
        if checkStateInstalled { return }
        state = PartyCoordinator.shared.session.current
        if let value = PartyCoordinator.shared.server.value as? ServerChoice { server = value }
        if let value = PartyCoordinator.shared.busy.value as? Bool { busy = value }
        avatarUrl = PartyAccountCache.avatarUrl
        reconcilePlayerBinding()
    }

    /// Told by the app when the signed-in account changes.
    func accountChanged() {
        let account = PartyAccountCache.account
        avatarUrl = account?.avatarUrl
        AppSettings.shared.setPartyAccount(
            value: account.map {
                PartyAccount(name: $0.name, email: $0.email, avatarUrl: $0.avatarUrl)
            }
        )
    }

    // MARK: - Reading

    /// Where the party is right now, on this device's clock.
    ///
    /// Recomputed on read rather than held, because it is a function of the clock
    /// and the last anchor: hold it and it goes stale between the frames that would
    /// refresh it, and two devices a second apart would show two numbers.
    var partyPositionMs: Int64? {
        let session = PartyCoordinator.shared.session
        let playback = session.current.playback
        guard session.current.clockSynced else { return nil }
        return session.correctedPosition(playback: playback, localNowMs: PartySocket.localNowMs())
    }

    /// The address this device will dial, or empty when none has been named.
    ///
    /// The build's own default is deliberately not shown: naming a party server in a
    /// build couples every install on it to one address's uptime, so the app asks
    /// the listener for theirs and says so rather than displaying a server the
    /// listener never chose.
    var hasServer: Bool { !PartyCoordinator.shared.defaultServer().isEmpty }

    /// The party code, or empty when this device is not in one.
    ///
    /// Read off the session rather than the membership, because the code is what the
    /// party calls itself and it stays the same for as long as this device is in it —
    /// whereas the membership is a credential that is dropped the moment the session
    /// ends, and a code that vanished at the same moment would take the share sheet's
    /// contents with it.
    var code: String {
        let live = PartyCoordinator.shared.session.code
        return live.isEmpty ? checkCode : live
    }

    var inParty: Bool { state.inParty }

    var isHost: Bool { state.isHost }

    /// Whether a frame has arrived, as opposed to merely having joined.
    ///
    /// The one distinction the screen draws: before the welcome there is no party to
    /// describe, so everything party-shaped is still empty and saying "reconnecting"
    /// would be describing a socket that has not had its first chance yet.
    var isLive: Bool { state.connection == PartyConnection.live }

    /// The signed-in account's name, for the join sheet's default.
    var accountName: String { PartyAccountCache.account?.name ?? "" }

    /// What to put in the nickname field, and the default for a create or join.
    ///
    /// The stored nickname wins over the account's name, because a listener who has
    /// chosen what to be called in a party means it every time rather than once.
    var nickname: String {
        let stored = PlatformSettings.shared.getString(key: "listen_together_nickname", default: "")
        return stored.isEmpty ? accountName : stored
    }

    func setNickname(_ value: String) {
        AppSettings.shared.setListenTogetherNickname(value: value)
    }

    /// The shareable link for the party this device is in.
    var inviteLink: String? { PartyCoordinator.shared.inviteLink() }

    // MARK: - The server

    /// The listener's own address, or empty. Never the build's default.
    var configuredServer: String {
        PlatformSettings.shared.getString(key: "listen_together_server", default: "")
    }

    func setConfiguredServer(_ value: String) {
        AppSettings.shared.setListenTogetherServer(value: value)
    }

    /// Whether an address is usable, and what is wrong with it if not.
    func serverProblem(_ raw: String) -> String? { PartyCoordinator.shared.serverProblem(raw: raw) }

    func resolveServer() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            PartyCoordinator.shared.resolveServer { _ in
                Task { @MainActor in
                    self.syncFromCoordinator()
                    continuation.resume()
                }
            }
        }
    }

    // MARK: - Joining and leaving

    func create(nickname: String, autoplay: Bool) async throws {
        setNickname(nickname)
        do {
            _ = try await createMembership(nickname: nickname, autoplay: autoplay)
            failure = nil
        } catch {
            failure = Self.describe(error)
            throw error
        }
    }

    func join(code: String, nickname: String) async throws {
        setNickname(nickname)
        do {
            _ = try await joinMembership(code: code, nickname: nickname)
            failure = nil
        } catch {
            failure = Self.describe(error)
            throw error
        }
    }

    func joinInvite(link: String, nickname: String) async throws {
        setNickname(nickname)
        do {
            _ = try await joinInviteMembership(link: link, nickname: nickname)
            failure = nil
        } catch {
            failure = Self.describe(error)
            throw error
        }
    }

    /// Look a party up without joining it.
    ///
    /// Both doors in — a tapped link and six characters typed — come through here, so
    /// what the listener agrees to is the same picture either way.
    @discardableResult
    func preview(code: String) async throws -> PartyPreview {
        do {
            let value = try await previewParty(code: code)
            failure = nil
            pendingPreview = value
            return value
        } catch {
            failure = Self.describe(error)
            pendingPreview = nil
            throw error
        }
    }

    func leave() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            PartyCoordinator.shared.leave { _ in
                Task { @MainActor in
                    self.syncFromCoordinator()
                    continuation.resume()
                }
            }
        }
        failure = nil
    }

    // MARK: - Controls

    func play() { PartyCoordinator.shared.play() }
    func pause() { PartyCoordinator.shared.pause() }
    func next() { PartyCoordinator.shared.next() }
    func previous() { PartyCoordinator.shared.previous() }
    func seek(toMs ms: Int64) { PartyCoordinator.shared.seek(positionMs: ms) }
    func setMaxMembers(_ count: Int32) { PartyCoordinator.shared.setMaxMembers(count: count) }
    func setHostOnlyControl(_ on: Bool) { PartyCoordinator.shared.setHostOnlyControl(enabled: on) }
    func kick(_ memberId: String) { PartyCoordinator.shared.kick(memberId: memberId) }
    func addToPartyQueue(_ entry: QueueEntry) { PartyCoordinator.shared.queueAdd(tracks: [entry.asPartyTrack()], playNext: false) }
    func removeFromPartyQueue(_ videoId: String) { PartyCoordinator.shared.queueRemove(videoId: videoId) }

    /**
     * Put a track in the party's running order, and tell the party it is now playing.
     *
     * Two frames and in this order, because they are two different decisions and the
     * order is what makes it sound right. `setTrack` is what every device loads *now*
     * — which is what "play this now" means to everybody, including this device — and
     * `queueAdd` is what the party will move on to afterwards. Adding to the queue
     * first and starting the track second would leave the party a second track
     * further on than the song everybody is hearing, and the drift judge would spend
     * the rest of the song pulling everybody back to it.
     *
     * A device that cannot control sends neither and says so, rather than appearing
     * to have done it: the party is either unlocked or the host has taken it over,
     * and both of those are things the listener can see and act on.
     *
     * @return whether the party accepted it
     */
    @discardableResult
    func playInParty(_ entry: QueueEntry) -> Bool {
        let track = entry.asPartyTrack()
        guard PartyCoordinator.shared.setTrack(track: track) else { return false }
        PartyCoordinator.shared.queueAdd(tracks: [track], playNext: false)
        return true
    }

    // MARK: - Errors

    /// A sentence to show, from whatever came back.
    ///
    /// The server's own message when it sent one, because it is the only party that
    /// knows why it said no; otherwise a plain statement of what failed, never the
    /// raw error — which on a network failure is a URL, a host name and a stack of
    /// framework text, and a party server's address is not something to put in front
    /// of a listener.
    static func describe(_ error: Error) -> String {
        let ns = error as NSError
        if ns.domain == "KotlinException" {
            let said = ns.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            if !said.isEmpty { return said }
        }
        if let url = ns.userInfo[NSURLErrorFailingURLErrorKey] as? URL {
            return "Couldn’t reach the party server at \(url.host() ?? "that address")."
        }
        return "Couldn’t reach the party server."
    }
}

// MARK: - Bridging the suspending calls

/// Kotlin suspend functions arrive in Swift as completion handlers, and a party call
/// is awaited from a view rather than from a callback. These three keep the
/// continuation in one place instead of at every call site, and are the reason the
/// store's methods above read as ordinary `async` ones.
///
/// Each resumes exactly once and never resumes with a failure: the caller catches, and
/// `describe` is given the error to turn into a sentence.

private func createMembership(nickname: String, autoplay: Bool) async throws -> PartyMembership {
    try await withCheckedThrowingContinuation { continuation in
        PartyCoordinator.shared.create(nickname: nickname, autoplay: autoplay) { value, error in
            if let error { continuation.resume(throwing: error) }
            else if let value { continuation.resume(returning: value) }
            else { continuation.resume(throwing: PartyStoreError.noValue) }
        }
    }
}

private func joinMembership(code: String, nickname: String) async throws -> PartyMembership {
    try await withCheckedThrowingContinuation { continuation in
        PartyCoordinator.shared.join(code: code, nickname: nickname) { value, error in
            if let error { continuation.resume(throwing: error) }
            else if let value { continuation.resume(returning: value) }
            else { continuation.resume(throwing: PartyStoreError.noValue) }
        }
    }
}

private func joinInviteMembership(link: String, nickname: String) async throws -> PartyMembership {
    try await withCheckedThrowingContinuation { continuation in
        PartyCoordinator.shared.joinInvite(link: link, nickname: nickname) { value, error in
            if let error { continuation.resume(throwing: error) }
            else if let value { continuation.resume(returning: value) }
            else { continuation.resume(throwing: PartyStoreError.noValue) }
        }
    }
}

private func previewParty(code: String) async throws -> PartyPreview {
    try await withCheckedThrowingContinuation { continuation in
        PartyCoordinator.shared.preview(code: code) { value, error in
            if let error { continuation.resume(throwing: error) }
            else if let value { continuation.resume(returning: value) }
            else { continuation.resume(throwing: PartyStoreError.noValue) }
        }
    }
}

enum PartyStoreError: Error {
    /// A call that reported neither a value nor a reason.
    ///
    /// Its own case rather than a fabricated error, so it can never be mistaken for
    /// something the server said.
    case noValue
}

// MARK: - The account, and the queue

/// The signed-in account, kept in one place because two features now want it and
/// neither should own it.
enum PartyAccountCache {
    private static var stored: PartyAccountCacheValue?

    struct PartyAccountCacheValue {
        let name: String
        let email: String
        let avatarUrl: String?
    }

    static var account: PartyAccountCacheValue? { stored }

    static var avatarUrl: String? { stored?.avatarUrl }

    static func update(name: String?, email: String?, avatarUrl: String?) {
        guard let name, !name.isEmpty else {
            stored = nil
            return
        }
        stored = PartyAccountCacheValue(
            name: name,
            email: email ?? "",
            avatarUrl: avatarUrl.flatMap { $0.hasPrefix("http") ? $0 : nil }
        )
    }
}

extension QueueEntry {
    /// This queue entry as the party describes a track.
    ///
    /// `PartyTrack` is deliberately not `Song`: a party shares *which* track and
    /// where the playhead is, never how a device gets the audio. Two people in a party
    /// can be on entirely different sources and still be in the same place in the
    /// same song, and this is what guarantees it — only the identity and the labels
    /// cross.
    func asPartyTrack() -> PartyTrack {
        PartyTrack(
            videoId: videoId ?? id,
            title: title,
            artist: artist,
            thumbnailUrl: thumbnailUrl,
            durationMs: durationSeconds > 0 ? KotlinLong(value: Int64(durationSeconds * 1000)) : nil,
            fromAutoplay: fromAutoplay
        )
    }

    /// A party track as something this device can play.
    ///
    /// The inverse of `asPartyTrack`, and needed because a queue row arrives as the
    /// party's idea of a track while the player only speaks `QueueEntry`. The source
    /// is `yt:` for the same reason the party's own track carries a video id: this
    /// device resolves it through its own sources, exactly as it would any other song
    /// somebody handed it.
    static func asPartyTrack(_ track: PartyTrack) -> QueueEntry {
        QueueEntry(
            id: track.videoId,
            title: track.title,
            artist: track.artist,
            source: "yt:" + track.videoId,
            thumbnailUrl: track.thumbnailUrl,
            durationText: nil,
            albumName: nil,
            artworkData: nil,
            isLocal: false,
            fromAutoplay: track.fromAutoplay
        )
    }
}
