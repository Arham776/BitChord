import Foundation
import Observation

extension Notification.Name {
    static let pageCacheUpdated = Notification.Name("BitChord.pageCacheUpdated")
}

/// Read-through cache for one-result bridges. A stale hit is immediately usable;
/// the background refresh notifies interested views when replacement data lands.
@MainActor
enum CachedPages {
    static func load<T: Codable & Sendable>(
        _ name: String, force: Bool = false,
        network: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let context = PageSession.capture()
        let repository = PageRepository.shared
        let cached = force ? nil : await repository.saved(name, context: context)
        guard PageSession.generation() == context.generation else { throw CancellationError() }
        if let cached, let value = try? JSONDecoder().decode(T.self, from: cached.data) {
            if !cached.fresh {
                CacheStatus.shared.saved.insert(name)
                Task {
                    do {
                        _ = try await fetch(name, context: context, network: network)
                        guard PageSession.generation() == context.generation else { return }
                        CacheStatus.shared.saved.remove(name)
                        CacheStatus.shared.failures.removeValue(forKey: name)
                        NotificationCenter.default.post(name: .pageCacheUpdated, object: name)
                    } catch {
                        guard PageSession.generation() == context.generation else { return }
                        CacheStatus.shared.failures[name] = error.localizedDescription
                    }
                }
            }
            Task { await LaunchReadiness.shared.contentAppeared() }
            try Task.checkCancellation()
            return value
        }
        do {
            return try await fetch(name, context: context, network: network)
        } catch {
            guard PageSession.generation() == context.generation, !Task.isCancelled else { throw CancellationError() }
            if let previous = await repository.saved(name, context: context),
               (try? JSONDecoder().decode(T.self, from: previous.data)) != nil {
                CacheStatus.shared.saved.insert(name)
                CacheStatus.shared.failures[name] = error.localizedDescription
            }
            throw error
        }
    }

    private static func fetch<T: Codable & Sendable>(
        _ name: String, context: PageContext,
        network: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let data = try await PageRepository.shared.fetch(name, context: context, force: true,
            currentGeneration: { PageSession.generation() }) { try JSONEncoder().encode(try await network()) }
        guard PageSession.generation() == context.generation else { throw CancellationError() }
        CacheStatus.shared.saved.remove(name)
        CacheStatus.shared.failures.removeValue(forKey: name)
        Task { await LaunchReadiness.shared.contentAppeared() }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

@MainActor @Observable
final class CacheStatus {
    static let shared = CacheStatus()
    var saved: Set<String> = []
    var failures: [String: String] = [:]
    func reset() { saved.removeAll(); failures.removeAll() }
}
