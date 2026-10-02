import Foundation

/// Always fetch fresh data; only simultaneous identical requests are shared.
@MainActor
enum PageRequests {
    static func load<T: Sendable>(
        _ name: String, force: Bool = false,
        network: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let context = PageSession.capture()
        let value: T = try await PageRequestCoordinator.shared.fetch(name, context: context,
            currentGeneration: { PageSession.generation() }, network: network)
        guard PageSession.generation() == context.generation else { throw CancellationError() }
        Task { await LaunchReadiness.shared.contentAppeared() }
        return value
    }
}
