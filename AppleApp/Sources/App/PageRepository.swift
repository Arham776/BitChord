import Foundation
import CryptoKit
import os

/// Values in the cache identify the listener, never their credentials.
struct PageContext: Sendable, Equatable {
    let identity: String
    let generation: Int64
    let locale: String
    let region: String

    var partition: String {
        PageRepository.digest([identity, locale, region].joined(separator: "\u{0}"))
    }
}

struct SavedPage: Sendable {
    let data: Data
    let date: Date
    let fresh: Bool
}

/// Shared by every page. Actor isolation coalesces requests and serializes disk
/// writes; disk work runs outside the main actor. Pagination stays memory-only.
actor PageRepository {
    static let shared = PageRepository()
    private struct Envelope: Codable {
        let version: Int
        let partition: String
        let date: Date
        let data: Data
    }
    private struct Flight {
        let id: UUID
        let task: Task<Data, Error>
    }
    private let folder: URL
    private let byteLimit: Int
    private let freshness: TimeInterval
    private var memory: [String: Envelope] = [:]
    private var memoryGenerations: [String: Int64] = [:]
    private var flights: [String: Flight] = [:]
    private var revision: UInt64 = 0
    struct Statistics: Sendable { let cacheHits: Int; let networkRequests: Int; let coalescedRequests: Int }
    private var cacheHits = 0
    private var networkRequests = 0
    private var coalescedRequests = 0
    func statistics() -> Statistics {
        Statistics(cacheHits: cacheHits, networkRequests: networkRequests, coalescedRequests: coalescedRequests)
    }
    private static let log = Logger(subsystem: AppIdentity.bundleIdentifier, category: "loading")

    init(folder: URL? = nil, byteLimit: Int = 20 * 1024 * 1024, freshness: TimeInterval = 300) {
        self.folder = folder ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BitChord/pages-v1", isDirectory: true)
        self.byteLimit = byteLimit
        self.freshness = freshness
    }

    nonisolated static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private func key(_ name: String, _ context: PageContext) -> String {
        Self.digest(context.partition + "\u{0}" + name)
    }
    private func file(_ key: String) -> URL { folder.appendingPathComponent(key + ".json") }

    func saved(_ name: String, context: PageContext) -> SavedPage? {
        let key = key(name, context)
        let envelope: Envelope
        if let hit = memory[key] { envelope = hit }
        else {
            guard let bytes = try? Data(contentsOf: file(key)),
                  let decoded = try? JSONDecoder().decode(Envelope.self, from: bytes),
                  decoded.version == 1, decoded.partition == context.partition else { return nil }
            envelope = decoded
            memory[key] = decoded
        }
        let age = Date().timeIntervalSince(envelope.date)
        cacheHits += 1
        Self.log.debug("page cache hit: \(name, privacy: .private)")
        let fresh = memoryGenerations[key] == context.generation && age >= 0 && age < freshness
        return SavedPage(data: fresh ? envelope.data : contentOnly(envelope.data), date: envelope.date, fresh: fresh)
    }

    private func contentOnly(_ data: Data) -> Data {
        guard var json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return data }
        json.removeValue(forKey: "continuation")
        return (try? JSONSerialization.data(withJSONObject: json)) ?? data
    }

    func cacheRevision() -> UInt64 { revision }

    func store(_ data: Data, name: String, context: PageContext,
               expectedRevision: UInt64? = nil, currentGeneration: (@Sendable () -> Int64)? = nil) {
        guard expectedRevision == nil || expectedRevision == revision,
              currentGeneration == nil || currentGeneration?() == context.generation else { return }
        // Persist content only. Server tokens cannot survive a parent refresh.
        let content = contentOnly(data)
        let envelope = Envelope(version: 1, partition: context.partition, date: Date(), data: data)
        let key = key(name, context)
        memory[key] = envelope
        memoryGenerations[key] = context.generation
        if memory.count > 128, let oldest = memory.min(by: { $0.value.date < $1.value.date })?.key {
            memory.removeValue(forKey: oldest)
            memoryGenerations.removeValue(forKey: oldest)
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var root = folder
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try root.setResourceValues(values)
            let diskEnvelope = Envelope(version: 1, partition: envelope.partition, date: envelope.date, data: content)
            let encoded = try JSONEncoder().encode(diskEnvelope)
            try encoded.write(to: file(key), options: .atomic)
            #if os(iOS)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: file(key).path)
            #endif
            trim()
        } catch { Self.log.debug("page cache write unavailable") }
    }

    func fetch(_ name: String, context: PageContext, force: Bool = false,
               currentGeneration: @escaping @Sendable () -> Int64,
               network: @escaping @Sendable () async throws -> Data) async throws -> Data {
        guard currentGeneration() == context.generation else { throw CancellationError() }
        if !force, let cached = saved(name, context: context), cached.fresh { return cached.data }
        let key = key(name, context) + ":\(context.generation)"
        let flight: Flight
        if let existing = flights[key] { flight = existing; coalescedRequests += 1 }
        else {
            networkRequests += 1
            flight = Flight(id: UUID(), task: Task { try await network() })
            flights[key] = flight
        }
        let started = ContinuousClock.now
        let version = revision
        do {
            let data = try await flight.task.value
            guard currentGeneration() == context.generation, version == revision else { throw CancellationError() }
            if flights[key]?.id == flight.id {
                flights.removeValue(forKey: key)
                store(data, name: name, context: context, expectedRevision: version, currentGeneration: currentGeneration)
                Self.log.debug("page fetch \(String(describing: started.duration(to: .now)), privacy: .public), requests=\(self.networkRequests) hits=\(self.cacheHits) coalesced=\(self.coalescedRequests)")
            }
            try Task.checkCancellation()
            return data
        } catch {
            if flights[key]?.id == flight.id { flights.removeValue(forKey: key) }
            throw error
        }
    }

    /// In-flight responses cannot refill a cache cleared by a mutation/sign-out.
    func invalidate(partition: String? = nil) {
        revision &+= 1
        memoryGenerations.removeAll()
        flights.values.forEach { $0.task.cancel() }; flights.removeAll()
        memory = memory.filter { partition != nil && $0.value.partition != partition }
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return }
        for url in files {
            if let partition {
                guard let data = try? Data(contentsOf: url),
                      let entry = try? JSONDecoder().decode(Envelope.self, from: data),
                      entry.partition == partition else { continue }
            }
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func trim() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else { return }
        let entries = files.compactMap { url -> (URL, Int, Date)? in
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
            return (url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
        }.sorted { $0.2 < $1.2 }
        var size = entries.reduce(0) { $0 + $1.1 }
        for (url, bytes, _) in entries where size > byteLimit {
            try? FileManager.default.removeItem(at: url); size -= bytes
        }
    }
}
