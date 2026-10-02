import Foundation
final class Generation: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64 = 1
    func get() -> Int64 { lock.withLock { value } }
    func advance() { lock.withLock { value += 1 } }
}
actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}
@main struct Verify {
    static func main() async throws {
        let repository = PageRequestCoordinator()
        let gen = Generation()
        let context = PageContext(identity: "account:channel", generation: 1, locale: "en", region: "US")
        let requests = Counter()
        for _ in 0..<2 {
            let value: String = try await repository.fetch("home", context: context, currentGeneration: { gen.get() }) {
                await requests.increment(); return "fresh"
            }
            precondition(value == "fresh")
        }
        let count = await requests.value
        precondition(count == 2, "Completed pages must never be cached")
        let concurrent = Counter()
        try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    try await repository.fetch("explore", context: context, currentGeneration: { gen.get() }) {
                        await concurrent.increment(); try await Task.sleep(for: .milliseconds(100)); return "feed"
                    }
                }
            }
            for try await result in group { precondition(result == "feed") }
        }
        let coalesced = await concurrent.value
        precondition(coalesced == 1, "Concurrent identical reads must coalesce")
        do {
            let _: String = try await repository.fetch("home", context: context, currentGeneration: { gen.get() }) {
                throw URLError(.notConnectedToInternet)
            }
            fatalError("Offline read returned retained data")
        } catch let error as URLError { precondition(error.code == .notConnectedToInternet) }
        do {
            let _: String = try await repository.fetch("obsolete", context: context, currentGeneration: { gen.get() }) {
                gen.advance(); return "obsolete"
            }
            fatalError("Old account response escaped")
        } catch is CancellationError {}
        print("PASS fresh revisits, concurrent deduplication, offline errors, obsolete account rejection")
    }
}
