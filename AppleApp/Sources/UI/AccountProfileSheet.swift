import SwiftUI

/// Upstream `AccountProfileSelector`: which YouTube identity to listen as.
///
/// ## Why this is a list and not just a menu
///
/// A Google account can own several channels, and the difference between them is
/// not cosmetic — a brand channel has its own library, its own history and its
/// own scrobbles. So the choice is worth more than one tap on an avatar, and a
/// popover that only ever shows the current one hides the alternatives.
///
/// ## Why the avatar swipes
///
/// Upstream swipes between profiles on the avatar itself. Kept, because the
/// avatar is already the thing you look at to answer "which account is this",
/// and a gesture there costs no space on a page that has none. It stops at both
/// ends rather than wrapping — see `adjacentProfile` in the shared module for
/// why a swipe past the last channel should do nothing rather than teleport the
/// listener to their oldest.
struct AccountProfileSheet: View {
    @Environment(AuthController.self) private var auth
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    /// The account this sheet is showing, or nil for "whichever is selected".
    /// Set by the header avatar so a tap on a *non*-selected account's avatar
    /// still opens the list rather than silently switching.
    let scopedAccountId: String?

    init(scopedAccountId: String? = nil) {
        self.scopedAccountId = scopedAccountId
    }

    private var accounts: [AccountSummary] {
        guard scopedAccountId != nil else { return auth.accounts }
        // A scoped sheet still shows every account — the point is to be able to
        // change which one — but starts on the one that was tapped.
        return auth.accounts
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(accounts) { account in
                    Section {
                        if account.profiles.isEmpty {
                            // An account always has at least one identity in the
                            // real world, so an empty list is a half-read record
                            // rather than a state to offer a choice within.
                            Text("No YouTube channels read for this account yet.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(account.profiles) { profile in
                                row(account: account, profile: profile)
                            }
                        }
                    } header: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(account.displayName)
                            if !account.email.isEmpty {
                                Text(account.email)
                                    .font(.caption)
                                    .textCase(nil)
                            }
                        }
                    } footer: {
                        if account.id == auth.listeningAs?.id {
                            Text("Listening as this account. Signing out removes it and its cookie.")
                        }
                    }
                }
            }
            .navigationTitle("Listen As")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Settings") {
                        dismiss()
                        Task { @MainActor in appModel.settingsPresented = true }
                    }
                }
            }
        }
        #if os(iOS)
        // See `LyricsOffsetSheet`: upstream's player sheets are bottom drawers
        // with a grab handle, and the platform's own indicator is the handle.
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        #endif
    }

    private func row(account: AccountSummary, profile: AccountProfile) -> some View {
        let selected = auth.listeningAs?.id == account.id
            && auth.listeningAs?.activeProfileId == profile.id
        return Button {
            auth.select(accountId: account.id, profileId: profile.id)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                Avatar(url: profile.avatar, name: profile.name, side: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.name)
                        .foregroundStyle(.primary)
                    if !profile.handle.isEmpty {
                        Text(profile.handle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if selected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                        .accessibilityLabel("Listening as this channel")
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The upstream account control in a screen's visible top bar. It is hosted
/// by each tab's NavigationStack, because a toolbar on the parent TabView is
/// not reliably shown with nested navigation stacks on iPhone.
struct TopBarAccountButton: View {
    @Environment(AuthController.self) private var auth
    @Environment(AppModel.self) private var appModel
    @State private var showingProfiles = false

    var body: some View {
        Button {
            if auth.signedIn && !auth.accounts.isEmpty {
                showingProfiles = true
            } else {
                appModel.settingsPresented = true
            }
        } label: {
            Group {
                if auth.signedIn {
                    Avatar(
                        url: auth.accountPhotoUrl,
                        name: auth.accountName ?? "Account",
                        side: 32
                    )
                } else {
                    Image(systemName: "person.fill")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                        .background(.quaternary, in: Circle())
                }
            }
            .overlay(Circle().strokeBorder(.primary.opacity(0.12), lineWidth: 1))
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(auth.signedIn ? "Account and Settings" : "Sign in and Settings")
        .gesture(
            DragGesture(minimumDistance: 28).onEnded { value in
                guard auth.signedIn,
                      abs(value.translation.height) > abs(value.translation.width)
                else { return }
                auth.stepProfile(forward: value.translation.height > 0)
            }
        )
        .sheet(isPresented: $showingProfiles) {
            AccountProfileSheet(scopedAccountId: auth.listeningAs?.id)
        }
    }
}

/// An account's avatar, which opens the selector and steps between identities on
/// a swipe. The compact control upstream puts on every visible account avatar.
struct AccountAvatarButton: View {
    @Environment(AuthController.self) private var auth
    @State private var showingSheet = false
    /// How far the last swipe went, so the gesture can be undone by swiping
    /// back without the list having to be consulted.
    @State private var swipeHint: Int = 0

    private var profile: AccountProfile? { auth.listeningAs?.activeProfile }

    var body: some View {
        Button {
            showingSheet = true
        } label: {
            Avatar(url: profile?.avatar, name: profile?.name ?? "Account", side: 34)
                .overlay(alignment: .bottomTrailing) {
                    // A small mark rather than a chevron: this opens a list, and a
                    // chevron here reads as "go deeper into the account", which is
                    // a different thing.
                    Image(systemName: "person.crop.circle.badge.checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white, .black.opacity(0.55))
                        .offset(x: 2, y: 2)
                }
        }
        .buttonStyle(.plain)
        .disabled(!auth.signedIn || auth.listeningAs == nil)
        .opacity(auth.signedIn && auth.listeningAs != nil ? 1 : 0.4)
        .accessibilityLabel(auth.listeningAs.map { "Listening as \($0.activeProfile?.name ?? $0.displayName)" } ?? "Not signed in")
        .accessibilityHint("Choose which YouTube channel to listen as")
        .sheet(isPresented: $showingSheet) {
            AccountProfileSheet(scopedAccountId: auth.listeningAs?.id)
        }
        .gesture(
            DragGesture(minimumDistance: 24)
                .onEnded { value in
                    guard abs(value.translation.width) > abs(value.translation.height) else { return }
                    // Right is "back", which is the direction a list reads
                    // backwards in, so forward is a leftward swipe.
                    auth.stepProfile(forward: value.translation.width < 0)
                }
        )
    }
}

/// A round image that falls back to a monogram, so an account without a picture
/// is still distinguishable from one with it.
struct Avatar: View {
    let url: String?
    let name: String
    let side: CGFloat

    var body: some View {
        Group {
            if let url, let address = URL(string: url) {
                AsyncImage(url: address) { phase in
                    if case .success(let image) = phase {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        monogram
                    }
                }
            } else {
                monogram
            }
        }
        .frame(width: side, height: side)
        .clipShape(Circle())
    }

    private var monogram: some View {
        Text(name.trimmingCharacters(in: .whitespaces).prefix(1).uppercased())
            .font(.system(size: side * 0.42, weight: .semibold))
            .foregroundStyle(.white.opacity(0.9))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.white.opacity(0.14))
    }
}
