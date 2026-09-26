import SwiftUI
import BitChordShared

/// Who is listening, from inside the player.
///
/// Upstream's `ui/player/ListenTogetherMembersSheet.kt`, which is a drawer over the
/// bottom of the player rather than a screen of its own. The reason it exists is
/// worth keeping: a listener who is *already playing* and wants to know who else is
/// here should not have to go and find the Listen Together settings page to find out.
///
/// Two things it deliberately does not have:
///
/// - **A create or join button.** There is nothing to create or join once there is a
///   party, so the sheet is a place to look and a place to leave. Starting a party is
///   the screen's job.
/// - **The party code as the headline.** The code is what you *send*; this is what
///   you *see*, and leading with six characters would answer neither question. The
///   code is a row at the bottom, next to copying it, where it belongs.
struct PartyMembersSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(PartyStore.self) private var party
    @Environment(AppModel.self) private var appModel

    var body: some View {
        NavigationStack {
            Form {
                Section {
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
                            }
                        )
                    }
                    if party.state.members.isEmpty {
                        Text("Nobody else is here yet.")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text(PartyCopy.listeningHeader(
                        members: party.state.members.count,
                        maxMembers: Int(party.state.maxMembers)
                    ))
                } footer: {
                    Text(PartyCopy.listeningFooter(maxMembers: Int(party.state.maxMembers)))
                }

                if let track = party.state.playback.track?.nonEmptyTitle {
                    Section("Now playing") {
                        LabeledContent(track) {
                            Text(PartyCopy.connectionLine(
                                connection: party.state.connection,
                                clockSynced: party.state.clockSynced,
                                roundTripMs: party.state.roundTripMs
                            ))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                        }
                    }
                }

                Section {
                    Button {
                        dismiss()
                        appModel.listenTogetherPresented = true
                    } label: {
                        Label("Manage party", systemImage: "slider.horizontal.3")
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(PartyMembersSheet.title(for: party))
            #if os(macOS)
            .frame(minWidth: 420, idealWidth: 480)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Leave", role: .destructive) {
                        Task {
                            await party.leave()
                            dismiss()
                        }
                    }
                }
            }
        }
    }

    /**
     * The host's first name, so the sheet says whose jam this is.
     *
     * First name rather than the whole display name because a member list is narrow
     * and a party nickname is often longer than the space; and a fallback rather than
     * a blank, because "’s Jam" is worse than not saying whose it is.
     */
    static func title(for party: PartyStore) -> String {
        let host = party.state.members.first { $0.isHost }?.name ?? ""
        let first = host.split(separator: " ").first.map(String.init) ?? ""
        return first.isEmpty ? "Listening together" : "\(first)’s Jam"
    }
}

private extension PartyTrack {
    /// The title, or nothing — a row with an empty label is a row nobody can read.
    var nonEmptyTitle: String? { title.nonEmpty }
}
