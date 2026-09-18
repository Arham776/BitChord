import Foundation
import BitChordShared

/// Mid-playback quality upgrade — Swift port of upstream `QualityUpgrade.kt`.
///
/// Play the first usable stream, keep looking for a better copy, and swap only
/// when the answer is the same recording *and* genuinely better. Every guard
/// errs toward not cutting the audio: a missed upgrade is quieter than an
/// interrupted song.
enum QualityUpgrade {
    static let marker = "q"
    static let upgraded = "hifi"
    static let minGainKbps = 96
    static let driftSec = 2
    static let minRemaining: TimeInterval = 20

    struct Format: Sendable, Equatable {
        var codec: String?
        var kbps: Int?
        var lossless: Bool

        var summary: String {
            if lossless { return codec.map { "\($0) · lossless" } ?? "lossless" }
            if let kbps { return "\(kbps) kbps" }
            return codec ?? "unmeasured"
        }

        static func isLosslessCodec(_ name: String?) -> Bool {
            guard let name else { return false }
            let lower = name.lowercased()
            return lower.contains("flac") || lower.contains("alac")
                || lower.contains("pcm") || lower.contains("wav")
                || lower.hasSuffix("raw")
        }
    }

    struct Candidate: Sendable {
        var url: String
        var headers: [String: String]
        var format: Format
        var durationSec: Int?
    }

    struct Target: Sendable {
        var title: String
        var artist: String
        var durationSec: Int?
    }

    private struct Pending {
        var target: Target
        var inFlight: Task<Candidate?, Never>?
        var playing: Format?
    }

    private final class Store: @unchecked Sendable {
        let lock = NSLock()
        var pending: [String: Pending] = [:]
        var forced: [String: Candidate] = [:]
        var shelved: [String: Candidate] = [:]
        var auditioning: Set<String> = []
        var refused: Set<String> = []
        var asked: Set<String> = []
        var upgraded: Set<String> = []
        var racing: Set<String> = []
    }

    private static let store = Store()

    static func beginAudition(_ mediaId: String) {
        store.lock.lock(); defer { store.lock.unlock() }
        store.auditioning.insert(mediaId)
    }

    static func endAudition(_ mediaId: String) {
        store.lock.lock(); defer { store.lock.unlock() }
        store.auditioning.remove(mediaId)
    }

    static func isAuditioning(_ videoId: String?) -> Bool {
        guard let videoId else { return false }
        store.lock.lock(); defer { store.lock.unlock() }
        return store.auditioning.contains(videoId)
    }

    static func shelve(_ mediaId: String, stream: Candidate) {
        store.lock.lock(); defer { store.lock.unlock() }
        store.shelved[mediaId] = stream
        store.asked.remove(mediaId)
    }

    static func shelvedFor(_ mediaId: String) -> Candidate? {
        store.lock.lock(); defer { store.lock.unlock() }
        return store.shelved[mediaId]
    }

    static func unshelve(_ mediaId: String) {
        store.lock.lock(); defer { store.lock.unlock() }
        store.shelved.removeValue(forKey: mediaId)
        store.upgraded.insert(mediaId)
    }

    static func settledForLess(
        mediaId: String,
        target: Target,
        inFlight: Task<Candidate?, Never>? = nil,
        playing: Format? = nil,
        canSubstitute: Bool
    ) -> Bool {
        if target.title.trimmingCharacters(in: .whitespaces).isEmpty
            || !canSubstitute
        {
            inFlight?.cancel()
            return false
        }
        store.lock.lock()
        if store.refused.contains(mediaId) {
            store.lock.unlock()
            inFlight?.cancel()
            return false
        }
        store.pending[mediaId] = Pending(target: target, inFlight: inFlight, playing: playing)
        store.racing.insert(mediaId)
        store.lock.unlock()
        return true
    }

    static func isPending(_ mediaId: String?) -> Bool {
        guard let mediaId else { return false }
        store.lock.lock(); defer { store.lock.unlock() }
        return store.pending[mediaId] != nil
    }

    static func isRacing(_ mediaId: String?) -> Bool {
        guard let mediaId else { return false }
        store.lock.lock(); defer { store.lock.unlock() }
        return store.racing.contains(mediaId)
    }

    static func refuseUpgrades(_ mediaId: String) {
        store.lock.lock(); defer { store.lock.unlock() }
        store.refused.insert(mediaId)
    }

    static func couldStillUpgrade(
        mediaId: String,
        canSubstitute: Bool
    ) -> Bool {
        store.lock.lock(); defer { store.lock.unlock() }
        if store.upgraded.contains(mediaId) { return false }
        if store.asked.contains(mediaId) || store.refused.contains(mediaId) { return false }
        if store.pending[mediaId] != nil { return false }
        return canSubstitute
    }

    static func adoptUnresolved(
        mediaId: String,
        target: Target,
        playingCodec: String?,
        playing: Format?,
        canSubstitute: Bool
    ) -> Bool {
        guard couldStillUpgrade(mediaId: mediaId, canSubstitute: canSubstitute) else {
            return false
        }
        if Format.isLosslessCodec(playingCodec) {
            store.lock.lock()
            store.asked.insert(mediaId)
            store.lock.unlock()
            return false
        }
        if target.title.trimmingCharacters(in: .whitespaces).isEmpty {
            store.lock.lock()
            store.asked.insert(mediaId)
            store.lock.unlock()
            return false
        }
        store.lock.lock()
        store.pending[mediaId] = Pending(target: target, inFlight: nil, playing: playing)
        store.racing.insert(mediaId)
        store.lock.unlock()
        return true
    }

    /// Looks for a stream that satisfies the request for a track already playing.
    /// `search` is the unhurried second look (every catalogue, no time limit).
    static func lookAgain(
        mediaId: String,
        playingDurationSec: Int?,
        search: () async -> Candidate?
    ) async -> Candidate? {
        store.lock.lock()
        guard let waiting = store.pending[mediaId] else {
            store.lock.unlock()
            return nil
        }
        let inFlight = waiting.inFlight
        let playing = waiting.playing
        store.lock.unlock()

        var found: Candidate?
        var answered = false
        defer {
            if answered {
                store.lock.lock()
                store.pending.removeValue(forKey: mediaId)
                store.asked.insert(mediaId)
                store.lock.unlock()
            }
            if found == nil {
                onRaceEnd(mediaId)
            }
        }

        if let lookup = inFlight {
            let late = await lookup.value
            if let late,
               worthSwapping(late.format, playing: playing),
               sameRecordingAs(late.durationSec, playingDurationSec)
            {
                found = late
                answered = true
                return late
            }
        }
        let next = await search()
        found = next
        answered = true
        return next
    }

    static func forget(_ mediaId: String) {
        store.lock.lock()
        let inflight = store.pending.removeValue(forKey: mediaId)?.inFlight
        store.forced.removeValue(forKey: mediaId)
        store.shelved.removeValue(forKey: mediaId)
        store.auditioning.remove(mediaId)
        store.racing.remove(mediaId)
        store.lock.unlock()
        inflight?.cancel()
    }

    static func forgetLastSession() {
        store.lock.lock()
        let ids = Set(store.pending.keys)
            .union(store.forced.keys)
            .union(store.shelved.keys)
            .union(store.auditioning)
        store.lock.unlock()
        ids.forEach(forget)
        store.lock.lock()
        store.asked.removeAll()
        store.refused.removeAll()
        store.upgraded.removeAll()
        store.lock.unlock()
    }

    static func force(_ mediaId: String, stream: Candidate) {
        store.lock.lock(); defer { store.lock.unlock() }
        store.forced[mediaId] = stream
    }

    static func forcedStream(_ mediaId: String) -> Candidate? {
        store.lock.lock(); defer { store.lock.unlock() }
        return store.forced[mediaId]
    }

    static func onRaceStart(_ mediaId: String) {
        store.lock.lock(); defer { store.lock.unlock() }
        store.racing.insert(mediaId)
    }

    static func onRaceEnd(_ mediaId: String) {
        store.lock.lock(); defer { store.lock.unlock() }
        store.racing.remove(mediaId)
    }

    static func worthSwapping(_ candidate: Format, playing: Format?) -> Bool {
        if candidate.lossless { return true }
        guard let cand = candidate.kbps, let floor = playing?.kbps else { return false }
        return cand - floor >= minGainKbps
    }

    static func sameRecordingAs(_ candidateSec: Int?, _ playingSec: Int?) -> Bool {
        guard let candidateSec, let playingSec else { return false }
        return abs(candidateSec - playingSec) <= driftSec
    }

    static func canSubstituteForYouTube() -> Bool {
        let jio = PlatformSettings.shared.getBoolean(key: "jiosaavn_enabled", default: true)
        let modules = PlatformSettings.shared.getString(key: "module_index_url", default: "")
        let custom = PlatformSettings.shared.getString(key: "custom_source_url", default: "")
        return jio || !modules.isEmpty || !custom.isEmpty
    }
}
