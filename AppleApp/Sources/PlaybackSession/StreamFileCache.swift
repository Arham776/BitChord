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
    private static let extensions = ["m4a", "mp4", "webm", "m4v", "aac", "flac"]

    private var inFlight: [String: String] = [:]

    var folder: URL { DiskCache.cachesSubfolder("audio") }

    func path(for videoId: String) -> String? {
        if let path = inFlight[videoId], FileManager.default.fileExists(atPath: path) {
            let complete = FileManager.default.fileExists(atPath: path + ".complete")
            let dest = cachedURL(for: videoId)
            if dest.path == path || complete { return path }
        }
        let dest = cachedURL(for: videoId)
        guard FileManager.default.fileExists(atPath: dest.path) else { return nil }
        DiskCache.touch(dest)
        return dest.path
    }

    func store(_ videoId: String, path: String) {
        inFlight[videoId] = path
        let dest = cachedURL(for: videoId, ext: URL(fileURLWithPath: path).pathExtension)
        let fm = FileManager.default
        if dest.path != path {
            try? fm.removeItem(at: dest)
            try? fm.copyItem(atPath: path, toPath: dest.path)
            // Leave `path` in place: the decoder may still be reading that file.
        }
        inFlight[videoId] = dest.path
        DiskCache.touch(dest)
        trim(keeping: videoId)
    }

    func clear() {
        inFlight.removeAll()
        DiskCache.clearFolder(folder)
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
        let dest = folder.appendingPathComponent(DiskCache.hashName(remote.absoluteString))
        if FileManager.default.fileExists(atPath: dest.path) {
            DiskCache.touch(dest)
            return dest
        }
        guard let (data, response) = try? await URLSession.shared.data(from: remote) else { return remote }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
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
