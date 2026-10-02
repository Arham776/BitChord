import Foundation
import CryptoKit

/// Request identity contains no credentials.
struct PageContext: Sendable, Equatable {
    let identity: String
    let generation: Int64
    let locale: String
    let region: String

    var partition: String {
        PageRequestCoordinator.digest([identity, locale, region].joined(separator: "\u{0}"))
    }
}

/// Shares only requests currently running. Completed page data is never retained.
actor PageRequestCoordinator {
    static let shared = PageRequestCoordinator()
    private struct Flight { let id: UUID; let task: Task<any Sendable, Error> }
    private var flights: [String: Flight] = [:]
    private var revision: UInt64 = 0
    nonisolated static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    func fetch<T: Sendable>(_ name: String, context: PageContext, force: Bool = false,
               currentGeneration: @escaping @Sendable () -> Int64,
               network: @escaping @Sendable () async throws -> T) async throws -> T {
        guard currentGeneration() == context.generation else { throw CancellationError() }
        let key = context.partition + ":\(context.generation):" + name + ":" + String(reflecting: T.self)
        let version = revision
        let flight: Flight
        if let existing = flights[key] { flight = existing }
        else {
            flight = Flight(id: UUID(), task: Task { try await network() })
            flights[key] = flight
        }
        defer { if flights[key]?.id == flight.id { flights.removeValue(forKey: key) } }
        let data = try await flight.task.value
        try Task.checkCancellation()
        guard currentGeneration() == context.generation, version == revision else { throw CancellationError() }
        guard let value = data as? T else { throw URLError(.cannotDecodeContentData) }
        return value
    }
    func invalidate(partition: String? = nil) {
        revision &+= 1
        flights.values.forEach { $0.task.cancel() }; flights.removeAll()
    }
    /// One-time removal of the retired page cache, outside the main actor.
    func removeLegacyCache() {
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BitChord/pages-v1", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
    }
}
