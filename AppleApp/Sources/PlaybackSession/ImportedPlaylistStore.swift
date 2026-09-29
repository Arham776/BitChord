import Foundation
import Observation
import SwiftUI
import BitChordShared

struct ImportedPlaylistTrack: Codable, Identifiable, Hashable {
    var id: String
    var title: String
    var artist: String
    var sourceTitle: String?
    var sourceArtist: String?
    var album: String?
    var durationText: String?
    var videoId: String?
    var thumbnailUrl: String?

    var queueEntry: QueueEntry? {
        guard let videoId else { return nil }
        return .youtube(
            videoId: videoId,
            title: title,
            artist: artist,
            thumbnailUrl: thumbnailUrl,
            durationText: durationText,
            albumName: album
        )
    }
}

struct ImportedPlaylist: Codable, Identifiable, Hashable {
    var id: String
    var title: String
    var sourceName: String
    var importedAt: Date
    var tracks: [ImportedPlaylistTrack]

    var matchedCount: Int { tracks.filter { $0.videoId != nil }.count }
}

@MainActor
@Observable
final class ImportedPlaylistStore {
    static let shared = ImportedPlaylistStore()

    private(set) var playlists: [ImportedPlaylist] = []
    private let fileURL: URL

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BitChord", isDirectory: true)
        fileURL = support.appendingPathComponent("imported-playlists.json")
        load()
    }

    /// Reimporting the same file updates its existing local playlist instead
    /// of silently creating a duplicate.
    func save(title: String, sourceName: String, tracks: [ImportedPlaylistTrack]) throws -> ImportedPlaylist {
        let key = Self.key(title: title, sourceName: sourceName)
        var playlist = playlists.first { Self.key(title: $0.title, sourceName: $0.sourceName) == key }
            ?? ImportedPlaylist(
                id: UUID().uuidString,
                title: title,
                sourceName: sourceName,
                importedAt: Date(),
                tracks: []
            )
        playlist.title = title
        playlist.sourceName = sourceName
        playlist.importedAt = Date()
        playlist.tracks = tracks
        playlists.removeAll { $0.id == playlist.id }
        playlists.insert(playlist, at: 0)
        try persist()
        return playlist
    }

    func remove(_ playlist: ImportedPlaylist) {
        playlists.removeAll { $0.id == playlist.id }
        try? persist()
    }

    func update(_ playlist: ImportedPlaylist) throws {
        guard let index = playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        playlists[index] = playlist
        try persist()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([ImportedPlaylist].self, from: data) else { return }
        playlists = decoded
    }

    private func persist() throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(playlists).write(to: fileURL, options: .atomic)
    }

    private static func key(title: String, sourceName: String) -> String {
        "\(sourceName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())\u{1f}\(title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
    }
}

struct ImportedPlaylistDetailView: View {
    @State private var playlist: ImportedPlaylist
    @State private var matching = false
    @State private var errorMessage: String?
    @Environment(PlaybackController.self) private var controller

    init(playlist: ImportedPlaylist) {
        _playlist = State(initialValue: playlist)
    }

    private var playable: [QueueEntry] { playlist.tracks.compactMap(\.queueEntry) }

    var body: some View {
        List {
            ForEach(Array(playlist.tracks.enumerated()), id: \.element.id) { offset, track in
                if let entry = track.queueEntry {
                    let playIndex = playlist.tracks[..<offset].filter { $0.videoId != nil }.count
                    HStack(spacing: 4) {
                        SongRow(
                            entry: entry,
                            play: { controller.play(playable, at: playIndex, context: playlist.title) },
                            playNext: { controller.playNext(entry) },
                            addToQueue: { controller.addToQueue(entry) }
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                        #if os(macOS)
                        Menu { trackManagementActions(at: offset) } label: {
                            Image(systemName: "ellipsis")
                                .frame(width: 32, height: 36)
                                .contentShape(Rectangle())
                        }
                        .menuStyle(.borderlessButton)
                        .accessibilityLabel("Edit \(track.title)")
                        #endif
                    }
                } else {
                    HStack(spacing: 12) {
                        Image(systemName: "questionmark.circle")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(track.sourceTitle ?? track.title).lineLimit(1)
                            Text("\(track.sourceArtist ?? track.artist) · No confident match")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Text("Skipped")
                            .font(.caption)
                            .foregroundStyle(.secondary)
#if os(macOS)
                        Menu { trackManagementActions(at: offset) } label: {
                            Image(systemName: "ellipsis")
                                .frame(width: 32, height: 36)
                                .contentShape(Rectangle())
                        }
                        .menuStyle(.borderlessButton)
                        .accessibilityLabel("Edit \(track.title)")
#endif
                    }
                }
            }
            .onDelete(perform: deleteTracks)
            .onMove(perform: moveTracks)
        }
        .listStyle(.plain)
        .navigationTitle(playlist.title)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if playlist.tracks.contains(where: { $0.videoId == nil }) {
                    Button {
                        Task { await matchUnmatchedTracks() }
                    } label: {
                        if matching {
                            ProgressView()
                        } else {
                            Label("Match Unmatched", systemImage: "arrow.triangle.2.circlepath")
                        }
                    }
                    .disabled(matching)
                }
            }
#if os(iOS)
            ToolbarItem(placement: .primaryAction) { EditButton() }
#endif
        }
        .alert("Playlist Update", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .safeAreaInset(edge: .bottom) {
            if !playable.isEmpty {
                Button {
                    controller.play(playable, context: playlist.title)
                } label: {
                    Label("Play Imported Playlist", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .padding()
            }
        }
    }

    private func deleteTracks(at offsets: IndexSet) {
        playlist.tracks.remove(atOffsets: offsets)
        saveChanges()
    }

    private func moveTracks(from source: IndexSet, to destination: Int) {
        playlist.tracks.move(fromOffsets: source, toOffset: destination)
        saveChanges()
    }

    @ViewBuilder
    private func trackManagementActions(at index: Int) -> some View {
        if index > 0 {
            Button("Move Up", systemImage: "arrow.up") { moveTrack(at: index, by: -1) }
        }
        if index + 1 < playlist.tracks.count {
            Button("Move Down", systemImage: "arrow.down") { moveTrack(at: index, by: 1) }
        }
        Button("Remove from Playlist", systemImage: "trash", role: .destructive) {
            removeTrack(at: index)
        }
    }

    private func moveTrack(at index: Int, by offset: Int) {
        guard playlist.tracks.indices.contains(index), playlist.tracks.indices.contains(index + offset) else { return }
        playlist.tracks.swapAt(index, index + offset)
        saveChanges()
    }

    private func removeTrack(at index: Int) {
        guard playlist.tracks.indices.contains(index) else { return }
        playlist.tracks.remove(at: index)
        saveChanges()
    }

    private func matchUnmatchedTracks() async {
        matching = true
        defer { matching = false }
        let rows = playlist.tracks.filter { $0.videoId == nil }.map {
            PlaylistImportRow(
                id: $0.id,
                title: $0.sourceTitle ?? $0.title,
                artist: $0.sourceArtist ?? $0.artist,
                album: $0.album,
                durationText: $0.durationText,
                matchedVideoId: nil,
                matchedTitle: nil,
                matchedArtist: nil,
                thumbnailUrl: nil
            )
        }
        let draft = PlaylistImportDraft(title: playlist.title, sourceName: playlist.sourceName, rows: rows)
        let matched = await PlaylistFileImport.match(draft)
        let updates = Dictionary(uniqueKeysWithValues: matched.rows.map { ($0.id, $0) })
        for index in playlist.tracks.indices {
            guard let row = updates[playlist.tracks[index].id], let videoId = row.matchedVideoId else { continue }
            playlist.tracks[index].videoId = videoId
            playlist.tracks[index].title = row.matchedTitle ?? row.title
            playlist.tracks[index].artist = row.matchedArtist ?? row.artist
            playlist.tracks[index].thumbnailUrl = row.thumbnailUrl
        }
        saveChanges()
    }

    private func saveChanges() {
        do {
            try ImportedPlaylistStore.shared.update(playlist)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct PlaylistImportReviewView: View {
    let draft: PlaylistImportDraft
    let onSaved: (String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selectedIDs: Set<String>

    init(draft: PlaylistImportDraft, onSaved: @escaping (String?) -> Void) {
        self.draft = draft
        self.onSaved = onSaved
        _selectedIDs = State(initialValue: Set(draft.rows.filter { $0.matchedVideoId != nil }.map(\.id)))
    }

    private var matchedRows: [PlaylistImportRow] { draft.rows.filter { $0.matchedVideoId != nil && selectedIDs.contains($0.id) } }
    private var preservedRows: [PlaylistImportRow] {
        draft.rows.filter { $0.matchedVideoId == nil || selectedIDs.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("\(draft.matchedCount) of \(draft.rows.count) tracks matched. Choose the matches to keep. Unmatched tracks stay in the playlist and can be matched later.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Section("Matched") {
                    ForEach(draft.rows.filter { $0.matchedVideoId != nil }) { row in
                        Button {
                            if selectedIDs.contains(row.id) { selectedIDs.remove(row.id) }
                            else { selectedIDs.insert(row.id) }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: selectedIDs.contains(row.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selectedIDs.contains(row.id) ? Color.accentColor : .secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(row.matchedTitle ?? row.title).lineLimit(1)
                                    Text(row.matchedArtist ?? row.artist)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                let unmatched = draft.rows.filter { $0.matchedVideoId == nil }
                if !unmatched.isEmpty {
                    Section("Not Matched · \(unmatched.count)") {
                        ForEach(unmatched) { row in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.title).lineLimit(1)
                                Text(row.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Review Import")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save \(matchedRows.count)") {
                        do {
                            let tracks = preservedRows.map(\.importedTrack)
                            _ = try ImportedPlaylistStore.shared.save(
                                title: draft.title,
                                sourceName: draft.sourceName,
                                tracks: tracks
                            )
                            onSaved(nil)
                            dismiss()
                        } catch {
                            onSaved(error.localizedDescription)
                        }
                    }
                    .disabled(preservedRows.isEmpty)
                }
            }
        }
    }
}
