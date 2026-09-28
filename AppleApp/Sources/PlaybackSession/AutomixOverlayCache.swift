import Foundation

/// Persists Automix analysis overlays (Music Understanding / future disk MIR)
/// under Application Support so a track is not re-analysed every session.
enum AutomixOverlayCache {
    private static let folderName = "AutomixOverlays"

    private static var directory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("BitChord", isDirectory: true)
            .appendingPathComponent(folderName, isDirectory: true)
    }

    /// Seed a previously cached overlay for `path` into the native engine.
    @discardableResult
    static func seedCached(forFilePath path: String) -> Bool {
        guard let overlay = load(forFilePath: path) else { return false }
        return seedAutomixAnalysis(path: path, overlay: overlay)
    }

    static func store(_ overlay: AutomixAnalysisOverlayRec, forFilePath path: String) {
        guard let url = cacheURL(forFilePath: path) else { return }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(CodableOverlay(overlay))
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("[BitChord] overlay cache write failed: %@", String(describing: error))
        }
    }

    static func load(forFilePath path: String) -> AutomixAnalysisOverlayRec? {
        guard let url = cacheURL(forFilePath: path),
              let data = try? Data(contentsOf: url),
              let coded = try? JSONDecoder().decode(CodableOverlay.self, from: data)
        else { return nil }
        return coded.asRec()
    }

    private static func cacheURL(forFilePath path: String) -> URL? {
        guard let directory else { return nil }
        let normalized = path.hasPrefix("file://")
            ? (URL(string: path)?.path ?? path)
            : path
        let digest = normalized.data(using: .utf8).map { data -> String in
            var hash: UInt64 = 5381
            for byte in data {
                hash = ((hash << 5) &+ hash) &+ UInt64(byte)
            }
            return String(hash, radix: 16)
        } ?? "unknown"
        return directory.appendingPathComponent("\(digest).json")
    }
}

/// Codable mirror of `AutomixAnalysisOverlayRec` for disk persistence.
private struct CodableOverlay: Codable {
    var bpm: Double?
    var beatConfidence: Double?
    var beatInterval: Double?
    var beats: [Double]?
    var downbeats: [Double]?
    var key: String?
    var keyConfidence: Double?
    var phraseBoundaries: [Double]?
    var vocalProbability: Double?
    var contentEnd: Double?
    var audibleStart: Double?
    var outroStart: Double?
    var mixInTime: Double?
    var source: String

    init(_ rec: AutomixAnalysisOverlayRec) {
        bpm = rec.bpm
        beatConfidence = rec.beatConfidence
        beatInterval = rec.beatInterval
        beats = rec.beats
        downbeats = rec.downbeats
        key = rec.key
        keyConfidence = rec.keyConfidence
        phraseBoundaries = rec.phraseBoundaries
        vocalProbability = rec.vocalProbability
        contentEnd = rec.contentEnd
        audibleStart = rec.audibleStart
        outroStart = rec.outroStart
        mixInTime = rec.mixInTime
        source = rec.source
    }

    func asRec() -> AutomixAnalysisOverlayRec {
        AutomixAnalysisOverlayRec(
            bpm: bpm,
            beatConfidence: beatConfidence,
            beatInterval: beatInterval,
            beats: beats,
            downbeats: downbeats,
            key: key,
            keyConfidence: keyConfidence,
            phraseBoundaries: phraseBoundaries,
            vocalProbability: vocalProbability,
            contentEnd: contentEnd,
            audibleStart: audibleStart,
            outroStart: outroStart,
            mixInTime: mixInTime,
            source: source.isEmpty ? "disk_cache" : source
        )
    }
}
