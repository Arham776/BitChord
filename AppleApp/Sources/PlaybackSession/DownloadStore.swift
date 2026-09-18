import Foundation
import Observation
import BitChordShared

struct DownloadedTrack: Identifiable, Hashable {
    let path: String
    var title: String
    var artist: String
    var album: String
    var artwork: Data?
    var id: String { path }
}

@MainActor
@Observable
final class DownloadStore {
    static let shared = DownloadStore()
    private(set) var items: [DownloadedTrack] = []
    var onChange: (() -> Void)?
    struct Job: Identifiable {
        enum Status { case queued, running, done, failed }
        let id: String
        var title: String
        var status: Status
        var message: String?
        var entry: QueueEntry
    }
    var jobs: [Job] = []
    var activeCount: Int { jobs.filter { $0.status == .queued || $0.status == .running }.count }

    var folder: URL {
        let base = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("BitChord", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func clearDownloads() {
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for url in urls {
            try? FileManager.default.removeItem(at: url)
        }
        refresh()
    }

    func refresh() {
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        items = urls.filter { ["m4a", "mp3", "flac", "mp4", "aac"].contains($0.pathExtension.lowercased()) }.map { url in
            if let meta = readTrackMetadata(path: url.path) {
                return DownloadedTrack(
                    path: url.path,
                    title: meta.title.isEmpty ? url.deletingPathExtension().lastPathComponent : meta.title,
                    artist: meta.artist.isEmpty ? "Unknown artist" : meta.artist,
                    album: meta.album,
                    artwork: meta.artwork.isEmpty ? nil : meta.artwork
                )
            }
            return DownloadedTrack(path: url.path, title: url.deletingPathExtension().lastPathComponent, artist: "Unknown artist", album: "", artwork: nil)
        }
        onChange?()
    }

    func download(_ entry: QueueEntry) {
        guard !entry.isLocal else { return }
        if NetworkQuality.shared.metered,
           PlatformSettings.shared.getBoolean(key: "wifi_only_downloads", default: true) {
            return
        }
        let videoId = entry.source.hasPrefix("yt:") ? String(entry.source.dropFirst(3)) : entry.id
        if jobs.contains(where: { $0.id == videoId && ($0.status == .queued || $0.status == .running || $0.status == .done) }) {
            return
        }
        jobs.append(Job(id: videoId, title: entry.title, status: .running, message: nil, entry: entry))
        DownloadBridge.shared.resolve(videoId: videoId, title: entry.title, artist: entry.artist, callback: ResolveAdapter { json, msg in
            Task { @MainActor in
                guard let json, let data = json.data(using: .utf8) else {
                    self.fail(videoId, msg ?? "resolve failed")
                    return
                }
                let url: String
                let headers: [String: String]
                if let hit = try? JSONDecoder().decode(CustomHit.self, from: data) {
                    url = hit.url
                    headers = [:]
                } else if let stream = try? JSONDecoder().decode(YTM.self, from: data) {
                    url = stream.url
                    headers = stream.headers
                } else {
                    self.fail(videoId, "bad payload")
                    return
                }
                StreamDownloadBridge.shared.download(url: url, headers: headers, callback: DoneAdapter { path, err in
                    Task { @MainActor in
                        guard let path else {
                            self.fail(videoId, err ?? "download failed")
                            return
                        }
                        self.finish(path: path, entry: entry)
                        self.mark(videoId, .done)
                    }
                })
            }
        })
    }

    func downloadCollection(browseId: String) async {
        guard let page = try? await InnertubeDetail.shared.browse(browseId: browseId) else { return }
        for song in page.songs {
            download(song.asEntry(fallbackArt: page.thumbnailUrl))
        }
    }

    func retry(_ id: String) {
        guard let job = jobs.first(where: { $0.id == id }) else { return }
        jobs.removeAll { $0.id == id }
        download(job.entry)
    }

    func cancel(_ id: String) {
        jobs.removeAll { $0.id == id }
    }

    private func fail(_ id: String, _ message: String) {
        if let i = jobs.firstIndex(where: { $0.id == id }) {
            jobs[i].status = .failed
            jobs[i].message = message
        }
    }

    private func mark(_ id: String, _ status: Job.Status) {
        if let i = jobs.firstIndex(where: { $0.id == id }) {
            jobs[i].status = status
        }
    }

    private func finish(path: String, entry: QueueEntry) {
        let ext = URL(fileURLWithPath: path).pathExtension.isEmpty ? "m4a" : URL(fileURLWithPath: path).pathExtension
        let safe = entry.title.replacingOccurrences(of: "/", with: "-")
        let dest = folder.appendingPathComponent("\(safe).\(ext)")
        try? FileManager.default.removeItem(at: dest)
        try? FileManager.default.moveItem(atPath: path, toPath: dest.path)
        _ = writeTrackTags(
            path: dest.path,
            title: entry.title,
            artist: entry.artist,
            album: entry.albumName ?? "",
            artwork: entry.artworkData ?? Data()
        )
        let durationMs = Swift.Int64((entry.durationSeconds > 0 ? entry.durationSeconds : 0) * 1000)
        LyricsTagBridge.shared.embedSidecar(
            audioPath: dest.path,
            videoId: entry.videoId ?? entry.id,
            title: entry.title,
            artist: entry.artist,
            durationMs: durationMs,
            album: entry.albumName,
            callback: EmbedSidecarAdapter { _, _ in }
        )
        refresh()
    }

    private struct CustomHit: Codable {
        let url: String
        let codec: String?
        let lossless: Bool?
    }
    private struct YTM: Codable {
        let url: String
        let kbps: Int
        let mimeType: String
        let headers: [String: String]
    }
}

private final class ResolveAdapter: DownloadBridgeResolveCallback {
    let handler: (String?, String?) -> Void
    init(_ handler: @escaping (String?, String?) -> Void) { self.handler = handler }
    func onResult(json: String?, message: String?) { handler(json, message) }
}

private final class DoneAdapter: StreamDownloadBridgeDownloadCallback {
    let handler: (String?, String?) -> Void
    init(_ handler: @escaping (String?, String?) -> Void) { self.handler = handler }
    func onResult(path: String?, message: String?) { handler(path, message) }
}

private final class EmbedSidecarAdapter: LyricsTagBridgeEmbedCallback {
    let handler: (String?, String?) -> Void
    init(_ handler: @escaping (String?, String?) -> Void) { self.handler = handler }
    func onResult(plain: String?, enhanced: String?) { handler(plain, enhanced) }
}
