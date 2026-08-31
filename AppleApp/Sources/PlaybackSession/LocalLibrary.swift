#if os(macOS)
import AppKit
#endif
import Observation
import BitChordShared

/// One scanned local audio file.
struct LocalTrack: Identifiable, Hashable {
    let path: String
    var title: String
    var artist: String
    var album: String
    var durationSeconds: Double
    var artwork: Data?

    var id: String { path }
}

/// Scans a user-selected folder for audio files (spec §5 LocalMusicView:
/// macOS scans via `NSOpenPanel` + security-scoped bookmarks; MPMediaLibrary
/// is iOS-only and permission-gated). Metadata comes from native-core's
/// lofty reader so tags decode identically to the playback engine.
@MainActor
@Observable
final class LocalLibrary {
    static let shared = LocalLibrary()

    private(set) var tracks: [LocalTrack] = []
    private(set) var scanned = false
    var onChange: (() -> Void)?

    private var securityURL: URL?

    /// Restores the persisted bookmark and rescans. BITCHORD_LIBRARY_PATH is
    /// a dev-only override so automated UI tests can seed the library without
    /// driving the modal open panel.
    func restore() {
        if let override = ProcessInfo.processInfo.environment["BITCHORD_LIBRARY_PATH"],
           !override.isEmpty {
            scan(folder: URL(fileURLWithPath: override))
            return
        }
        let stored = PlatformSettings.shared.getString(key: "local_library_path", default: "")
        guard !stored.isEmpty, let data = Data(base64Encoded: stored) else { return }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data,
                                options: [],
                                relativeTo: nil,
                                bookmarkDataIsStale: &stale) else { return }
        _ = url.startAccessingSecurityScopedResource()
        securityURL = url
        scan(folder: url)
    }

    /// Prompts for a folder, persists a bookmark, scans.
    func chooseFolder() {
#if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose the folder holding your music library"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        _ = url.startAccessingSecurityScopedResource()
        securityURL = url
        if let bookmark = try? url.bookmarkData() {
            AppSettings.shared.setLocalLibraryPath(value: bookmark.base64EncodedString())
        }
        scan(folder: url)
#else
        pickingPlaceholder()
#endif
    }

    func scanPicked(_ url: URL) {
        _ = url.startAccessingSecurityScopedResource()
        securityURL = url
        if let bookmark = try? url.bookmarkData() {
            AppSettings.shared.setLocalLibraryPath(value: bookmark.base64EncodedString())
        }
        scan(folder: url)
    }

    #if os(iOS)
    private func pickingPlaceholder() {}
    #endif

    private func scan(folder: URL) {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let enumerator = fm.enumerator(at: folder,
                                             includingPropertiesForKeys: keys,
                                             options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            return
        }
        let audioPaths = enumerator
            .compactMap { $0 as? URL }
            .filter { url in
                let ext = url.pathExtension.lowercased()
                return ["mp3", "flac", "m4a", "mp4", "aac", "ogg", "opus", "wav", "aiff", "aif", "webm"]
                    .contains(ext)
            }
            .map(\.path)

        var found: [LocalTrack] = []
        for path in audioPaths {
            let fileName = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            if let meta = readTrackMetadata(path: path) {
                // Untagged files parse fine but carry empty strings; give them
                // the same fallbacks as the unreadable path so rows never
                // render invisible zero-height text.
                found.append(LocalTrack(
                    path: path,
                    title: meta.title.isEmpty ? fileName : meta.title,
                    artist: meta.artist.isEmpty ? "Unknown artist" : meta.artist,
                    album: meta.album,
                    durationSeconds: meta.durationSeconds,
                    artwork: meta.artwork.isEmpty ? nil : meta.artwork
                ))
            } else {
                found.append(LocalTrack(
                    path: path,
                    title: fileName,
                    artist: "Unknown artist",
                    album: "",
                    durationSeconds: 0,
                    artwork: nil
                ))
            }
        }
        tracks = found.sorted { lhs, rhs in
            if lhs.artist != rhs.artist { return lhs.artist < rhs.artist }
            if lhs.album != rhs.album { return lhs.album < rhs.album }
            return lhs.title < rhs.title
        }
        scanned = true
        onChange?()
    }

    var albumGroups: [(name: String, artist: String, tracks: [LocalTrack])] {
        Dictionary(grouping: tracks) { "\($0.artist)|\($0.album.isEmpty ? "—" : $0.album)" }
            .values
            .map { group in
                (name: group.first?.album ?? "", artist: group.first?.artist ?? "", tracks: group)
            }
            .sorted { ($0.artist, $0.name) < ($1.artist, $1.name) }
    }

    var artistGroups: [(name: String, tracks: [LocalTrack])] {
        Dictionary(grouping: tracks, by: \.artist)
            .map { (name: $0.key, tracks: $0.value) }
            .sorted { $0.name < $1.name }
    }
}
