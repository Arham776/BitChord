import CryptoKit
import Foundation
import BitChordShared

/// Disk LRU of completed stream files — Apple stand-in for upstream `AudioCache`
/// + `DynamicLruCacheEvictor`. Keyed by video id, ceiling from Settings
/// (512 MB–10 GB). Whole files rather than Media3 spans: the easy path on
/// Apple, and it never evicts a track's opening while keeping its tail.
actor StreamFileCache {
    static let shared = StreamFileCache()

    private static let defaultLimit: Int64 = 512 * 1024 * 1024
    private static let extensions = ["m4a", "mp4", "webm", "m4v", "aac", "flac", "ogg", "opus", "mp3", "wav", "aiff"]

    struct Manifest: Codable {
        var version: Int = 1
        var codec: String
        var kbps: Int
        var quality: String
        var sourceIdentity: String
        var recordingIdentity: String
        var complete: Bool
        var bytes: Int64
        var sha256: String
        var relativeLoudnessDb: Double? = nil
    }
    private var inFlight: [String: (path: String, quality: String, kbps: Int, loudnessDb: Double?)] = [:]
    nonisolated static var qualityIdentity: String {
        let wifi = PlatformSettings.shared.getString(key: "audio_quality_wifi", default: "LOSSLESS")
        let cellular = PlatformSettings.shared.getString(key: "audio_quality_cellular", default: "LOSSLESS")
        let musicOnly = PlatformSettings.shared.getBoolean(key: "prefer_music_only", default: false)
        return "\(wifi)|\(cellular)|\(musicOnly)"
    }
    private func manifestURL(_ path: String) -> URL { URL(fileURLWithPath: path).appendingPathExtension("json") }
    private func hashFile(_ path: String) -> String? {
        guard let file = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? file.close() }
        var hash = SHA256()
        do { while true { let data = try file.read(upToCount: 65536) ?? Data(); if data.isEmpty { break }; hash.update(data: data) } } catch { return nil }

        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    var folder: URL { DiskCache.cachesSubfolder("audio") }

    func path(for videoId: String, maxKbps: Int = Int.max, requireLossless: Bool = false) -> String? {
        if let active = inFlight[videoId], active.quality == Self.qualityIdentity,
           FileManager.default.fileExists(atPath: active.path),
           !requireLossless, active.kbps <= maxKbps { return active.path }
        for ext in Self.extensions {
        let dest = cachedURL(for: videoId, ext: ext)
        guard let data = try? Data(contentsOf: manifestURL(dest.path)),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
              manifest.version == 1, manifest.complete, manifest.codec != "unknown",
              manifest.recordingIdentity == videoId,
              manifest.quality == Self.qualityIdentity,
              manifest.kbps <= maxKbps,
              !requireLossless || ["FLAC", "ALAC", "PCM"].contains(manifest.codec),
              let bytes = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size]) as? NSNumber,
              bytes.int64Value == manifest.bytes,
              hashFile(dest.path) == manifest.sha256 else { continue }
        // A legacy entry needs a fresh resolution: its quality and completion
        // cannot be established from a file extension. Keep its bytes for any
        // active reader while the new rendition is resolved.

        DiskCache.touch(dest)
        return dest.path
        }
        return nil
    }

    private struct LoudnessCache: Codable {
        var sourceSHA256: String
        var measurementVersion: String
        var trackLufs: Double
        var truePeakDbtp: Double?
    }
    func measuredLoudness(at path: String) -> LoudnessMeasurement? {
        let url = URL(fileURLWithPath: path).appendingPathExtension("loudness.json")
        guard let data = try? Data(contentsOf: url), let entry = try? JSONDecoder().decode(LoudnessCache.self, from: data),
              entry.measurementVersion == "ebur128-0.1.10-stereo", entry.sourceSHA256 == hashFile(path) else { return nil }
        return LoudnessMeasurement(trackLufs: entry.trackLufs, albumLufs: nil, truePeakDbtp: entry.truePeakDbtp)
    }
    func storeMeasurement(_ measurement: LoudnessMeasurement, at path: String) {
        guard let hash = hashFile(path) else { return }
        let entry = LoudnessCache(sourceSHA256: hash, measurementVersion: "ebur128-0.1.10-stereo", trackLufs: measurement.trackLufs, truePeakDbtp: measurement.truePeakDbtp)
        guard let data = try? JSONEncoder().encode(entry) else { return }
        try? data.write(to: URL(fileURLWithPath: path).appendingPathExtension("loudness.json"), options: .atomic)
    }

    func metadata(at path: String) -> Manifest? {
        if let data = try? Data(contentsOf: manifestURL(path)) {
            return try? JSONDecoder().decode(Manifest.self, from: data)
        }
        if let entry = inFlight.first(where: { $0.value.path == path }) {
            return Manifest(codec: "unknown", kbps: entry.value.kbps, quality: entry.value.quality, sourceIdentity: "growing", recordingIdentity: entry.key, complete: false, bytes: 0, sha256: "", relativeLoudnessDb: entry.value.loudnessDb)
        }
        return nil
    }

    /// The download has its first bytes. Later resolves of the same track must
    /// join this file instead of starting a second fetch at the handoff.
    func noteGrowing(videoId: String, path: String, kbps: Int = 0, quality: String? = nil, relativeLoudnessDb: Double? = nil) {
        inFlight[videoId] = (path, quality ?? Self.qualityIdentity, kbps, relativeLoudnessDb)
    }

    /// The download failed before it finished. Drop the pointer so the next
    /// resolve fetches again. The bytes already handed to a player stay put.
    func dropGrowing(videoId: String) {
        inFlight.removeValue(forKey: videoId)
    }

    func store(_ videoId: String, path: String, sourceIdentity: String = "unknown", codec: String = "unknown", kbps: Int = 0, quality: String? = nil, relativeLoudnessDb: Double? = nil) {
        inFlight[videoId] = (path, quality ?? Self.qualityIdentity, kbps, relativeLoudnessDb)
        let dest = cachedURL(for: videoId, ext: URL(fileURLWithPath: path).pathExtension)
        let fm = FileManager.default
        if dest.path != path {
            try? fm.removeItem(at: dest)
            try? fm.copyItem(atPath: path, toPath: dest.path)
            // Leave `path` in place: the decoder may still be reading that file.
        }
        guard let bytes = (try? fm.attributesOfItem(atPath: dest.path)[.size]) as? NSNumber,
              let hash = hashFile(dest.path), bytes.int64Value > 0 else { return }
        let manifest = Manifest(codec: codec, kbps: kbps, quality: quality ?? Self.qualityIdentity, sourceIdentity: sourceIdentity, recordingIdentity: videoId, complete: true, bytes: bytes.int64Value, sha256: hash, relativeLoudnessDb: relativeLoudnessDb)
        guard let data = try? JSONEncoder().encode(manifest), (try? data.write(to: manifestURL(dest.path), options: .atomic)) != nil else { return }
        inFlight.removeValue(forKey: videoId)
        DiskCache.touch(dest)
        trim(keeping: videoId)
    }

    func clear() {
        inFlight.removeAll()
        DiskCache.clearFolder(folder)
    }

    /// Drops everything cached for one track, and forgets where it was growing.
    ///
    /// The growing path has to go too, and not only the finished copy: a revert
    /// sends the track back to YouTube's own upload, and leaving the old file in
    /// `inFlight` means the next `path(for:)` finds it still there and hands
    /// back the exact copy the listener just rejected — so the revert appears to
    /// do nothing. Every extension is tried because the cached file's extension
    /// is whichever one the source offered, and the rejected copy is the one
    /// nobody remembers the extension of.
    func forget(videoId: String) {
        let growing = inFlight.removeValue(forKey: videoId)
        let fm = FileManager.default
        for ext in Self.extensions {
            let url = folder.appendingPathComponent("\(Self.sanitized(videoId)).\(ext)")
            if fm.fileExists(atPath: url.path) { try? fm.removeItem(at: url); try? fm.removeItem(at: manifestURL(url.path)) }
        }
        if let growing, growing.path != folder.path {
            try? fm.removeItem(atPath: growing.path)
        }
    }

    func trim(keeping videoId: String? = nil) {
        let limit = PlatformSettings.shared.getLong(key: "audio_cache_limit_bytes", default: Self.defaultLimit)
        DiskCache.trimFolder(folder, limitBytes: limit, keepingPrefix: videoId.map(Self.sanitized))
    }

    private func cachedURL(for videoId: String, ext: String? = nil) -> URL {
        let safe = Self.sanitized(videoId)
        if let ext, !ext.isEmpty {
            return folder.appendingPathComponent("\(safe).\(ext)")
        }
        for e in Self.extensions {
            let url = folder.appendingPathComponent("\(safe).\(e)")
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return folder.appendingPathComponent("\(safe).m4a")
    }

    private static func sanitized(_ videoId: String) -> String {
        videoId.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
    }
}

/// Looping canvas clips, capped at 150 MB like upstream `CanvasCache`.
actor CanvasFileCache {
    static let shared = CanvasFileCache()
    private static let limit: Int64 = 150 * 1024 * 1024

    var folder: URL { DiskCache.cachesSubfolder("canvas") }

    func cachedFile(for remote: URL) async -> URL {
        if remote.isFileURL { return remote }
        let ext = remote.pathExtension.lowercased()
        // AVPlayer must see an HLS playlist as a network resource so it can
        // resolve and fetch its media segments. Do not snapshot the playlist
        // into a local file, where its relative segment URLs would break.
        if ["m3u", "m3u8"].contains(ext) { return remote }
        // Keep the container extension on disk; AVPlayer uses it when opening
        // the downloaded movie as a local asset.
        guard ["mp4", "m4v", "mov", "webm"].contains(ext) else { return remote }
        let dest = folder.appendingPathComponent("\(DiskCache.hashName(remote.absoluteString)).\(ext)")
        if FileManager.default.fileExists(atPath: dest.path) {
            DiskCache.touch(dest)
            return dest
        }
        guard let (data, response) = try? await URLSession.shared.data(from: remote) else { return remote }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            return remote
        }
        if let mimeType = response.mimeType?.lowercased(), mimeType.contains("mpegurl") {
            return remote
        }
        try? data.write(to: dest, options: .atomic)
        DiskCache.trimFolder(folder, limitBytes: Self.limit)
        return FileManager.default.fileExists(atPath: dest.path) ? dest : remote
    }

    func clear() { DiskCache.clearFolder(folder) }
}

enum DiskCache {
    static func cachesSubfolder(_ name: String) -> URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BitChord/\(name)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func hashName(_ raw: String) -> String {
        SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func touch(_ url: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    static func trimFolder(_ folder: URL, limitBytes: Int64, keepingPrefix: String? = nil) {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        )) ?? []
        struct Item { var url: URL; var date: Date; var size: Int64 }
        var items: [Item] = urls.compactMap { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true else { return nil }
            return Item(
                url: url,
                date: values?.contentModificationDate ?? .distantPast,
                size: Int64(values?.fileSize ?? 0)
            )
        }
        var total = items.reduce(Int64(0)) { $0 + $1.size }
        guard total > limitBytes else { return }
        items.sort { $0.date < $1.date }
        for item in items {
            if total <= limitBytes { break }
            if let keepingPrefix, item.url.deletingPathExtension().lastPathComponent == keepingPrefix {
                continue
            }
            try? FileManager.default.removeItem(at: item.url)
            total -= item.size
        }
    }

    static func clearFolder(_ folder: URL) {
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for url in urls { try? FileManager.default.removeItem(at: url) }
    }
}
