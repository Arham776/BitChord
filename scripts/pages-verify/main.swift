import Foundation

final class Generation: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64 = 1
    func get() -> Int64 { lock.lock(); defer { lock.unlock() }; return value }
    func advance() { lock.lock(); value += 1; lock.unlock() }
}
actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}
struct Fixture: Codable, Sendable { let title: String; let continuation: String? }
func expect(_ condition: Bool, _ message: String) {
    guard condition else { fatalError(message) }
    print("PASS \(message)")
}
@main struct Verify {
    static func main() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let gen = Generation()
        let context = PageContext(identity: "account-a:channel-a", generation: 1, locale: "en", region: "US")
        let other = PageContext(identity: "account-b:channel-a", generation: 1, locale: "en", region: "US")
        let channel = PageContext(identity: "account-a:channel-b", generation: 1, locale: "en", region: "US")
        let locale = PageContext(identity: context.identity, generation: 1, locale: "fr", region: "FR")
        let repository = PageRepository(folder: folder)
        let data = try JSONEncoder().encode(Fixture(title: "Saved content", continuation: "current-token"))
        let requests = Counter()
        let started = ContinuousClock.now
        let result = try await repository.fetch("home", context: context, currentGeneration: { gen.get() }) {
            await requests.increment(); try await Task.sleep(for: .milliseconds(250)); return data
        }
        let cold = started.duration(to: .now)
        expect(result == data, "cold fetch returns network content")
        let warmStart = ContinuousClock.now
        let warm = try await repository.fetch("home", context: context, currentGeneration: { gen.get() }) {
            fatalError("A fresh cached page awaited the network")
        }
        let warmTime = warmStart.duration(to: .now)
        expect(warm == data, "warm page needs zero network requests")
        expect(await repository.saved("home", context: other) == nil, "accounts have separate caches")
        expect(await repository.saved("home", context: channel) == nil, "channels have separate caches")
        expect(await repository.saved("home", context: locale) == nil, "locale and region have separate caches")
        expect(await repository.saved("detail:other", context: context) == nil, "request parameters have separate caches")
        let disk = PageRepository(folder: folder)
        let saved = await disk.saved("home", context: context)
        expect(saved != nil && saved?.fresh == false, "disk content appears before background refresh")
        expect(try JSONDecoder().decode(Fixture.self, from: saved!.data).continuation == nil, "disk never restores continuation tokens")
        let changed = PageContext(identity: context.identity, generation: 2, locale: "en", region: "US")
        let old = await repository.saved("home", context: changed)
        expect(try JSONDecoder().decode(Fixture.self, from: old!.data).continuation == nil, "new session cannot use an old memory token")
        do {
            _ = try await disk.fetch("home", context: context, force: true, currentGeneration: { gen.get() }) { throw URLError(.notConnectedToInternet) }
            fatalError("offline refresh succeeded")
        } catch { expect(await disk.saved("home", context: context) != nil, "offline refresh preserves saved content") }
        let coalesced = Counter()
        try await withThrowingTaskGroup(of: Data.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    try await repository.fetch("explore", context: context, force: true, currentGeneration: { gen.get() }) {
                        await coalesced.increment(); try await Task.sleep(for: .milliseconds(80)); return data
                    }
                }
            }
            for try await _ in group {}
        }
        expect(await coalesced.value == 1, "eight identical requests coalesce into one")
        let obsolete = Task {
            try await repository.fetch("obsolete", context: context, force: true, currentGeneration: { gen.get() }) {
                try await Task.sleep(for: .milliseconds(40)); gen.advance(); return data
            }
        }
        do { _ = try await obsolete.value; fatalError("obsolete response escaped") }
        catch { expect(await repository.saved("obsolete", context: context) == nil, "account switch prevents response and cache write") }
        let newContext = PageContext(identity: context.identity, generation: gen.get(), locale: "en", region: "US")
        let mutation = Task {
            try await repository.fetch("mutation", context: newContext, force: true, currentGeneration: { gen.get() }) {
                try? await Task.sleep(for: .milliseconds(100)); return data
            }
        }
        try await Task.sleep(for: .milliseconds(10))
        await repository.invalidate(partition: context.partition)
        do { _ = try await mutation.value; fatalError("invalidated response escaped") }
        catch { expect(await repository.saved("mutation", context: newContext) == nil, "mutation invalidation prevents cache refill") }
        expect(await repository.saved("home", context: context) == nil, "sign-out removes affected content")
        await repository.store(data, name: "corrupt", context: context)
        for url in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
            try Data("corrupt".utf8).write(to: url)
        }
        let corrupted = PageRepository(folder: folder)
        expect(await corrupted.saved("corrupt", context: context) == nil, "corrupt cache files are misses")
        let boundedFolder = folder.appendingPathComponent("bounded")
        let bounded = PageRepository(folder: boundedFolder, byteLimit: 1000)
        for i in 0..<10 { await bounded.store(data, name: "page-\(i)", context: context) }
        let sizes = try FileManager.default.contentsOfDirectory(at: boundedFolder, includingPropertiesForKeys: [.fileSizeKey])
            .map { (try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
        expect(sizes.reduce(0,+) <= 1000, "disk cache obeys its byte budget")
        let stale = PageRepository(folder: folder.appendingPathComponent("stale"), freshness: 0)
        await stale.store(data, name: "detail", context: context)
        let staleHit = await stale.saved("detail", context: context)
        expect(staleHit?.fresh == false, "expired pages refresh even within one session")
        expect(try JSONDecoder().decode(Fixture.self, from: staleHit!.data).continuation == nil, "expired parent cannot supply pagination tokens")
        print("Release fixture: cold=\(cold), warm=\(warmTime), cold requests=\(await requests.value), warm requests=0, concurrent requests=8→1")
    }
}
