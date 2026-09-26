import SwiftUI
import BitChordShared
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Listen together: one party, one code, up to ten devices.
///
/// # The shape, and where it comes from
///
/// Upstream's `ui/screens/ListenTogetherScreen.kt`, rebuilt on `Form` rather than a
/// hand-rolled column of cards. That is not a cosmetic swap: upstream draws its own
/// `SettingsGroup`/`SettingsRow` primitives with their own insets, and a port that
/// re-draws those in SwiftUI would be re-implementing the platform's list to look
/// like another platform's list. The structure, the copy and the ordering are
/// upstream's; the chrome is the one the rest of this app already uses.
///
/// Three things the ordering is load-bearing for, from upstream's comments:
///
/// - **The party code is read aloud.** Six cells, and an alphabet without O and I, so
///   an "oh" is always a zero. That is why the code is a row of its own and not a
///   subtitle.
/// - **The address is last and empty by default.** Nobody starting a party needs to
///   think about a server, so this is where somebody running their own comes looking
///   rather than the first thing everybody reads past. And it is locked while in a
///   party: changing it under a live membership would leave this device holding a
///   token for a server it no longer talks to.
/// - **The activity log is inside the party branch.** A log of who skipped what is a
///   thing to look back over while a party is running; on the page that offers to
///   start one it is a list of somebody else's evening, under a button nobody has
///   pressed yet.
struct ListenTogetherView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ToastCenter.self) private var toast
    @Environment(PartyStore.self) private var party
    @Environment(AppModel.self) private var appModel

    /// Which sheet is up, if any.
    ///
    /// One optional value rather than a boolean each: they are alternatives, and a set
    /// of flags that must not both be true is a bug waiting for the one path that sets
    /// the second without clearing the first.
    @State private var sheet: PartySheetCase?
    /// The party a join is about, once it has been looked up.
    @State private var joining: PartyPreview?
    /// The server that preview came from, when the invite named one.
    @State private var joiningServer: String?
    /// Set by a link, so the code cell is pre-filled rather than the sheet opening blank.
    @State private var codeFromLink: String?
    @State private var serverEditorPresented = false

    /// How long the newly made party sits on screen before the invite rises over it.
    ///
    /// Long enough to be a page that was arrived at rather than a frame that flashed
    /// past, short enough that nobody has started reading the member list yet. From
    /// upstream.
    private static let inviteDelay: Duration = .seconds(1)

    var body: some View {
        Form {
            if party.inParty {
                codeSection
                nowPlayingSection
                transportSection
                queueSection
                listeningSection
                leaveSection
                let entries = party.state.activities
                if !entries.isEmpty {
                    activitySection(entries)
                }
            } else {
                landingSection
            }
            if sheet == nil, let message = party.failure ?? party.state.error?.message {
                // Only when nothing is covering it. A sheet is a drawer over the
                // bottom of the screen, and every failure it can produce is already
                // shown inside it — printing the same line down here as well means
                // printing it where it cannot be read.
                Section {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            }
            serverSection
        }
        .formStyle(.grouped)
        .navigationTitle("Listen together")
        #if os(macOS)
        .frame(minWidth: 520, idealWidth: 600)
        #endif
        .task {
            party.syncFromCoordinator()
            // A link that arrived while this screen was closed. A link tap is already
            // an explicit request to join, so it does not stop to ask for a code
            // first — but it still goes through the same confirmation a typed code
            // does.
            if let invite = appModel.pendingPartyInvite {
                appModel.pendingPartyInvite = nil
                arrive(withInvite: invite)
            } else if let codeFromLink, !codeFromLink.isEmpty {
                self.codeFromLink = nil
                arrive(code: codeFromLink)
            }
        }
        .sheet(item: $sheet) { item in
            switch item {
            case .create:
                CreatePartySheet { created() }
            case .joinCode:
                JoinPartySheet(initialCode: joining?.code ?? "")
            case .confirm:
                JoinConfirmSheet(preview: joining, server: joiningServer)
            case .invite:
                InviteSheet()
            }
        }
        .sheet(isPresented: $serverEditorPresented) { PartyServerEditor() }
        .onChange(of: party.pendingPreview?.code) { _, code in
            // The code sheet has looked a party up and handed it back. Both doors in —
            // a typed code and a tapped link — come through the same lookup, so what
            // the listener is asked to agree to is the same picture either way.
            guard let code, let preview = party.pendingPreview else { return }
            joining = preview
            joiningServer = nil
            sheet = .confirm
            _ = code
        }
    }

    /// A party was just made, so the invite rises over the page.
    ///
    /// Three separate things, and the order is the whole point. The create sheet is
    /// dismissed *and removed* rather than swapped for the invite's contents under a
    /// drawer that never moved, because a swap is the one thing that does not read as
    /// a new sheet arriving. Then a beat with nothing over the page at all: what is
    /// underneath has just become a different page — a code, a member list — and an
    /// invite that rises immediately means nobody ever sees that it did. Only then the
    /// invite, from a fresh presentation, so it slides.
    private func created() {
        Task {
            try? await Task.sleep(for: Self.inviteDelay)
            // A second is long enough to have gone and opened something else in, and
            // being interrupted by a sheet nobody asked for is worse than not being
            // offered the link at all.
            guard sheet == nil else { return }
            sheet = .invite
        }
    }

    // MARK: - Not in a party

    private var landingSection: some View {
        Section {
            PartyLanding(
                avatarUrl: party.avatarUrl,
                enabled: party.hasServer && !party.busy,
                serverMissing: !party.hasServer,
                busy: party.busy,
                onCreate: { sheet = .create },
                onJoin: { sheet = .joinCode }
            )
        }
    }

    // MARK: - The code

    private var codeSection: some View {
        Section {
            VStack(spacing: 10) {
                Text(party.code)
                    .font(.system(size: 32, weight: .semibold, design: .monospaced))
                    .tracking(6)
                    .textSelection(.enabled)
                    .padding(.vertical, 8)
                    .accessibilityLabel("Party code")
                    .accessibilityValue(party.code)
            }
            .frame(maxWidth: .infinity)
            .listRowBackground(Color.clear)

            Button {
                copyCode()
            } label: {
                Label("Copy code", systemImage: "doc.on.doc")
            }

            ShareLink(
                item: shareText,
                subject: Text("Listen together"),
                message: Text("Listen with me on BitChord — party code \(party.code)")
            ) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
        } header: {
            Text("Party code")
        } footer: {
            Text(PartyCopy.codeFooter)
        }
    }

    /// What the Share button sends.
    ///
    /// The link first and the code in words after it, because the link only works for
    /// people who already have the app and the code works for everybody. A party
    /// server's address is not repeated here beyond what the link needs to carry.
    private var shareText: String {
        guard let link = party.inviteLink else { return party.code }
        return "\(link)\n\nListen with me on BitChord — party code \(party.code)"
    }

    private func copyCode() {
        #if os(iOS)
        UIPasteboard.general.string = party.code
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(party.code, forType: .string)
        #endif
        toast.show("Copied \(party.code)")
    }

    // MARK: - What the party is playing

    private var nowPlayingSection: some View {
        Section("Now playing") {
            PartyNowPlayingRow(
                title: PartyCopy.nowPlayingTitle(party.state.playback.track),
                detail: PartyCopy.nowPlayingDetail(
                    track: party.state.playback.track,
                    positionMs: party.partyPositionMs,
                    connection: party.state.connection,
                    clockSynced: party.state.clockSynced,
                    roundTripMs: party.state.roundTripMs
                )
            )
        }
    }

    // MARK: - The transport, for everybody

    /**
     * The three controls that move a party, shown as controls and not left to the
     * player alone.
     *
     * Upstream's screen does not carry these — on Android they live in the playback
     * service's own notification and the player drawer, which is the right answer
     * there because that is where a listener already has a hand. Here the player is a
     * window that may be behind something else, so a listener who is looking at the
     * party and cannot see the player has no way to skip.
     *
     * Disabled rather than hidden when the host has taken control, because a control
     * that vanishes is a control somebody reports as broken, and the reason is right
     * there in the footer.
     */
    private var transportSection: some View {
        Section {
            HStack(spacing: 0) {
                PartyTransportButton(
                    systemImage: "backward.end.fill",
                    label: "Previous",
                    enabled: party.state.canControl,
                    action: { party.previous() }
                )
                PartyTransportButton(
                    systemImage: party.state.playback.isPlaying ? "pause.fill" : "play.fill",
                    label: PartyCopy.transportTitle(isPlaying: party.state.playback.isPlaying),
                    enabled: party.state.canControl,
                    prominent: true,
                    action: {
                        if party.state.playback.isPlaying { party.pause() } else { party.play() }
                    }
                )
                PartyTransportButton(
                    systemImage: "forward.end.fill",
                    label: "Next",
                    enabled: party.state.canControl,
                    action: { party.next() }
                )
            }
            .padding(.vertical, 4)
        } footer: {
            if party.state.controlsLocked {
                Text(PartyCopy.transportLockedFooter)
            }
        }
    }

    // MARK: - What is coming

    /**
     * The party's running order, and the one place a song is added to it.
     *
     * The landing page promises "add songs in real time", so this is where that
     * promise is kept — and it is kept *here* rather than in each device's own queue
     * because in a party there is only one queue. A listener who taps "play next"
     * somewhere else is describing a queue that nobody else can see.
     */
    private var queueSection: some View {
        Section {
            ForEach(Array(party.state.queue.items.enumerated()), id: \.element.videoId) { index, track in
                PartyQueueRow(
                    track: track,
                    position: Int(party.state.playback.queueIndex),
                    index: index,
                    isCurrent: party.state.playback.track?.videoId == track.videoId,
                    canControl: party.state.canControl,
                    onPlay: { playNow(track) },
                    onRemove: {
                        party.removeFromPartyQueue(track.videoId)
                        toast.show("Removed from the queue", kind: .info)
                    }
                )
            }
            if party.state.queue.items.isEmpty {
                Text(PartyCopy.queueEmpty)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } header: {
            let ahead = party.state.queue.items.count - max(0, Int(party.state.playback.queueIndex) + 1)
            Text(PartyCopy.queueHeader(ahead: ahead))
        }
    }

    /// Play this now, for everybody.
    private func playNow(_ track: PartyTrack) {
        guard party.state.canControl else {
            toast.show("Only the host can change the music", kind: .failure)
            return
        }
        guard party.playInParty(QueueEntry.asPartyTrack(track)) else {
            toast.show("Only the host can change the music", kind: .failure)
            return
        }
    }

    // MARK: - Who is here

    private var listeningSection: some View {
        Section {
            if party.isHost {
                partySizeRow
                Toggle(isOn: hostOnlyBinding) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(PartyCopy.hostOnlyTitle)
                        Text(PartyCopy.hostOnlySubtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            ForEach(party.state.members, id: \.memberId) { member in
                MemberRow(
                    name: member.name,
                    avatarUrl: member.avatarUrl,
                    isYou: party.state.isMe(member: member),
                    isHost: member.isHost,
                    connected: member.connected,
                    canRemove: party.isHost && !member.isHost,
                    onRemove: {
                        party.kick(member.memberId)
                        toast.show("Removed \(member.name)", kind: .info)
                    }
                )
            }
        } header: {
            Text(PartyCopy.listeningHeader(members: party.state.members.count, maxMembers: Int(party.state.maxMembers)))
        } footer: {
            Text(PartyCopy.listeningFooter(maxMembers: Int(party.state.maxMembers)))
        }
    }

    /// The capacity stepper.
    ///
    /// The floor is `max(2, current members)` rather than a flat 2, because lowering
    /// the size below the number of devices already in the party would be refused by
    /// the server and leave a host tapping a button that does nothing.
    private var partySizeRow: some View {
        let floor = max(2, Int(party.state.members.count))
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Party size")
                Text(PartyCopy.partySizeFooter)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            StepperStep(
                symbol: "minus",
                enabled: Int(party.state.maxMembers) > floor,
                action: { party.setMaxMembers(party.state.maxMembers - 1) }
            )
            Text("\(party.state.maxMembers)")
                .font(.title3.monospacedDigit())
                .frame(minWidth: 28)
                .multilineTextAlignment(.center)
            StepperStep(
                symbol: "plus",
                enabled: party.state.maxMembers < 10,
                action: { party.setMaxMembers(party.state.maxMembers + 1) }
            )
        }
        .padding(.vertical, 3)
    }

    private var hostOnlyBinding: Binding<Bool> {
        Binding(
            get: { party.state.hostOnlyControl },
            set: { party.setHostOnlyControl($0) }
        )
    }

    // MARK: - Leaving

    private var leaveSection: some View {
        Section {
            Button(role: .destructive) {
                Task {
                    await party.leave()
                    toast.show("Left the party", kind: .info)
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Leave the party")
                    Text(PartyCopy.leaveSubtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - The log

    /// What everybody in the party has done, newest first.
    ///
    /// Capped at what fits and scrollable inside the section rather than given a row
    /// each: a party that ran for three hours has a hundred lines, and a list a
    /// hundred rows long inside a form is a form nobody can get out of.
    private func activitySection(_ entries: [PartyActivity]) -> some View {
        Section {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(entries, id: \.atMs) { entry in
                        Text(PartyFormat.activityLine(entry))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 156)
            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
        } header: {
            Text("Recent activity")
        } footer: {
            Text(PartyCopy.activityFooter)
        }
    }

    // MARK: - The server

    private var serverSection: some View {
        Section {
            Button {
                serverEditorPresented = true
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("Use your own server")
                        if party.busy {
                            ProgressView().controlSize(.mini)
                        }
                    }
                    Text(party.configuredServer.nonEmpty ?? PartyCopy.serverUsingDefault)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !party.configuredServer.isEmpty, let server = party.server {
                        ServerConnectionLine(
                            connection: server.connection,
                            isChecking: party.busy
                        )
                    }
                }
            }
            .disabled(party.inParty || party.busy)
        } header: {
            Text("Party server")
        } footer: {
            // Locked while in a party, and the footer says so rather than the row
            // simply being dead: a control that is greyed for a reason nobody can see
            // is a control people report as broken.
            Text(party.inParty ? PartyCopy.serverLockedFooter : PartyCopy.serverFooter)
        }
    }

    // MARK: - The join path

    /// A link arrived while this screen was not open.
    ///
    /// The server it names is carried through to the confirmation, because the join
    /// that follows has to go to the same place the preview came from.
    func arrive(withInvite invite: String) {
        guard let parsed = JamInviteLink.shared.parseInvite(value: invite) else { return }
        arrive(code: parsed.code, server: parsed.serverUrl)
    }

    func arrive(code: String, server: String? = nil) {
        joiningServer = server
        Task { await lookUp(code: code) }
    }

    /// Look a party up and put its faces on screen, rather than joining it.
    private func lookUp(code: String) async {
        do {
            let preview = try await party.preview(code: code)
            joining = preview
            sheet = .confirm
        } catch {
            // The message is already in `party.failure`; the sheet shows it where it
            // can be read.
        }
    }
}

// MARK: - The rows

/// What the party is playing, and where its playhead is right now.
///
/// The position is recomputed on a tick rather than read out of the last frame,
/// because *that is the feature*: between server updates each device advances the
/// same anchored position on its own clock, and two devices side by side should show
/// the same number. A value that only moved when a frame arrived would prove nothing.
private struct PartyNowPlayingRow: View {
    /// The song, or the sentence that says there is not one.
    let title: String
    /// The line under it, already written by [PartyCopy].
    ///
    /// One string rather than a set of parts, because the parts are only ever shown
    /// together and a view that assembled them would be a second, untested copy of the
    /// same sentences.
    let detail: String

    @State private var tick = Date()

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "music.note")
                .font(.title3)
                .frame(width: 26)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .lineLimit(1)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
        .task {
            // Ticked rather than read once, and the tick is what makes the number
            // mean anything: between server updates each device advances the same
            // anchored position on its own clock, and two devices side by side should
            // show the same number. A value that only moved when a frame arrived would
            // prove nothing.
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                tick = Date()
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(detail)
    }
}

/// One song in the party's running order.
///
/// The row is a button, not a switch, because tapping it means "this one, now, for
/// everybody" — which is the only thing a queue row can mean once there is more than
/// one person listening. The remove button is separate and last, so the row's own tap
/// target is not interrupted by a control that does something else.
private struct PartyQueueRow: View {
    let track: PartyTrack
    let position: Int
    let index: Int
    let isCurrent: Bool
    let canControl: Bool
    let onPlay: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(url: track.thumbnailUrl, data: nil, side: 40)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            Button(action: onPlay) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(track.title.nonEmpty ?? "Unknown")
                            .font(.body)
                            .foregroundStyle(isCurrent ? Color.accentColor : Color.primary)
                            .lineLimit(1)
                        if isCurrent {
                            Image(systemName: "speaker.wave.2.fill")
                                .font(.caption2)
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    if let artist = track.artist.nonEmpty {
                        Text(artist)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canControl)
            if canControl {
                Button(role: .destructive, action: onRemove) {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Remove \(track.title.nonEmpty ?? "track") from the queue")
            }
        }
        .padding(.vertical, 2)
    }
}

/// One of the three party-wide transport controls.
private struct PartyTransportButton: View {
    let systemImage: String
    let label: String
    let enabled: Bool
    var prominent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: prominent ? 22 : 18, weight: .semibold))
                Text(label)
                    .font(.caption2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
        .accessibilityLabel(label)
    }
}

private struct MemberRow: View {
    let name: String
    let avatarUrl: String?
    let isYou: Bool
    let isHost: Bool
    let connected: Bool
    let canRemove: Bool
    let onRemove: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            PartyAvatar(url: avatarUrl, name: name, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(name).lineLimit(1)
                    if isYou { PartyBadge(text: "You") }
                }
                if !connected {
                    // Their slot is still held, so this is not "they left" — which is
                    // the difference between a member list that shrinks on its own and
                    // one that does not.
                    Text(PartyCopy.awaySubtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if isHost {
                PartyBadge(text: "Host")
            } else if canRemove {
                Button("Remove", action: onRemove)
                    .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        var parts = [name]
        if isYou { parts.append("you") }
        if isHost { parts.append("host") }
        if !connected { parts.append("away, their slot is held") }
        return parts.joined(separator: ", ")
    }
}

/// Whether the address that was typed is actually answering.
///
/// Under the address rather than in a toast, because the interesting case is the one
/// nobody is watching for: a server that answered when it was saved and has since
/// gone quiet. A toast for that would have to fire at a moment nobody asked anything,
/// so it does not fire at all — this line simply reads differently the next time the
/// page is opened.
struct ServerConnectionLine: View {
    let connection: ServerConnection
    let isChecking: Bool

    var body: some View {
        // Nothing to say for the built-in server: the row above already reads
        // "Using default server", and a second line saying the same thing is noise.
        if let label {
            HStack(spacing: 6) {
                if isChecking {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: symbol)
                        .font(.caption)
                }
                Text(label)
                    .font(.caption)
                    .lineLimit(1)
            }
            .foregroundStyle(tint)
        }
    }

    /// `ServerConnection` is a Kotlin sealed interface, so in Swift it is a protocol
    /// and each case is a class. The cases are therefore read by casting rather than
    /// by switching over cases — which is also why a new case is a compile error here
    /// only if it is also missing below, so the two are kept together deliberately.
    private var label: String? {
        if connection is ServerConnectionDefaultOnline { return nil }
        if connection is ServerConnectionUnconfigured { return nil }
        if let online = connection as? ServerConnectionCustomOnline {
            return "Connected to your server · \(online.latencyMs) ms"
        }
        if let fallback = connection as? ServerConnectionCustomFallback {
            return "Your server is unreachable · Using the default server (\(fallback.latencyMs) ms)"
        }
        if connection is ServerConnectionOffline {
            return "The party server could not be reached"
        }
        if connection is ServerConnectionChecking { return "Checking…" }
        return nil
    }

    private var symbol: String {
        if connection is ServerConnectionCustomOnline { return "checkmark.icloud.fill" }
        if connection is ServerConnectionCustomFallback { return "icloud.slash.fill" }
        if connection is ServerConnectionOffline { return "icloud.slash.fill" }
        return "icloud"
    }

    private var tint: Color {
        if connection is ServerConnectionCustomOnline { return .accentColor }
        if connection is ServerConnectionCustomFallback { return .red }
        if connection is ServerConnectionOffline { return .red }
        return .secondary
    }
}

// MARK: - Pieces

/// The sheet model. See `ListenTogetherView.sheet` for why it is one value.
enum PartySheetCase: String, Identifiable {
    case create
    case joinCode
    case confirm
    case invite

    var id: String { rawValue }
}

/// One member's face, or their initial.
struct PartyAvatar: View {
    let url: String?
    let name: String
    var size: CGFloat = 32

    var body: some View {
        ZStack {
            Circle().fill(.quaternary)
            if let url, !url.isEmpty {
                AsyncImage(url: URL(string: url)) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    initial
                }
            } else {
                initial
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay { Circle().strokeBorder(.separator.opacity(0.4), lineWidth: 0.5) }
        .accessibilityHidden(true)
    }

    private var initial: some View {
        Text(name.trimmingCharacters(in: .whitespaces).first.map(String.init)?.uppercased() ?? "?")
            .font(.system(size: size * 0.42, weight: .medium))
            .foregroundStyle(.secondary)
    }
}

struct PartyBadge: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.accentColor.opacity(0.16), in: RoundedRectangle(cornerRadius: 5))
    }
}

struct StepperStep: View {
    let symbol: String
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .foregroundStyle(enabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
    }
}

/**
 * Every sentence this screen can say, derived from state.
 *
 * ## Why the words are a function and not scattered through the views
 *
 * Because they are the part of a screen that is wrong most easily and least
 * visibly. A view that interpolates its own copy has no single place to ask "what
 * does this say when the party is full", and no way to check the answer without a
 * window — and a window is not available where this is checked, nor in a test, nor
 * in review.
 *
 * So the sentences live here, take the state and return words, and the views do
 * nothing but place them. `scripts/check-party-ui.sh` calls every one of them in
 * every state; the layout check still renders each screen, because "lays out" and
 * "says the right thing" are different failures and both matter.
 */
enum PartyCopy {

    // ---- The party itself ------------------------------------------------

    /// The shareable code, and the reminder that the alphabet is deliberate.
    static let codeFooter: String = "Read it out or send it. O and I aren’t used, so an “oh” is always a zero."

    /// What the party is playing, or that it is not playing anything.
    static func nowPlayingTitle(_ track: PartyTrack?) -> String {
        guard let title = track?.title.nonEmpty else { return "Nothing playing yet" }
        return title
    }

    /// The line under the song: what and where, and how well in step this device is.
    static func nowPlayingDetail(
        track: PartyTrack?,
        positionMs: Int64?,
        connection: PartyConnection,
        clockSynced: Bool,
        roundTripMs: Int64
    ) -> String {
        let position = PartyFormat.elapsed(ms: positionMs ?? 0)
        // A `KotlinLong?` is a boxed nullable, so it is unwrapped by hand rather than
        // with `?? 0` — which would try to make an `Int64` out of a `KotlinLong`.
        let duration = PartyFormat.elapsed(ms: track?.durationMs?.int64Value ?? 0)
        var parts: [String] = []
        if let artist = track?.artist.nonEmpty {
            parts.append(artist)
        }
        parts.append("\(position) / \(duration)")
        parts.append(connectionLine(connection: connection, clockSynced: clockSynced, roundTripMs: roundTripMs))
        return parts.joined(separator: " · ")
    }

    /**
     * How well this device is in step with the party.
     *
     * Three states, and they mean three different things. Before a frame has landed
     * there is no party to be out of step with, so it says reconnecting rather than
     * claiming a problem. Live but unmeasured is its own sentence, because the
     * playhead is a guess for those few seconds and saying "in sync" then would be a
     * claim nothing supports.
     */
    static func connectionLine(
        connection: PartyConnection,
        clockSynced: Bool,
        roundTripMs: Int64
    ) -> String {
        if connection != PartyConnection.live { return "Reconnecting…" }
        return clockSynced ? "In sync · \(roundTripMs) ms round trip" : "Measuring the clock…"
    }

    /// How many are listening, out of how many can be.
    static func listeningHeader(members: Int, maxMembers: Int) -> String {
        "Listening · \(members) of \(maxMembers)"
    }

    static func listeningFooter(maxMembers: Int) -> String {
        "A party holds \(maxMembers) devices. Anyone in it can control the music."
    }

    /// What a member who is not connected is doing.
    ///
    /// Says their slot is held rather than that they have gone, because the second is
    /// a lie: the server keeps the slot, and a list that shrinks on its own is a list
    /// that adds somebody else's device without asking.
    static let awaySubtitle: String = "Away — their slot is held"

    /// The host's own controls.
    static let partySizeFooter: String = "Only you can change capacity or remove listeners"
    static let hostOnlyTitle: String = "Only I control the music"
    static let hostOnlySubtitle: String = "Everyone else listens along and can pause on their own device"

    /// The transport, and why it might be unavailable.
    static let transportLockedFooter = "The host has taken control of the music. You can still pause on your own device."
    static func transportTitle(isPlaying: Bool) -> String {
        isPlaying ? "Pause for everyone" : "Play for everyone"
    }

    /// Up next.
    static func queueHeader(ahead: Int) -> String {
        ahead > 0 ? "Up next · \(ahead)" : "Up next"
    }
    static let queueEmpty: String = "Nothing queued. Anything you play goes here for everyone."

    /// The log.
    static let activityFooter: String = "This session only · latest first"

    /// Leaving.
    static let leaveSubtitle: String = "The others carry on listening"

    // ---- Not in a party ---------------------------------------------------

    static let landingTitle: String = "Start a party"
    static let landingSubtitle: String = "Because music sounds better together. Invite friends to listen and add songs in real time, wherever they are."
    static let landingNoServer: String = "Set a party server first — there isn’t one built in."

    // ---- The server -------------------------------------------------------

    static let serverUsingDefault: String = "Using default server"
    static let serverFooter = "Leave this empty to use the default server. If you run your own copy, everyone in the party has to be pointed at the same one."

    /// Why the address is locked, which is not obvious from a greyed row.
    static let serverLockedFooter = "Locked while you are in a party. Leaving a party you had already given the address to would leave this device holding a token for a server it no longer talks to."

    // ---- The sheets -------------------------------------------------------

    static let createSubtitle = "Pick how you’ll show up"
    static let createNicknamePlaceholder = "Nickname for this party"
    static let createSizeSubtitle = "Choose 2–10 listeners"
    static let joinCodeHint = "Six letters or digits"
    static let joinPreviewFooter = "People in the party will see your name and profile picture."
    static let inviteFooter = "Anyone with BitChord can open this link. The party server travels with it, so they do not need to have set one up."

    /// The question the confirm sheet asks.
    ///
    /// Falls back to "this party" rather than to a blank name, because "Join ’s
    /// party?" is worse than not naming them.
    static func joinQuestion(hostName: String) -> String {
        let host = hostName.trimmingCharacters(in: .whitespacesAndNewlines)
        return host.isEmpty ? "Join this party?" : "Join \(host)’s party?"
    }
}

enum PartyFormat {
    /// `m:ss`, which is what a duration is read as everywhere else in the app.
    static func elapsed(ms: Int64) -> String {
        let total = max(0, ms / 1000)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// The wall-clock time an activity happened, for the log line.
    static func clock(_ atMs: Int64) -> String {
        let date = Date(timeIntervalSince1970: Double(atMs) / 1000)
        return date.formatted(date: .omitted, time: .standard)
    }

    /// One line of the log.
    ///
    /// The server writes the sentence — `Changed the song to "…"`, `Paused playback` —
    /// and it is the only party that knows what it just did, so it is used verbatim.
    /// The action name is the fallback for a frame with no detail, which is what a
    /// control nobody wrote a phrase for arrives as.
    static func activityLine(_ entry: PartyActivity) -> String {
        let what = entry.detail.trimmingCharacters(in: .whitespacesAndNewlines)
        return "[\(clock(entry.atMs))] \(entry.by): \(what.isEmpty ? entry.action : what)"
    }
}

extension String {
    /// The string, or nil when it is only whitespace — for subtitles where a blank
    /// row's worth of space is worse than no row.
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
