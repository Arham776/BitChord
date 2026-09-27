import SwiftUI
import BitChordShared

/// Apple equivalent of upstream `SongActionsSheet` / `BrowseActionsSheet`:
/// context menu on both platforms, swipe actions on iOS.
struct SongActionButtons: View {
    let entry: QueueEntry
    var playlistBrowseId: String? = nil
    var setVideoId: String? = nil
    var playlistOwned: Bool = false
    var showSleepTimer: Bool = true
    var showDebugLog: Bool = false
    @Environment(PlaybackController.self) private var controller
    @Environment(AuthController.self) private var auth
    @Environment(AppModel.self) private var appModel
    @Environment(ToastCenter.self) private var toast

    var body: some View {
        let _ = LikeStore.shared.epoch
        Button("Play") { controller.play([entry], at: 0) }
        Button("Play Next") {
            controller.playNext(entry)
            toast.queueNotice("Playing next: \(entry.title)")
        }
        Button("Add to Queue") {
            controller.addToQueue(entry)
            toast.queueNotice("Added to queue: \(entry.title)")
        }
        Button("Start Radio") { controller.playRadio(entry) }
        if auth.signedIn, let vid = entry.videoId {
            Divider()
            Button(likeTitle(vid)) {
                Task { await toggleLike(vid) }
            }
            Button(dislikeTitle(vid)) {
                Task { await toggleDislike(vid) }
            }
            Button("Add to Playlist…") {
                appModel.playlistPicker = PlaylistPickerRequest(videoId: vid, title: entry.title)
            }
            if playlistOwned, let setVideoId, let playlistBrowseId {
                Button("Remove from Playlist", role: .destructive) {
                    let title = entry.title
                    toast.requestConfirmation(ConfirmationRequest(
                        title: "Remove from playlist?",
                        message: "“\(title)” will be removed from this playlist. This cannot be undone.",
                        confirm: "Remove from Playlist"
                    ) {
                        Task {
                            // These wrappers return nil on success and the failure
                            // message otherwise, so the toast reports whichever came
                            // back rather than assuming the write landed.
                            if let failure = await LibraryActions.removeFromPlaylist(
                                playlistId: playlistBrowseId, setVideoId: setVideoId, videoId: vid
                            ) {
                                toast.show("Couldn't remove it — \(failure)", kind: .failure)
                            } else {
                                toast.show("Removed from playlist")
                            }
                        }
                    })
                }
            }
        }
        // Revert / upgrade are two halves of one decision, so they are offered on
        // opposite sides of it and never both. Upstream gates them on the
        // player's copy of the track specifically — a row opened from a list has
        // no stream to change, and a track playing off a file the listener saved
        // has nothing a substitute could replace. The controller holds both
        // answers so the menu cannot disagree with the resolution path about
        // what a revert means.
        if entry.id == controller.current?.id {
            if controller.canRevertToOriginal {
                Divider()
                Button("Revert to Original") { controller.revertToOriginal() }
            }
            if controller.canUpgradeQuality {
                Divider()
                Button("Upgrade Quality") { controller.upgradeQuality() }
            }
        }
        if !entry.isLocal {
            Button("Download") {
                switch DownloadStore.shared.download(entry) {
                case .started:
                    toast.show("Downloading \(entry.title)")
                case .blockedByWifiOnly:
                    toast.show("Downloads are limited to Wi-Fi. Turn that off in Settings to use mobile data.", kind: .failure)
                case .alreadyExists:
                    toast.show("\(entry.title) is already downloading or downloaded", kind: .info)
                case .ignoredLocalTrack:
                    break
                }
            }
        }
        if let albumId = entry.albumId {
            Button("Open Album") {
                appModel.pendingDetail = .detail(browseId: albumId, title: entry.albumName ?? "Album")
            }
        }
        if let artistId = entry.artistId {
            Button("Open Artist") {
                appModel.pendingDetail = .detail(browseId: artistId, title: entry.artist)
            }
        }
        ShareLink(item: shareURL) {
            Label("Share", systemImage: "square.and.arrow.up")
        }
        if showSleepTimer {
            SleepTimerMenu()
        }
        if showDebugLog {
            Button("Track Log…") {
                toast.showTrackLog(entry)
            }
        }
    }

    private var shareURL: URL {
        if let vid = entry.videoId {
            return URL(string: "https://music.youtube.com/watch?v=\(vid)")!
        }
        return URL(string: "https://music.youtube.com")!
    }

    private func likeTitle(_ videoId: String) -> String {
        LibraryActions.cachedLike(videoId) == "LIKE" ? "Remove Like" : "Like"
    }

    private func toggleLike(_ videoId: String) async {
        let next = LibraryActions.cachedLike(videoId) == "LIKE" ? "INDIFFERENT" : "LIKE"
        _ = await LibraryActions.rate(videoId: videoId, status: next)
    }

    /// The label, which is upstream's: the second tap is an undo and says so.
    private func dislikeTitle(_ videoId: String) -> String {
        LibraryActions.cachedLike(videoId) == "DISLIKE" ? "Undo Dislike" : "Dislike"
    }

    /// Thumb down, and move on if this is the track that is playing.
    ///
    /// The decision is `shouldSkipAfterDislike` in the shared module rather than
    /// anything written here, because it is a rule with an edge case — the second tap
    /// is an undo and must *not* skip — and the edge case is the whole reason the rule
    /// exists. The previous status is read before the write, so the answer describes
    /// what the track was and not what it became.
    private func toggleDislike(_ videoId: String) async {
        let wasDisliked = LibraryActions.cachedLike(videoId) == "DISLIKE"
        let previous = wasDisliked
            ? LikeStatus.dislike
            : (LibraryActions.cachedLike(videoId) == "LIKE" ? LikeStatus.like : .indifferent)
        let next = wasDisliked ? "INDIFFERENT" : "DISLIKE"
        if let failure = await LibraryActions.rate(videoId: videoId, status: next) {
            toast.show(failure, kind: .failure)
            return
        }
        let currentId = controller.current?.videoId
        if DislikeSkipKt.shouldSkipAfterDislike(
            previousStatus: previous,
            targetVideoId: videoId,
            currentVideoId: currentId
        ) {
            controller.next()
        }
    }
}

struct BrowseActionButtons: View {
    let card: ShelfCard
    @Environment(PlaybackController.self) private var controller
    @Environment(AuthController.self) private var auth
    @Environment(AppModel.self) private var appModel
    @Environment(ToastCenter.self) private var toast

    var body: some View {
        if let videoId = card.videoId, !videoId.isEmpty {
            let entry = QueueEntry.youtube(
                videoId: videoId, title: card.title, artist: card.subtitle ?? "",
                thumbnailUrl: card.thumbnailUrl
            )
            Button("Play") { controller.playRadio(entry) }
            Button("Play Next") { controller.playNext(entry) }
            Button("Add to Queue") { controller.addToQueue(entry) }
        }
        if let browseId = card.browseId, !browseId.isEmpty {
            Button("Open") {
                appModel.pendingDetail = .detail(browseId: browseId, title: card.title)
            }
            Button("Play") {
                Task { await playCollection(browseId, shuffle: false) }
            }
            Button("Shuffle") {
                Task { await playCollection(browseId, shuffle: true) }
            }
            if auth.signedIn {
                let pinned = PlatformSettings.shared.getString(key: "pinned_playlists", default: "")
                    .split(separator: ",").map(String.init)
                Button(pinned.contains(browseId) ? "Unpin" : "Pin") {
                    if !PlaylistPinning.toggle(browseId: browseId) {
                        appModel.pinLimitAlert = true
                    }
                }
                if browseId.hasPrefix("VL") || browseId.hasPrefix("PL") {
                    Button("Rename Playlist…") {
                        appModel.playlistRename = PlaylistRenameRequest(browseId: browseId, title: card.title)
                    }
                }
                if browseId.hasPrefix("VL") || browseId.hasPrefix("MPRE") || browseId.hasPrefix("OLAK") {
                    Button("Save to Library") {
                        Task {
                            let pid = browseId.hasPrefix("VL") ? String(browseId.dropFirst(2)) : browseId
                            _ = await LibraryActions.ratePlaylist(playlistId: pid, saved: true)
                        }
                    }
                }
            }
            Button("Download") {
                Task {
                    let result = await DownloadStore.shared.downloadCollection(browseId: browseId)
                    switch result {
                    case .started:
                        toast.show("Downloading \(card.title)")
                    case .blockedByWifiOnly:
                        toast.show("Downloads are limited to Wi-Fi. Turn that off in Settings to use mobile data.", kind: .failure)
                    case .alreadyExists:
                        toast.show("\(card.title) is already downloading or downloaded", kind: .info)
                    case .ignoredLocalTrack:
                        break
                    }
                }
            }
        }
    }

    private func playCollection(_ browseId: String, shuffle: Bool) async {
        guard let page = try? await InnertubeDetail.shared.browse(browseId: browseId) else { return }
        var entries = page.songs.map { $0.asEntry(fallbackArt: page.thumbnailUrl) }
        if shuffle { entries.shuffle() }
        if !entries.isEmpty { controller.play(entries, at: 0) }
    }
}

struct PlaylistPickerRequest: Identifiable {
    let id = UUID()
    let videoId: String
    let title: String
}

struct PlaylistPickerView: View {
    let request: PlaylistPickerRequest
    @Environment(\.dismiss) private var dismiss
    @State private var playlists: [UserPlaylistDTO] = []
    @State private var title = ""
    @State private var privacy = "PRIVATE"
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                Section("New playlist") {
                    TextField("Title", text: $title)
                    Picker("Privacy", selection: $privacy) {
                        Text("Private").tag("PRIVATE")
                        Text("Unlisted").tag("UNLISTED")
                        Text("Public").tag("PUBLIC")
                    }
                    Button("Create") {
                        Task {
                            _ = await LibraryActions.createPlaylist(
                                title: title,
                                privacy: privacy,
                                videoId: request.videoId.isEmpty ? nil : request.videoId
                            )
                            dismiss()
                        }
                    }
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Section("Your playlists") {
                    ForEach(playlists) { list in
                        Button {
                            Task {
                                if let err = await LibraryActions.addToPlaylist(playlistId: list.playlistId, videoId: request.videoId) {
                                    error = err
                                } else {
                                    dismiss()
                                }
                            }
                        } label: {
                            VStack(alignment: .leading) {
                                Text(list.title)
                                if !list.subtitle.isEmpty {
                                    Text(list.subtitle).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Add to Playlist")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .task { playlists = await LibraryActions.userPlaylists() }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 480)
        #endif
    }
}

struct SleepTimerMenu: View {
    @Environment(PlaybackController.self) private var controller

    var body: some View {
        Menu {
            Button("Sleep 15 min") { controller.startSleep(minutes: 15) }
            Button("Sleep 30 min") { controller.startSleep(minutes: 30) }
            Button("Sleep 45 min") { controller.startSleep(minutes: 45) }
            Button("Sleep 60 min") { controller.startSleep(minutes: 60) }
            Button("Stop after this track") { controller.startSleepAfterTrack() }
            if controller.sleepUntil != nil || controller.sleepAfterTrack {
                Button("Cancel timer", role: .destructive) { controller.cancelSleep() }
            }
        } label: {
            if let status = controller.sleepTimerStatus {
                Label("Sleep timer · \(status)", systemImage: "moon.zzz")
            } else {
                Label("Sleep timer", systemImage: "moon.zzz")
            }
        }
    }
}

struct PlaylistRenameRequest: Identifiable {
    let id = UUID()
    let browseId: String
    let title: String
}

struct RenamePlaylistAlert: View {
    @Environment(AppModel.self) private var appModel
    @State private var title = ""

    var body: some View {
        TextField("Title", text: $title)
            .onAppear { title = appModel.playlistRename?.title ?? "" }
        Button("Save") {
            if let req = appModel.playlistRename {
                let name = title
                Task { _ = await LibraryActions.renamePlaylist(playlistId: req.browseId, title: name) }
            }
            appModel.playlistRename = nil
        }
        Button("Cancel", role: .cancel) { appModel.playlistRename = nil }
    }
}

/// Upstream `ConfirmationAlert`: a two-action confirmation in the Apple idiom.
///
/// Presented from `ToastHost` via a `ConfirmationRequest` (see `ToastCenter`),
/// because the destructive actions it guards — remove from playlist, clear
/// queue, delete download — are raised from song menus whose content is torn
/// down on tap. Title names the action, the message names what is lost, and the
/// destructive button carries the verb — so the reader never confirms a
/// sentence they did not read.
struct ConfirmationDialog<ConfirmLabel: View>: View {
    let title: String
    let message: String
    let destructive: Bool
    @ViewBuilder let confirmLabel: () -> ConfirmLabel
    let onConfirm: () -> Void
    @Environment(\.dismiss) private var dismiss

    /// Convenience for the common text-labelled case.
    init(
        title: String,
        message: String,
        confirm: String,
        destructive: Bool = true,
        onConfirm: @escaping () -> Void
    ) where ConfirmLabel == Text {
        self.title = title
        self.message = message
        self.destructive = destructive
        self.confirmLabel = { Text(confirm) }
        self.onConfirm = onConfirm
    }

    init(
        title: String,
        message: String,
        destructive: Bool = true,
        onConfirm: @escaping () -> Void,
        @ViewBuilder confirmLabel: @escaping () -> ConfirmLabel
    ) {
        self.title = title
        self.message = message
        self.destructive = destructive
        self.confirmLabel = confirmLabel
        self.onConfirm = onConfirm
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 10) {
                Text(title)
                    .font(.headline)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button(action: { onConfirm(); dismiss() }) {
                    confirmLabel()
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(destructive ? .red : .accentColor)
                Button("Cancel", role: .cancel) { dismiss() }
                    .frame(maxWidth: .infinity)
            }
            .padding(20)
            .navigationTitle("Confirm")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        }
        #if os(macOS)
        .frame(minWidth: 340, minHeight: 220)
        #endif
    }
}

/// Upstream song-menu "Track Log": the last playback-engine events for one track.
///
/// The lines are the real `PlaybackDebugLog` ring filtered to this track's
/// identifiers — the same lines "Copy Log" used to copy whole — newest last, so
/// the story of a resolve/upgrade/swap reads top to bottom. A track the engine
/// has never touched has no lines, and says so rather than showing a sample.
struct TrackLogSheet: View {
    let entry: QueueEntry
    @Environment(\.dismiss) private var dismiss
    @Environment(ToastCenter.self) private var toast

    var body: some View {
        NavigationStack {
            Group {
                if lines.isEmpty {
                    ContentUnavailableView(
                        "No log lines for this track",
                        systemImage: "doc.text.magnifyingglass",
                        description: Text("The engine has not logged anything about “\(entry.title)” yet.")
                    )
                } else {
                    List(lines, id: \.self) { line in
                        Text(line)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                    #if os(iOS)
                    .listStyle(.plain)
                    #endif
                }
            }
            .navigationTitle("Track Log")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                if !lines.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Copy") {
                            PlayerParity.copyToPasteboard(lines.joined(separator: "\n"))
                            toast.show("Track log copied")
                        }
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 420)
        #endif
    }

    /// Every ring line that names this track, oldest first.
    ///
    /// Matched on both the YouTube id and the queue id because the engine logs
    /// whichever identifier the decision was made with — a resolve names the
    /// videoId, a queue move the entry id — and matching one would drop the
    /// other's half of the story.
    private var lines: [String] {
        let dump = PlaybackDebugLog.shared.dump()
        guard !dump.isEmpty else { return [] }
        let needles = [entry.videoId, entry.id].compactMap { $0 }.filter { !$0.isEmpty }
        return dump.split(separator: "\n").map(String.init).filter { line in
            needles.contains { line.contains($0) }
        }
    }
}

/// Upstream `SpotifyCanvasAuthScreen`: the full Canvas setup, Apple Settings style.
///
/// The `sp_dc` cookie (persisted through the shared settings like the rest of
/// the canvas configuration), plus the two switches upstream puts on the same
/// screen: auto-hide the motion art when the still sleeve tells the story, and
/// prefer Spotify's catalogue when looking motion art up. The lookup itself runs
/// in the shared `CanvasBridge`, which reads these same keys — so these rows
/// steer the selection logic rather than duplicating it.
struct SpotifyCanvasSettingsView: View {
    @State private var cookie = PlatformSettings.shared.getString(key: "spotify_spdc_token", default: "")
    @State private var autoHide = PlatformSettings.shared.getBoolean(key: "canvas_autohide", default: false)
    @State private var prioritizeSpotify = PlatformSettings.shared.getBoolean(key: "canvas_prioritize_spotify", default: true)

    /// Whether motion art should play over this track right now.
    ///
    /// The still sleeve wins when auto-hide is on and nothing is moving — the
    /// caller decides what "nothing is moving" means for the artwork it holds.
    static func shouldShowCanvas(hasCanvasURL: Bool) -> Bool {
        guard PlatformSettings.shared.getBoolean(key: "animated_canvas", default: true) else { return false }
        if PlatformSettings.shared.getBoolean(key: "canvas_autohide", default: false), !hasCanvasURL {
            return false
        }
        return hasCanvasURL
    }

    var body: some View {
        Form {
            Section {
                SecureField("sp_dc cookie", text: $cookie)
                    #if os(iOS)
                    .textContentType(.password)
                    #endif
            } header: {
                Text("Spotify Cookie")
            } footer: {
                Text("Paste the sp_dc cookie from an open Spotify web session. BitChord uses it only to look up looping motion art. Leave blank to skip.")
            }
            Section {
                Toggle("Auto-hide motion art", isOn: $autoHide)
                Toggle("Prefer Spotify catalogue", isOn: $prioritizeSpotify)
            } footer: {
                Text("Auto-hide keeps the still sleeve when no motion clip was found. Prefer Spotify asks Spotify's catalogue first when looking one up.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Spotify Canvas")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onChange(of: cookie) { _, value in AppSettings.shared.setSpotifySpdc(value: value) }
        .onChange(of: autoHide) { _, value in PlatformSettings.shared.putBoolean(key: "canvas_autohide", value: value) }
        .onChange(of: prioritizeSpotify) { _, value in PlatformSettings.shared.putBoolean(key: "canvas_prioritize_spotify", value: value) }
    }
}
