import Foundation
import Observation
import CryptoKit
import BitChordShared

struct DownloadedTrack: Identifiable, Hashable {
    let path: String
    var title: String
    var artist: String
    var album: String
    var artwork: Data?
    var id: String { path }
}

protocol DownloadBackend: Sendable {
    func resolve(_ entry: QueueEntry, quality: String) async throws -> String
    func transfer(id: String, url: String, headers: [String: String]) async throws -> String
    func cancel(id: String)
}
private struct BridgeDownloadBackend: DownloadBackend {
    func resolve(_ entry: QueueEntry, quality: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DownloadBridge.shared.resolveAtQuality(videoId: entry.videoId ?? entry.id, title: entry.title,
                artist: entry.artist, qualityName: quality, callback: ResolveAdapter { json, error in
                if let json { continuation.resume(returning: json) }
                else { continuation.resume(throwing: NSError(domain: "Download", code: 1, userInfo: [NSLocalizedDescriptionKey: error ?? "Resolution failed"])) }
            })
        }
    }
    func transfer(id: String, url: String, headers: [String: String]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            StreamDownloadBridge.shared.download(downloadId: id, url: url, headers: headers, callback: DoneAdapter { path, error in
                if let path { continuation.resume(returning: path) }
                else { continuation.resume(throwing: NSError(domain: "Download", code: 2, userInfo: [NSLocalizedDescriptionKey: error ?? "Download failed"])) }
            })
        }
    }
    func cancel(id: String) { StreamDownloadBridge.shared.cancel(downloadId: id) }
}

/// Durable intent and assets are separate: collections own requests, requests
/// resolve to renditions, and several requests may share one physical file.
@MainActor @Observable
final class DownloadStore {
    static let shared = DownloadStore()
    enum RequestResult: Equatable { case started, blockedByWifiOnly, alreadyExists, ignoredLocalTrack }
    struct Job: Identifiable, Codable {
        enum Status: String, Codable { case queued, running, done, failed }
        let id: String
        var runID: String
        var title: String
        var status: Status
        var message: String?
        var entry: QueueEntry
        var quality: String
        var attempts = 0
        var retryAt: Date? = nil
        var cancelled = false
    }
    struct Owner: Identifiable, Codable {
        var id: String
        var browseId: String?
        var accountId: String
        var title: String
        var requests: [String]
    }
    struct Asset: Codable {
        var id: String
        var path: String
        var provider: String
        var recordingIdentity: String
        var codec: String
        var kbps: Int
        var lossless: Bool
        var youtubeVideoId: String?
        var bytes: Int64
        var sha256: String
        var entry: QueueEntry
        var managed: Bool
        var sampleRate: Int? = nil
        var bitDepth: Int? = nil
        var quality: String? = nil
    }
    private struct Index: Codable {
        var version = 1
        var owners: [String: Owner] = [:]
        var assets: [String: Asset] = [:]
        var bindings: [String: String] = [:]
        var jobs: [Job] = []
        var migrated = false
        var pendingDeletes: Set<String>? = nil
    }
    private var index = Index()
    private var restoreTask: Task<Void, Never>?
    private var restoreActions: [@MainActor () -> Void] = []
    private(set) var restoring = false
    private var refreshTask: Task<Void, Never>?
    private var refreshID = UUID()
    private(set) var items: [DownloadedTrack] = []
    var jobs: [Job] = []
    var onChange: (() -> Void)?
    private var tasks: [String: Task<Void, Never>] = [:]
    private var transferring: Set<String> = []
    private var leasePaths: Set<String> = []
    private var timer: Timer?
    private var syncs: Set<String> = []
    private var writable = true
    private let backend: any DownloadBackend
    private let workersEnabled: Bool
    private var verified: [String: Date] = [:]
    var activeCount: Int { jobs.filter { $0.status == .queued || $0.status == .running }.count }
    var collections: [Owner] { index.owners.values.filter { $0.browseId != nil && $0.accountId == accountId }.sorted { $0.title < $1.title } }
    var folder: URL { directory.appendingPathComponent("audio", isDirectory: true) }
    private let directory: URL
    private let legacyDirectoryOverride: URL?
    private var indexURL: URL { directory.appendingPathComponent("index.json") }
    private var accountId: String { AccountStore.shared.activeAccount()?.accountId ?? "guest" }
    private var legacyFolder: URL {
        if let legacyDirectoryOverride { return legacyDirectoryOverride }
        let base = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("BitChord", isDirectory: true)
    }

    init(directory: URL? = nil, startWorker: Bool = true, legacyDirectory: URL? = nil, backend: (any DownloadBackend)? = nil) {
        self.backend = backend ?? BridgeDownloadBackend()
        self.workersEnabled = startWorker
        self.legacyDirectoryOverride = legacyDirectory
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BitChord/Downloads", isDirectory: true)
        if startWorker {
            restoring = true; writable = false
            let root = self.directory
            let legacy = self.legacyFolder
            restoreTask = Task { [weak self] in
                let restored = await Task.detached(priority: .utility) { Self.readIndex(directory: root, legacyFolder: legacy) }.value
                guard let self else { return }
                switch restored {
                case .success(let restoredIndex):
                    self.index = restoredIndex
                    self.jobs = restoredIndex.jobs.map { job in
                        var job = job
                        if job.status == .running { job.status = .queued; job.runID = UUID().uuidString }
                        return job
                    }
                    self.writable = true
                case .failure:
                    PlaybackDebugLog.shared.record("download index unavailable; downloads kept unchanged")
                }
                self.restoring = false
                let actions = self.restoreActions; self.restoreActions.removeAll()
                actions.forEach { $0() }
                self.refresh()
                self.timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.pump(); self?.prune() }
                }
                self.pump()
            }
            return
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: indexURL.path) {
                index = try JSONDecoder().decode(Index.self, from: Data(contentsOf: indexURL))
                guard index.version == 1 else { throw CocoaError(.fileReadCorruptFile) }
            }
            jobs = index.jobs.map { job in
                var job = job
                if job.status == .running { job.status = .queued; job.runID = UUID().uuidString }
                return job
            }
        } catch {
            // A corrupt/newer index must not authorize deletion or overwrite.
            writable = false
            PlaybackDebugLog.shared.record("download index unavailable: \(error)")
        }
        if startWorker || legacyDirectory != nil { migrateLegacy() }
        if startWorker {
            refresh()
            timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.pump(); self?.prune() }
            }
            pump()
        }
    }

    func waitUntilReady() async { await restoreTask?.value }
    private func afterRestore(_ action: @escaping @MainActor () -> Void) -> Bool {
        guard restoring else { return false }
        restoreActions.append(action)
        return true
    }

    nonisolated private static func readIndex(directory: URL, legacyFolder: URL) -> Result<Index, Error> {
        do {
            try FileManager.default.createDirectory(at: directory.appendingPathComponent("audio"), withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("index.json")
            var index = FileManager.default.fileExists(atPath: url.path)
                ? try JSONDecoder().decode(Index.self, from: Data(contentsOf: url)) : Index()
            guard index.version == 1 else { throw CocoaError(.fileReadCorruptFile) }
            if !index.migrated {
                let files = (try? FileManager.default.contentsOfDirectory(at: legacyFolder, includingPropertiesForKeys: nil)) ?? []
                for file in files where ["m4a", "mp3", "flac", "mp4", "aac", "opus", "ogg", "wav"].contains(file.pathExtension.lowercased()) {
                    guard let hash = hashFile(file.path) else { continue }
                    let metadata = readTrackMetadata(path: file.path)
                    let id = "legacy:" + digest(file.path)
                    let entry = QueueEntry(id: id, title: metadata?.title.downloadNonEmpty ?? file.deletingPathExtension().lastPathComponent,
                        artist: metadata?.artist.downloadNonEmpty ?? "Unknown artist", source: file.path,
                        albumName: metadata?.album, artworkData: nil, isLocal: true)
                    let bytes = ((try? FileManager.default.attributesOfItem(atPath: file.path)[.size]) as? NSNumber)?.int64Value ?? 0
                    index.assets[id] = Asset(id: id, path: file.path, provider: "legacy", recordingIdentity: id,
                        codec: file.pathExtension, kbps: 0, lossless: false, youtubeVideoId: nil, bytes: bytes,
                        sha256: hash, entry: entry, managed: false)
                    index.bindings[id] = id
                    index.owners[id] = Owner(id: id, browseId: nil, accountId: "", title: entry.title, requests: [id])
                }
                index.migrated = true
                try JSONEncoder().encode(index).write(to: url, options: .atomic)
            }
            return .success(index)
        } catch { return .failure(error) }
    }

    nonisolated static func digest(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
    nonisolated static func hashFile(_ path: String) -> String? {
        guard let file = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? file.close() }
        var hash = SHA256()
        do {
            while true {
                let data = try file.read(upToCount: 65536) ?? Data()
                if data.isEmpty { break }; hash.update(data: data)
            }
            return hash.finalize().map { String(format: "%02x", $0) }.joined()
        } catch { return nil }
    }
    private func persist() {
        guard writable else { return }
        index.jobs = jobs
        do { try JSONEncoder().encode(index).write(to: indexURL, options: .atomic) }
        catch { writable = false; PlaybackDebugLog.shared.record("download index save failed: \(error)") }
    }
    private func canonicalPath(_ path: String) -> String {
        guard path.hasPrefix("/") else { return path }
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }
    private func requestId(_ entry: QueueEntry, quality: String) -> String { Self.digest(entry.source + "|" + entry.id + "|" + quality) }
    private func valid(_ asset: Asset) -> Bool {
        guard let bytes = (try? FileManager.default.attributesOfItem(atPath: asset.path)[.size]) as? NSNumber,
              bytes.int64Value == asset.bytes else { return false }
        let modified = ((try? FileManager.default.attributesOfItem(atPath: asset.path)[.modificationDate]) as? Date) ?? .distantPast
        if verified[asset.id] == modified { return true }
        guard Self.hashFile(asset.path) == asset.sha256 else { return false }
        verified[asset.id] = modified; return true
    }
    private func migrateLegacy() {
        guard writable, !index.migrated else { return }
        let files = (try? FileManager.default.contentsOfDirectory(at: legacyFolder, includingPropertiesForKeys: nil)) ?? []
        for file in files where ["m4a", "mp3", "flac", "mp4", "aac", "opus", "ogg", "wav"].contains(file.pathExtension.lowercased()) {
            guard let hash = Self.hashFile(file.path) else { continue }
            let metadata = readTrackMetadata(path: file.path)
            let id = "legacy:" + Self.digest(file.path)
            let entry = QueueEntry(id: id, title: metadata?.title.downloadNonEmpty ?? file.deletingPathExtension().lastPathComponent,
                                   artist: metadata?.artist.downloadNonEmpty ?? "Unknown artist", source: file.path,
                                   albumName: metadata?.album, artworkData: nil, isLocal: true)
            let bytes = ((try? FileManager.default.attributesOfItem(atPath: file.path)[.size]) as? NSNumber)?.int64Value ?? 0
            index.assets[id] = Asset(id: id, path: file.path, provider: "legacy", recordingIdentity: id, codec: file.pathExtension,
                                     kbps: 0, lossless: false, youtubeVideoId: nil, bytes: bytes, sha256: hash, entry: entry, managed: false)
            index.bindings[id] = id
            index.owners[id] = Owner(id: id, browseId: nil, accountId: "", title: entry.title, requests: [id])
        }
        index.migrated = true; persist()
    }
    func refresh() {
        guard !restoring else { return }
        let assets = Array(index.assets.values)
        let id = UUID(); refreshID = id
        refreshTask?.cancel()
        let work = Task.detached(priority: .utility) {
            assets.filter { FileManager.default.fileExists(atPath: $0.path) }.map { asset in
                let metadata = readTrackMetadata(path: asset.path)
                return DownloadedTrack(path: asset.path, title: asset.entry.title, artist: asset.entry.artist,
                    album: asset.entry.albumName ?? "", artwork: metadata?.artwork)
            }.sorted { $0.title < $1.title }
        }
        refreshTask = Task {
            let scanned = await work.value
            guard refreshID == id, !Task.isCancelled else { return }
            items = scanned; onChange?()
        }
    }
    func waitForRefresh() async { await refreshTask?.value }
    func asset(for entry: QueueEntry, quality: String? = nil) -> Asset? {
        let candidates = index.assets.values.filter { asset in
            (asset.entry.source == entry.source && asset.entry.id == entry.id) || canonicalPath(asset.path) == canonicalPath(entry.source) ||
            ["STANDARD", "HIGH", "LOSSLESS"].contains { quality in index.bindings[requestId(entry, quality: quality)] == asset.id }
        }
        return candidates.sorted { ($0.lossless ? Int.max : $0.kbps) > ($1.lossless ? Int.max : $1.kbps) }.first {
            (quality != "LOSSLESS" || $0.lossless) && (quality != "HIGH" || $0.lossless || $0.kbps >= 128) && valid($0)
        }
    }
    func provenance(for path: String) -> String? { index.assets.values.first { canonicalPath($0.path) == canonicalPath(path) }?.youtubeVideoId }
    func retainPlayback(paths: Set<String>) { leasePaths = Set(paths.map(canonicalPath)); prune() }
    func progress(_ owner: Owner) -> String {
        let done = owner.requests.filter { id in index.bindings[id].flatMap { index.assets[$0] }.map(valid) ?? false }.count
        let failed = jobs.filter { owner.requests.contains($0.id) && $0.status == .failed }.count
        return "\(done) of \(owner.requests.count) saved" + (failed > 0 ? " · \(failed) failed" : "")
    }
    @discardableResult func download(_ entry: QueueEntry) -> RequestResult {
        if afterRestore({ _ = self.download(entry) }) { return .started }
        guard writable else { return .ignoredLocalTrack }
        guard !entry.isLocal else { return .ignoredLocalTrack }
        let quality = PlatformSettings.shared.getString(key: "download_quality", default: "LOSSLESS")
        let id = requestId(entry, quality: quality)
        index.owners["single:" + id] = Owner(id: "single:" + id, browseId: nil, accountId: "", title: entry.title, requests: [id])
        let result = enqueue(entry, quality: quality)
        persist(); pump(); return result
    }
    private func enqueue(_ entry: QueueEntry, quality: String) -> RequestResult {
        let id = requestId(entry, quality: quality)
        if let existing = asset(for: entry, quality: quality) { index.bindings[id] = existing.id; return .alreadyExists }
        if jobs.contains(where: { $0.id == id && ($0.status == .queued || $0.status == .running) }) { return .alreadyExists }
        jobs.removeAll { $0.id == id }
        jobs.append(Job(id: id, runID: UUID().uuidString, title: entry.title, status: .queued, entry: entry, quality: quality))
        return .started
    }
    func hasCollection(_ browseId: String) -> Bool { index.owners[collectionId(browseId)] != nil }
    private func collectionId(_ browseId: String) -> String { Self.digest(accountId + "|" + browseId) }
    func syncIfOwned(browseId: String) async {
        await waitUntilReady()
        if hasCollection(browseId) { _ = await downloadCollection(browseId: browseId) }
    }
    @discardableResult func downloadCollection(browseId: String) async -> RequestResult {
        let generation = PageSession.generation()
        await waitUntilReady()
        guard generation == PageSession.generation(), !Task.isCancelled else { return .ignoredLocalTrack }
        let ownerId = collectionId(browseId), scope = accountId
        guard writable, syncs.insert(ownerId).inserted else { return .alreadyExists }
        defer { syncs.remove(ownerId) }
        do {
            var page = try await InnertubeDetail.shared.browse(browseId: browseId, force: true)
            var seen: Set<String> = []
            while let token = page.continuation, !token.isEmpty {
                guard generation == PageSession.generation(), !Task.isCancelled else { return .ignoredLocalTrack }
                guard seen.insert(token).inserted else { throw CocoaError(.fileReadCorruptFile) }
                let extra = try await InnertubeDetail.shared.more(token: token)
                page.songs += extra.songs; page.continuation = extra.continuation
            }
            guard accountId == scope, generation == PageSession.generation() else { return .ignoredLocalTrack }
            let quality = PlatformSettings.shared.getString(key: "download_quality", default: "LOSSLESS")
            var requests: [String] = []
            for song in page.songs {
                let entry = song.asEntry(fallbackArt: page.thumbnailUrl), id = requestId(entry, quality: quality)
                requests.append(id); _ = enqueue(entry, quality: quality)
            }
            index.owners[ownerId] = Owner(id: ownerId, browseId: browseId, accountId: scope, title: page.title, requests: requests)
            persist(); prune(); pump()
            return .started
        } catch { PlaybackDebugLog.shared.record("collection refresh failed; previous membership retained: \(error)"); return .ignoredLocalTrack }
    }
    func removeOwner(_ id: String) { if afterRestore({ self.removeOwner(id) }) { return }; index.owners.removeValue(forKey: id); persist(); prune(); refresh() }
    func retryOwner(_ owner: Owner) { for id in owner.requests { _ = retry(id) } }
    @discardableResult func retry(_ id: String) -> RequestResult {
        guard let i = jobs.firstIndex(where: { $0.id == id && $0.status == .failed }) else { return .alreadyExists }
        jobs[i].status = .queued; jobs[i].attempts = 0; jobs[i].retryAt = nil; jobs[i].cancelled = false
        persist(); pump(); return .started
    }
    func cancel(_ id: String, restartWorker: Bool = true) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        backend.cancel(id: jobs[i].runID)
        tasks[id]?.cancel(); tasks.removeValue(forKey: id)
        jobs[i].runID = UUID().uuidString; jobs[i].status = .failed; jobs[i].cancelled = true; jobs[i].message = "Cancelled"
        persist(); if restartWorker { pump() }
    }
    func cancelAll() { if afterRestore({ self.cancelAll() }) { return }; for id in jobs.filter({ $0.status == .queued || $0.status == .running }).map(\.id) { cancel(id) } }
    func clearFinishedJobs() { if afterRestore({ self.clearFinishedJobs() }) { return }; jobs.removeAll { $0.status == .done }; persist() }
    func delete(_ path: String) {
        if afterRestore({ self.delete(path) }) { return }
        guard let asset = index.assets.values.first(where: { canonicalPath($0.path) == canonicalPath(path) }) else { return }
        let requests = Set(index.bindings.filter { $0.value == asset.id }.map(\.key))
        for key in Array(index.owners.keys) { index.owners[key]?.requests.removeAll { requests.contains($0) } }
        // Explicit deletion may remove a legacy/exported item, but not a file in use.
        if index.pendingDeletes == nil { index.pendingDeletes = [] }; index.pendingDeletes?.insert(asset.id)
        persist(); prune(); refresh()
    }
    func clearDownloads() { if afterRestore({ self.clearDownloads() }) { return }; cancelAll(); index.owners = [:]; persist(); prune(); refresh() }
    private func prune() {
        guard writable else { return }
        let requests = Set(index.owners.values.flatMap(\.requests))
        for job in jobs where !requests.contains(job.id) && job.status == .running { cancel(job.id, restartWorker: false) }
        jobs.removeAll { !requests.contains($0.id) }
        index.bindings = index.bindings.filter { requests.contains($0.key) }
        let assets = Set(index.bindings.values)
        for asset in Array(index.assets.values) where !assets.contains(asset.id) && !leasePaths.contains(canonicalPath(asset.path)) && !sourceHasPlaybackReaders(source: asset.path) {
            if asset.managed || index.pendingDeletes?.contains(asset.id) == true {
                do {
                    if FileManager.default.fileExists(atPath: asset.path) { try FileManager.default.removeItem(atPath: asset.path) }
                } catch { PlaybackDebugLog.shared.record("private download deletion deferred: \(error)"); continue }
                try? FileManager.default.removeItem(atPath: URL(fileURLWithPath: asset.path).deletingPathExtension().appendingPathExtension("lrc").path)
            }
            index.assets.removeValue(forKey: asset.id)
            index.pendingDeletes?.remove(asset.id)
        }
        persist()
    }
    func networkPolicyChanged() { pump() }
    private func pump() {
        guard writable, workersEnabled else { return }
        if !NetworkQuality.shared.connected || (NetworkQuality.shared.metered && PlatformSettings.shared.getBoolean(key: "wifi_only_downloads", default: true)) {
            for i in jobs.indices where jobs[i].status == .running {
                backend.cancel(id: jobs[i].runID)
                tasks.removeValue(forKey: jobs[i].id)?.cancel()
                jobs[i].runID = UUID().uuidString
                jobs[i].status = .queued; jobs[i].attempts = max(0, jobs[i].attempts - 1)
            }
            persist(); return
        }
        for id in jobs.filter({ $0.status == .queued && !$0.cancelled && ($0.retryAt ?? .distantPast) <= Date() }).map(\.id) {
            guard tasks.count < 2, let i = jobs.firstIndex(where: { $0.id == id }) else { break }
            jobs[i].status = .running; jobs[i].attempts += 1
            let job = jobs[i]; persist()
            tasks[id] = Task { [weak self] in
                guard let self else { return }
                do { try await self.transfer(job) }
                catch {
                    if let i = self.jobs.firstIndex(where: { $0.id == id && $0.runID == job.runID }) {
                        self.jobs[i].message = PlaybackDebugLog.sanitize(error.localizedDescription)
                        self.jobs[i].status = self.jobs[i].attempts < 3 ? .queued : .failed
                        self.jobs[i].retryAt = Date().addingTimeInterval(pow(2, Double(self.jobs[i].attempts)) * 2)
                        PlaybackDebugLog.shared.record("download failed: \(error)", about: id)
                    }
                }
                if self.jobs.contains(where: { $0.id == id && $0.runID == job.runID }) { self.tasks.removeValue(forKey: id) }
                self.persist(); self.refresh(); self.pump()
            }
        }
    }
    private func transfer(_ job: Job) async throws {
        let payload = try await backend.resolve(job.entry, quality: job.quality)
        try Task.checkCancellation()
        var hit = try JSONDecoder().decode(ResolvedDownload.self, from: Data(payload.utf8))
        if hit.provider.hasPrefix("custom:") { hit.provider = "custom:" + Self.digest(hit.provider) }
        var cached: String?
        if hit.provider == "youtube" {
            cached = await StreamFileCache.shared.completedDownloadPath(videoId: hit.recordingIdentity ?? job.entry.id, requireLossless: job.quality == "LOSSLESS", minimumKbps: job.quality == "HIGH" ? 128 : 0)
        }
        if let cached, let metadata = await StreamFileCache.shared.metadata(at: cached) {
            hit.codec = metadata.codec; hit.kbps = metadata.kbps
            hit.lossless = ["FLAC", "ALAC", "PCM", "WAV"].contains(metadata.codec.uppercased())
        }
        let identity = hit.recordingIdentity ?? job.id
        let codec = hit.codec ?? hit.mimeType ?? "unknown"
        let assetId = Self.digest(hit.provider + "|" + identity + "|" + codec + "|\(hit.kbps ?? 0)|\(hit.sampleRate ?? 0)|\(hit.bitDepth ?? 0)|\(hit.lossless ?? false)")
        while transferring.contains(assetId) { try await Task.sleep(for: .milliseconds(100)) }
        try Task.checkCancellation()
        if let existing = index.assets[assetId], valid(existing) { finishJob(job, asset: existing); return }
        transferring.insert(assetId); defer { transferring.remove(assetId) }
        let path: String
        if let cached {
            let temporary = folder.appendingPathComponent(UUID().uuidString).appendingPathExtension(URL(fileURLWithPath: cached).pathExtension)
            try FileManager.default.copyItem(atPath: cached, toPath: temporary.path); path = temporary.path
        } else {
            path = try await backend.transfer(id: job.runID, url: hit.url, headers: hit.headers ?? [:])
        }
        defer { if path != index.assets[assetId]?.path { discardTemporary(path) } }
        try Task.checkCancellation()
        guard jobs.contains(where: { $0.id == job.id && $0.runID == job.runID && $0.status == .running }) else { return }
        let ext = URL(fileURLWithPath: path).pathExtension.downloadNonEmpty ?? "m4a"
        let destination = folder.appendingPathComponent(assetId).appendingPathExtension(ext)
        defer { if index.assets[assetId] == nil { try? FileManager.default.removeItem(at: destination) } }
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        try FileManager.default.moveItem(atPath: path, toPath: destination.path)
        let hash = await Task.detached(priority: .utility) {
            _ = writeTrackTags(path: destination.path, title: job.entry.title, artist: job.entry.artist, album: job.entry.albumName ?? "", artwork: job.entry.artworkData ?? Data())
            return Self.hashFile(destination.path)
        }.value
        try Task.checkCancellation()
        guard jobs.contains(where: { $0.id == job.id && $0.runID == job.runID && $0.status == .running }) else { return }
        guard let hash, let bytes = (try FileManager.default.attributesOfItem(atPath: destination.path)[.size]) as? NSNumber else { throw DownloadError("Incomplete asset") }
        let asset = Asset(id: assetId, path: destination.path, provider: hit.provider, recordingIdentity: identity, codec: codec,
                          kbps: hit.kbps ?? 0, lossless: hit.lossless ?? false, youtubeVideoId: hit.youtubeVideoId,
                          bytes: bytes.int64Value, sha256: hash, entry: job.entry, managed: true, sampleRate: hit.sampleRate, bitDepth: hit.bitDepth, quality: job.quality)
        index.assets[assetId] = asset; finishJob(job, asset: asset); persist()
        LyricsTagBridge.shared.embedSidecar(audioPath: destination.path, videoId: hit.youtubeVideoId ?? job.entry.id,
            title: job.entry.title, artist: job.entry.artist, durationMs: Int64(job.entry.durationSeconds * 1000), album: job.entry.albumName,
            callback: EmbedSidecarAdapter { _, _ in })
        if PlatformSettings.shared.getBoolean(key: "export_downloads", default: false) {
            try FileManager.default.createDirectory(at: legacyFolder, withIntermediateDirectories: true)
            let name = job.entry.title.replacingOccurrences(of: "/", with: "-")
            let exported = legacyFolder.appendingPathComponent("\(name)-\(assetId.prefix(12))").appendingPathExtension(ext)
            if !FileManager.default.fileExists(atPath: exported.path) { try FileManager.default.copyItem(at: destination, to: exported) }
        }
        PlaybackDebugLog.shared.record("download saved provider=\(hit.provider) codec=\(codec) bytes=\(bytes)", about: job.id)
    }
    private func finishJob(_ job: Job, asset: Asset) {
        guard let i = jobs.firstIndex(where: { $0.id == job.id && $0.runID == job.runID }) else { return }
        index.bindings[job.id] = asset.id; jobs[i].status = .done; jobs[i].message = nil
    }
    private func discardTemporary(_ path: String) { for path in [path, path + ".len", path + ".grow", path + ".complete"] { try? FileManager.default.removeItem(atPath: path) } }
    private struct ResolvedDownload: Decodable {
        var url: String; var provider: String; var recordingIdentity: String?; var codec: String?; var mimeType: String?
        var kbps: Int?; var sampleRate: Int?; var bitDepth: Int?; var lossless: Bool?; var youtubeVideoId: String?; var headers: [String: String]?
    }
    private struct DownloadError: LocalizedError { let message: String; init(_ message: String) { self.message = message }; var errorDescription: String? { message } }
}
private extension String { var downloadNonEmpty: String? { isEmpty ? nil : self } }
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
