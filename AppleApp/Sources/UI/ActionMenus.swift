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
            toast.show("Playing next: \(entry.title)")
        }
        Button("Add to Queue") {
            controller.addToQueue(entry)
            toast.show("Added to queue")
        }
        Button("Start Radio") { controller.playRadio(entry) }
        if auth.signedIn, let vid = entry.videoId {
            Divider()
            Button(likeTitle(vid)) {
                Task { await toggleLike(vid) }
            }
            Button("Dislike") {
                Task { _ = await LibraryActions.rate(videoId: vid, status: "DISLIKE") }
            }
            Button("Add to Playlist…") {
                appModel.playlistPicker = PlaylistPickerRequest(videoId: vid, title: entry.title)
            }
            if playlistOwned, let setVideoId, let playlistBrowseId {
                Button("Remove from Playlist", role: .destructive) {
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
                }
            }
        }
        if !entry.isLocal {
            Button("Download") {
                DownloadStore.shared.download(entry)
                toast.show("Downloading \(entry.title)")
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
            Button("Copy Log") {
                PlayerParity.copyToPasteboard(PlayerParity.debugLog(controller))
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
}

struct BrowseActionButtons: View {
    let card: ShelfCard
    @Environment(PlaybackController.self) private var controller
    @Environment(AuthController.self) private var auth
    @Environment(AppModel.self) private var appModel

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
                Task { await DownloadStore.shared.downloadCollection(browseId: browseId) }
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
