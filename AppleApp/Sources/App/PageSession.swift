import Foundation
import BitChordShared

@MainActor
enum PageSession {
    private static var cached: PageContext?
    static func reset() { cached = nil }
    static func capture() -> PageContext {
        let generation = generation()
        if let cached, cached.generation == generation { return cached }
        let selection = AccountStore.shared.activeSelection()
        let currentCookie = Innertube.shared.cookie
        let identity: String
        if let selection, selection.account.cookie == currentCookie {
            identity = selection.account.accountId + ":" + selection.profile.profileId
        } else if let cookie = currentCookie {
            // A sign-in candidate cannot write into the previous account's cache.
            identity = "legacy:" + PageRepository.digest(cookie)
        } else {
            identity = AuthStore.isLocked ? "locked" : "guest"
        }
        let context = PageContext(identity: identity, generation: generation, locale: "en", region: "US")
        cached = context
        return context
    }
    nonisolated static func generation() -> Int64 { AuthBridge.shared.sessionGeneration() }
    static func invalidate() {
        let partition = capture().partition
        Task { await PageRepository.shared.invalidate(partition: partition) }
    }
}
