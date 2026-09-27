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
    /// Upstream `swapCurrentToVersion`'s `swapCrossfadeMs`: the equal-power
    /// crossfade the engine runs between the old and the new source of the same
    /// recording. Long enough to hide a decoder swap, short enough that a
    /// same-timeline blend never reads as an edit.
    static let swapCrossfadeSeconds: Double = 0.55

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
        let snapshot = store.lock.withLock { () -> (Task<Candidate?, Never>?, Format?)? in
            guard let waiting = store.pending[mediaId] else { return nil }
            return (waiting.inFlight, waiting.playing)
        }
        guard let (inFlight, playing) = snapshot else { return nil }

        var found: Candidate?
        var answered = false
        defer {
            if answered {
                store.lock.withLock {
                    store.pending.removeValue(forKey: mediaId)
                    store.asked.insert(mediaId)
                }
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

    /**
     * Puts a track the app had written off back on the automatic path, because
     * the listener asked for it by hand.
     *
     * Two things are cleared, and the difference matters. `refused` is the
     * "this upgrade broke, leave it alone for the session" mark, and it is the
     * one a by-hand request overrides — the listener has now said they want
     * another look, which is the thing that mark stands in the way of. `upgraded`
     * is *not* cleared: a track that already swapped to a better copy has had
     * its turn, and re-running the search on it would find the same copy and
     * swap to it again.
     */
    static func askByHand(_ mediaId: String) {
        store.lock.lock(); defer { store.lock.unlock() }
        store.refused.remove(mediaId)
        store.auditioning.remove(mediaId)
        // Anything found by the automatic search is shelved precisely so a
        // failed swap can be taken back. A by-hand request wants the fresh
        // answer, not the one that was already judged and set aside.
        store.shelved.removeValue(forKey: mediaId)
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
        // The judgement itself lives in the shared module, so the host cannot
        // drift from it. This used to be a second copy here, and the copies
        // disagreed in two ways that both mattered: this one had no Dolby-Atmos rule
        // (so a lossless FLAC could be cut over an immersive mix the listener had
        // chosen), and an unknown candidate bitrate was treated as no rather than
        // as a source that declined to describe itself.
        guard let candidateJson = formatJSON(candidate) else { return false }
        return SourceResolverBridge.shared.worthSwapping(
            candidateJson: candidateJson,
            playingJson: playing.flatMap(formatJSON)
        )
    }

    static func sameRecordingAs(_ candidateSec: Int?, _ playingSec: Int?) -> Bool {
        // The shared signature is `Int?` (a nullable boxed `Int32`), so the bridge
        // takes an optional boxed integer and Swift will not silently widen a nil
        // into a zero — which would read as "both runtimes are 0s, so they agree".
        SourceResolverBridge.shared.sameRecordingAs(
            candidateSec: candidateSec.map { KotlinInt(value: Int32($0)) },
            playingSec: playingSec.map { KotlinInt(value: Int32($0)) }
        )
    }

    /**
     * Whether a source ranked above YouTube is enabled — the real check.
     *
     * This used to read three settings keys and answer true if *any* of them was
     * set, including a source ranked below YouTube. So every queued YouTube track
     * paid a pointless cross-source race for a source that could not have won it,
     * and a user with only YouTube enabled was asked the question as though they
     * had configured something.
     *
     * Answerable from the source list alone, with no search, which is what lets the
     * read-ahead ask it before anyone has looked anything up.
     */
    static func canSubstituteForYouTube() -> Bool {
        SourceResolverBridge.shared.canSubstituteForYouTube()
    }

    /// A [Format] as the shared module's `FormatDocument`.
    private static func formatJSON(_ format: Format) -> String? {
        guard let data = try? JSONEncoder().encode(
            FormatDocument(
                codec: format.codec,
                kbps: format.kbps,
                isLossless: format.lossless ? true : nil
            )
        ) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// The subset of the shared module's `FormatDocument` the host sends back.
private struct FormatDocument: Encodable {
    var codec: String?
    var kbps: Int?
    var isLossless: Bool?
}
