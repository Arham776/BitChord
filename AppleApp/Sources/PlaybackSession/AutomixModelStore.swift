import Foundation
import CryptoKit
import Observation

/// The two ONNX graphs Automix leans on, fetched on first run rather than shipped.
///
/// The upstream Android app copies its graphs out of the APK's own assets, so the
/// models are a build input there. Here they are a *download*: 123 MB of graphs in
/// an app bundle is 123 MB that every listener pays for whether or not they turn
/// Automix on, and the beat model alone is what unlocks real beat/downbeat grids
/// (10.4 MB). So the beat model is offered first and the 113 MB vocal model is a
/// separate opt-in — Automix works without it, it just cannot avoid a clash between
/// two vocals without it.
///
/// Every source is pinned to a revision and verified against a SHA-256 that was
/// read off the repository before it was written down here. A redirect to a CDN is
/// followed by the system, but the bytes are only ever trusted after the hash is
/// recomputed on this device, so neither a moved tag nor a truncated transfer can
/// put a bad graph in the analyzer.
///
/// Deliberately free of `BitChordShared` and SwiftUI:
/// `scripts/check-models.sh` compiles this file alone with the real network and
/// real hashing, and a file that can only be exercised from inside the app is a
/// file whose download logic is only ever tested by hand. Policy that belongs to
/// the app — whether a metered connection is acceptable, whether the sheet has
/// been dismissed — is passed in or handled by the call site.
@MainActor
@Observable
final class AutomixModelStore {

    // MARK: - Identity

    enum ModelID: String, CaseIterable, Identifiable {
        case beat
        case vocals

        var id: String { rawValue }
    }

    /// One pinned graph: where it comes from, how big it is, and what it must hash to.
    struct ModelSpec {
        let id: ModelID
        let fileName: String
        let displayName: String
        let detail: String
        let byteCount: Int64
        let sha256: String
        let url: URL

        var sizeText: String {
            ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
        }

        static let beat = ModelSpec(
            id: .beat,
            fileName: "beat_this.onnx",
            displayName: "Beat + downbeat detection",
            detail: "Beat This! reads the beat grid and downbeats, so transitions land on the music rather than near it.",
            byteCount: 10_401_044,
            sha256: "c462b064a4033050ca6a5354bf866ff4610ab1fd8f1dec1e494b20b22d870aea",
            // Pinned to the revision, not `main`: a branch can move, a commit cannot.
            url: URL(string: "https://huggingface.co/ashudesai/songbird-models/resolve/345312bf5604913b3c0d05815f93c81c4b114e4d/small0.onnx")!
        )

        static let vocals = ModelSpec(
            id: .vocals,
            fileName: "vocals_umxhq.onnx",
            displayName: "Vocal detection",
            detail: "open-unmix measures how much singing is in an instant, so Automix can avoid blending two vocals over each other.",
            byteCount: 113_115_263,
            sha256: "da6c48a21f1231eef0ea61dc00e8e4c6e5c29d37f86685323d68de1e6836c4cb",
            url: URL(string: "https://huggingface.co/nsosu/demucs-onnx/resolve/571310473535558f41c1bcd8ed4955515b983490/umxl_vocals.onnx")!
        )

        static func spec(for id: ModelID) -> ModelSpec {
            switch id {
            case .beat: return .beat
            case .vocals: return .vocals
            }
        }
    }

    struct Record: Codable {
        var sha256: String
        var bytes: Int64
        var installedAt: Date
    }

    // MARK: - State

    enum Status: Equatable {
        case notInstalled
        /// A partial transfer on disk, with the byte count it reached.
        case paused(Int64)
        case downloading(Double)
        case verifying
        case installed
        /// Refused because the connection is metered and the caller did not allow it.
        case blockedByWifi
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .downloading, .verifying: return true
            default: return false
            }
        }

        var isInstalled: Bool { self == .installed }
    }

    static let shared = AutomixModelStore()

    private(set) var status: [ModelID: Status] = [:]

    /// Fired on the main actor after any install or removal, so the app can reload
    /// the analyzer and let the player use what is now on disk.
    var onChanged: (() -> Void)?

    let directory: URL

    /// The manifest in use. Injectable so the download path can be exercised end to
    /// end against a fixture server — `scripts/check-models.sh` — rather than only
    /// against the two real graphs, which are 123 MB and somebody else's uptime.
    private let specs: [ModelID: ModelSpec]
    private var records: [String: Record] = [:]
    private var tasks: [ModelID: Task<Void, Never>] = [:]
    /// Models removed while a transfer was still winding down. A cancelled task still
    /// reaches its own catch block, and that catch must not report "paused" over the
    /// removal that caused it.
    private var discarded: Set<ModelID> = []

    init(directory: URL? = nil, specs: [ModelSpec]? = nil) {
        self.directory = directory ?? Self.defaultDirectory
        self.specs = Dictionary(
            (specs ?? [ModelSpec.beat, .vocals]).map { ($0.id, $0) },
            uniquingKeysWith: { _, last in last }
        )
        for id in ModelID.allCases {
            status[id] = .notInstalled
        }
    }

    /// Application Support, not Caches: a 113 MB graph that the system may purge at
    /// any moment is a graph the listener downloads twice. Excluded from backup for
    /// the same reason — it is reproducible, and iCloud backup is not the place to
    /// put it.
    static var defaultDirectory: URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return root.appendingPathComponent("BitChord/Models", isDirectory: true)
    }

    /// One session per transfer, because a `URLSessionDataTask` takes its delegate
    /// from the session rather than from the task, and the delegate is what turns
    /// the response into writes on the part file. Two downloads at most, one session
    /// each, invalidated when the transfer ends.
    private static func makeSession(delegate: URLSessionDataDelegate) -> URLSession {
        let configuration = URLSessionConfiguration.default
        // A 113 MB fetch over a slow connection is minutes, not seconds; the default
        // per-request timeout would abandon it halfway and turn a slow download into
        // a failed one.
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 60 * 60
        configuration.waitsForConnectivity = true
        // A cached 200 would answer a Range request with the whole file and silently
        // undo a resume, so nothing about this transfer may come from a cache.
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    // MARK: - Queries

    func spec(_ id: ModelID) -> ModelSpec { specs[id] ?? ModelSpec.spec(for: id) }

    func status(of id: ModelID) -> Status { status[id] ?? .notInstalled }

    var beatInstalled: Bool { status(of: .beat).isInstalled }
    var vocalsInstalled: Bool { status(of: .vocals).isInstalled }

    var anyBusy: Bool { ModelID.allCases.contains { status(of: $0).isBusy } }

    var totalBytesOnDisk: Int64 {
        ModelID.allCases.reduce(0) { total, id in
            guard status(of: id).isInstalled else { return total }
            return total + sizeOnDisk(of: spec(id).fileName)
        }
    }

    func installedPath(_ id: ModelID) -> String? {
        guard status(of: id).isInstalled else { return nil }
        return fileURL(for: spec(id)).path
    }

    /// Where the analyzer should load from.
    ///
    /// Downloaded copies win over the bundle, and the bundle lookup stays for the
    /// development flow: `scripts/fetch-automix-models.sh` drops graphs into
    /// `Resources/Models`, which is how the port has been built until now and is
    /// how CI gets a model without a network step at test time. An empty string is
    /// what `configureAnalyzer` already means by "unload" — so a listener with no
    /// models gets today's tempo fallback and no vocal mask, unchanged.
    var analyzerPaths: (beat: String, vocal: String) {
        (analyzerPath(for: .beat), analyzerPath(for: .vocals))
    }

    private func analyzerPath(for id: ModelID) -> String {
        if let downloaded = installedPath(id) { return downloaded }
        guard let bundled = Self.bundleURL(for: spec(id).fileName) else { return "" }
        return bundled.path
    }

    private static func bundleURL(for fileName: String) -> URL? {
        let base = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        return Bundle.main.url(forResource: base, withExtension: ext, subdirectory: "Models")
            ?? Bundle.main.url(forResource: base, withExtension: ext)
    }

    // MARK: - Refresh

    /// Reconcile the directory with the manifest.
    ///
    /// A file whose size is right and whose sidecar record matches is trusted: the
    /// hash was checked when it was installed, and re-reading 113 MB on every launch
    /// to rediscover that is a launch cost with no answer behind it. A file with no
    /// record — copied in by hand, say — is hashed once and recorded, because the
    /// alternative is either trusting it blindly or deleting something the listener
    /// put there.
    func refresh() {
        ensureDirectory()
        records = loadRecords()
        var changed = false

        for id in ModelID.allCases where !status(of: id).isBusy {
            let spec = spec(id)
            let file = fileURL(for: spec)
            let part = partURL(for: spec)

            if FileManager.default.fileExists(atPath: file.path) {
                let size = sizeOnDisk(of: spec.fileName)
                if size == spec.byteCount, records[spec.fileName]?.sha256 == spec.sha256 {
                    status[id] = .installed
                    continue
                }
                if size == spec.byteCount, hashMatches(file, spec: spec) {
                    records[spec.fileName] = Record(sha256: spec.sha256, bytes: spec.byteCount, installedAt: Date())
                    saveRecords()
                    status[id] = .installed
                    changed = true
                    continue
                }
                // Wrong length, or a length that does not survive its own hash: the
                // only states worth having are "usable" and "absent".
                try? FileManager.default.removeItem(at: file)
                records[spec.fileName] = nil
                saveRecords()
                changed = true
            }

            let partSize = sizeOnDisk(of: spec.fileName + ".part")
            if partSize > 0 {
                // A part that already carries the whole file is finished except for
                // the check; anything else is a resume point.
                if partSize == spec.byteCount {
                    let outcome = installVerified(part: part, spec: spec)
                    status[id] = outcome
                    if case .installed = outcome { changed = true }
                } else if partSize > spec.byteCount {
                    try? FileManager.default.removeItem(at: part)
                    status[id] = .notInstalled
                } else {
                    status[id] = .paused(partSize)
                }
            } else {
                status[id] = .notInstalled
            }
        }

        if changed { onChanged?() }
    }

    // MARK: - Download

    /// Download in the background, cancelable through ``cancel(_:)``.
    func start(_ id: ModelID, allowMetered: Bool) {
        guard !status(of: id).isBusy, !status(of: id).isInstalled else { return }
        guard tasks[id] == nil else { return }
        tasks[id] = Task { [weak self] in
            await self?.download(id, allowMetered: allowMetered)
            self?.tasks[id] = nil
        }
    }

    /// The download itself.
    ///
    /// Bytes are written to the part file as they arrive rather than assembled in a
    /// system temporary file, which is what makes a dropped connection resumable:
    /// the truncated transfer is the part file, and the next attempt asks for
    /// `bytes=<n>-` and carries on. Waiting for the whole body and only then writing
    /// it would mean a 113 MB download that fails at 112 MB starts over.
    func download(_ id: ModelID, allowMetered: Bool) async {
        let spec = spec(id)
        guard !status(of: id).isInstalled else { return }
        guard !status(of: id).isBusy else { return }
        // A new attempt supersedes an earlier removal, which may still have a task
        // winding down. Clearing here means the winding-down task's own catch cannot
        // resurrect it as "paused" over the removal's "not installed".
        discarded.remove(id)

        guard allowMetered else {
            status[id] = .blockedByWifi
            return
        }

        ensureDirectory()
        let part = partURL(for: spec)
        var existing = sizeOnDisk(of: spec.fileName + ".part")

        if existing > spec.byteCount {
            try? FileManager.default.removeItem(at: part)
            existing = 0
        }
        if existing == spec.byteCount {
            status[id] = .verifying
            let outcome = installVerified(part: part, spec: spec)
            status[id] = outcome
            if case .installed = outcome { onChanged?() }
            return
        }

        status[id] = .downloading(spec.byteCount > 0 ? Double(existing) / Double(spec.byteCount) : 0)

        var request = URLRequest(url: spec.url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if existing > 0 {
            request.setValue("bytes=\(existing)-", forHTTPHeaderField: "Range")
        }

        let delegate = PartWriter(
            part: part,
            append: existing > 0,
            initial: existing,
            onProgress: { [weak self] reached in
                Task { @MainActor in self?.noteProgress(id, bytes: reached) }
            }
        )
        let session = Self.makeSession(delegate: delegate)
        defer { session.finishTasksAndInvalidate() }
        let task = session.dataTask(with: request)

        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    delegate.attach(continuation)
                    task.resume()
                }
            } onCancel: {
                task.cancel()
            }

            status[id] = .verifying
            let outcome = installVerified(part: part, spec: spec)
            guard !discarded.contains(id) else { return }
            status[id] = outcome
            if case .installed = outcome { onChanged?() }
        } catch is CancellationError {
            guard !discarded.contains(id) else { return }
            let reached = sizeOnDisk(of: spec.fileName + ".part")
            status[id] = reached > 0 ? .paused(reached) : .notInstalled
        } catch let error as URLError where error.code == .cancelled {
            guard !discarded.contains(id) else { return }
            let reached = sizeOnDisk(of: spec.fileName + ".part")
            status[id] = reached > 0 ? .paused(reached) : .notInstalled
        } catch {
            guard !discarded.contains(id) else { return }
            let reached = sizeOnDisk(of: spec.fileName + ".part")
            status[id] = .failed(
                reached > 0
                    ? "\(error.localizedDescription) · \(Self.bytes(reached)) kept, try again to resume"
                    : error.localizedDescription
            )
        }
    }

    func cancel(_ id: ModelID) {
        tasks[id]?.cancel()
        tasks[id] = nil
    }

    func cancelAll() {
        for id in ModelID.allCases { cancel(id) }
    }

    // MARK: - Manage

    /// Delete the installed graph (and any partial transfer) for one model.
    func remove(_ id: ModelID) {
        // Marked before cancelling: the task winding down must not write a status
        // over the removal once it notices, and `discarded` is what tells it so.
        discarded.insert(id)
        cancel(id)
        let spec = spec(id)
        try? FileManager.default.removeItem(at: fileURL(for: spec))
        try? FileManager.default.removeItem(at: partURL(for: spec))
        records[spec.fileName] = nil
        saveRecords()
        status[id] = .notInstalled
        onChanged?()
    }

    /// Recompute the hash from disk. `false` means the file was not usable and has
    /// been removed, so nothing downstream should be pointed at it.
    @discardableResult
    func verify(_ id: ModelID) -> Bool {
        let spec = spec(id)
        let file = fileURL(for: spec)
        guard FileManager.default.fileExists(atPath: file.path) else {
            status[id] = .notInstalled
            return false
        }
        status[id] = .verifying
        if sizeOnDisk(of: spec.fileName) == spec.byteCount, hashMatches(file, spec: spec) {
            records[spec.fileName] = Record(sha256: spec.sha256, bytes: spec.byteCount, installedAt: Date())
            saveRecords()
            status[id] = .installed
            return true
        }
        try? FileManager.default.removeItem(at: file)
        records[spec.fileName] = nil
        saveRecords()
        status[id] = .failed("The downloaded file did not match its checksum and was removed.")
        onChanged?()
        return false
    }

    // MARK: - Progress

    fileprivate func noteProgress(_ id: ModelID, bytes: Int64) {
        guard status(of: id).isBusy else { return }
        let total = spec(id).byteCount
        guard total > 0 else { return }
        status[id] = .downloading(min(1, max(0, Double(bytes) / Double(total))))
    }

    // MARK: - Files

    private func fileURL(for spec: ModelSpec) -> URL {
        directory.appendingPathComponent(spec.fileName, isDirectory: false)
    }

    private func partURL(for spec: ModelSpec) -> URL {
        directory.appendingPathComponent(spec.fileName + ".part", isDirectory: false)
    }

    private func ensureDirectory() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var url = directory
        try? url.setResourceValues(values)
    }

    private func sizeOnDisk(of name: String) -> Int64 {
        let url = directory.appendingPathComponent(name, isDirectory: false)
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// Move a verified part into place, record it, and report the resulting status.
    private func installVerified(part: URL, spec: ModelSpec) -> Status {
        guard sizeOnDisk(of: spec.fileName + ".part") == spec.byteCount else {
            return .failed("The download was incomplete.")
        }
        guard hashMatches(part, spec: spec) else {
            try? FileManager.default.removeItem(at: part)
            return .failed("The downloaded file did not match its checksum and was removed.")
        }
        let destination = fileURL(for: spec)
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: part, to: destination)
        } catch {
            return .failed(error.localizedDescription)
        }
        records[spec.fileName] = Record(sha256: spec.sha256, bytes: spec.byteCount, installedAt: Date())
        saveRecords()
        return .installed
    }

    private func hashMatches(_ url: URL, spec: ModelSpec) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return digest == spec.sha256
    }

    // MARK: - Sidecar

    private var recordsURL: URL {
        directory.appendingPathComponent("installed.json", isDirectory: false)
    }

    private func loadRecords() -> [String: Record] {
        guard let data = try? Data(contentsOf: recordsURL) else { return [:] }
        return (try? JSONDecoder().decode([String: Record].self, from: data)) ?? [:]
    }

    private func saveRecords() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: recordsURL, options: .atomic)
    }

    // MARK: - Formatting

    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}

enum AutomixModelError: LocalizedError {
    case badStatus(Int)

    var errorDescription: String? {
        switch self {
        case .badStatus(let code):
            return "The model server answered \(code). Try again in a moment."
        }
    }
}

/// Writes a response body onto the part file as it arrives, and reports progress.
///
/// A `URLSessionDataDelegate` rather than `URLSession.download(for:)` for one
/// reason: the download API only hands over a file once the body is complete, so an
/// interrupted transfer leaves nothing behind to resume from. Here every chunk is on
/// disk the moment it is received, which is what makes "Try again" continue a
/// 113 MB download instead of restarting it.
///
/// The response decides the file's fate: `206` appends to what is already there, and
/// `200` — a server that ignored the range — means the bytes on disk are the wrong
/// bytes and the file starts again from zero.
private final class PartWriter: NSObject, URLSessionDataDelegate {
    private let part: URL
    private let append: Bool
    private let onProgress: (Int64) -> Void

    private let lock = NSLock()
    private var handle: FileHandle?
    private var opened = false
    private var written: Int64 = 0
    private var base: Int64
    private var continuation: CheckedContinuation<Void, Error>?
    private var finished: Result<Void, Error>?

    init(part: URL, append: Bool, initial: Int64, onProgress: @escaping (Int64) -> Void) {
        self.part = part
        self.append = append
        self.base = initial
        self.onProgress = onProgress
    }

    /// Hand the delegate the continuation the transfer will resolve. A delegate can
    /// finish before this is called — a refused request does exactly that — so the
    /// result is parked and delivered on attach rather than dropped.
    func attach(_ continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        if let finished {
            lock.unlock()
            continuation.resume(with: finished)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    private func finish(_ result: Result<Void, Error>) {
        lock.lock()
        if let continuation {
            self.continuation = nil
            lock.unlock()
            continuation.resume(with: result)
        } else if finished == nil {
            // Parked for a continuation that has not been attached yet. A second
            // result — the task's own completion after a cancelled 416 — is dropped
            // rather than replacing the first.
            finished = result
            lock.unlock()
        } else {
            lock.unlock()
        }
    }

    // MARK: URLSessionDataDelegate

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 || code == 206 || code == 416 else {
            completionHandler(.cancel)
            finish(.failure(AutomixModelError.badStatus(code)))
            return
        }

        lock.lock()
        if code == 416 {
            // Nothing more to send: whatever is on disk is what there is, and the
            // checksum is the only thing that gets to judge it.
            lock.unlock()
            completionHandler(.cancel)
            finish(.success(()))
            return
        }
        if code == 200 {
            // A full body where a range was asked for: start the file over.
            base = 0
            written = 0
            openHandle(truncate: true)
        } else {
            openHandle(truncate: !append)
        }
        lock.unlock()

        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        let target = handle
        written += Int64(data.count)
        let reached = base + written
        lock.unlock()

        guard let target else { return }
        do {
            try target.write(contentsOf: data)
        } catch {
            finish(.failure(error))
            return
        }
        onProgress(reached)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        closeHandle()
        if let error {
            finish(.failure(error))
        } else {
            finish(.success(()))
        }
    }

    /// Caller holds ``lock``.
    private func openHandle(truncate: Bool) {
        guard !opened else { return }
        opened = true
        if truncate {
            FileManager.default.createFile(atPath: part.path, contents: nil)
            base = 0
        }
        guard let file = try? FileHandle(forWritingTo: part) else { return }
        if !truncate {
            _ = try? file.seekToEnd()
        }
        handle = file
    }

    private func closeHandle() {
        lock.lock()
        let file = handle
        handle = nil
        lock.unlock()
        try? file?.close()
    }
}
