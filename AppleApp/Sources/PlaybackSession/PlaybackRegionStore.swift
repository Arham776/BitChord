import Foundation
import CryptoKit

struct NonMusicSegment: Codable, Equatable, Sendable {
    var start: Double
    var end: Double
}
actor SponsorBlockStore {
    static let shared = SponsorBlockStore()
    private struct Cached: Codable { var expires: Date; var segments: [NonMusicSegment] }
    private var known: [String: Cached] = [:]
    private var inFlight: [String: Task<[NonMusicSegment], Never>] = [:]
    private let file: URL
    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("BitChord", isDirectory: true)
        file = base.appendingPathComponent("sponsorblock.json")
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode([String: Cached].self, from: data) { known = saved }
    }
    static func parse(_ data: Data) -> [NonMusicSegment] {
        guard let entries = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        return entries.compactMap { entry in
            guard entry["category"] as? String == "music_offtopic", entry["actionType"] as? String == "skip",
                  let span = entry["segment"] as? [Double], span.count == 2,
                  span[0].isFinite, span[1].isFinite, span[0] >= 0, span[1] > span[0] else { return nil }
            return NonMusicSegment(start: span[0], end: span[1])
        }.sorted { $0.start < $1.start }
    }
    func segments(videoId: String) async -> [NonMusicSegment] {
        guard videoId.range(of: "^[A-Za-z0-9_-]{11}$", options: .regularExpression) != nil else { return [] }
        if let cached = known[videoId], cached.expires > Date() { return cached.segments }
        if let task = inFlight[videoId] { return await task.value }
        let task = Task<[NonMusicSegment], Never> {
            do {
                var components = URLComponents(string: "https://sponsor.ajay.app/api/skipSegments")!
                components.queryItems = [URLQueryItem(name: "videoID", value: videoId), URLQueryItem(name: "categories", value: "[\"music_offtopic\"]")]
                var request = URLRequest(url: components.url!); request.timeoutInterval = 6
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let response = response as? HTTPURLResponse else { return [] }
                if response.statusCode == 404 { self.remember(videoId, segments: []); return [] }
                guard response.statusCode == 200 else { return [] }
                let result = Self.parse(data); self.remember(videoId, segments: result); return result
            } catch { PlaybackDebugLog.shared.record("SponsorBlock unavailable: \(error)"); return [] }
        }
        inFlight[videoId] = task
        let result = await task.value; inFlight[videoId] = nil
        return result
    }
    private func remember(_ id: String, segments: [NonMusicSegment]) {
        known = known.filter { $0.value.expires > Date() }
        if known.count >= 512, let oldest = known.min(by: { $0.value.expires < $1.value.expires })?.key { known[oldest] = nil }
        known[id] = Cached(expires: Date().addingTimeInterval(segments.isEmpty ? 86400 : 604800), segments: segments)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(known) { try? data.write(to: file, options: .atomic) }
    }
}

/// Only complete, fingerprinted audio persists a tail bound. Partial-head
/// analysis is deliberately transient and retried as bytes finish arriving.
actor PlaybackRegionStore {
    static let shared = PlaybackRegionStore()
    private struct Edges: Codable { var version = 1; var start: Double; var end: Double? }
    func regions(path: String, videoId: String?, trimEdges: Bool, skipSegments: Bool) async -> PlaybackRegions {
        var result = PlaybackRegions(audibleStartSeconds: 0, audibleEndSeconds: nil, excluded: [])
        if trimEdges, !path.hasPrefix("http") {
            let complete = !FileManager.default.fileExists(atPath: path + ".grow") || FileManager.default.fileExists(atPath: path + ".complete")
            let hash = complete ? DownloadStore.hashFile(path) : nil
            let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("BitChord/Boundaries", isDirectory: true)
            let file = hash.map { directory.appendingPathComponent($0 + "-v1.json") }
            if let file, let data = try? Data(contentsOf: file), let cached = try? JSONDecoder().decode(Edges.self, from: data), cached.version == 1 {
                result.audibleStartSeconds = cached.start; result.audibleEndSeconds = cached.end
            } else if let detected = try? detectPlaybackRegions(source: path, complete: complete) {
                result = detected
                if let file {
                    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    if let data = try? JSONEncoder().encode(Edges(start: result.audibleStartSeconds, end: result.audibleEndSeconds)) { try? data.write(to: file, options: .atomic) }
                }
            }
        }
        if skipSegments, let videoId {
            result.excluded = await SponsorBlockStore.shared.segments(videoId: videoId).map { PlaybackInterval(startSeconds: $0.start, endSeconds: $0.end) }
        }
        return result
    }
}
