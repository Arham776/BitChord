import AVFoundation
import Foundation
#if canImport(UIKit)
import UIKit
#endif

#if canImport(MusicUnderstanding)
import MusicUnderstanding
#endif

/// On-device Music Understanding → Automix analysis overlay.
///
/// Available on iOS 27 / macOS 27+. Older OS versions no-op and leave the
/// Rust DSP / Beat This path alone.
///
/// GPU note: Music Understanding runs Core ML / MPS graph work. That asserts
/// (and can abort the process) when the app is backgrounded, and Apple's
/// `InstrumentActivityModel` has been observed to hard-crash with
/// `shape for TensorData is not static`. We therefore only analyze in the
/// foreground and never request `.instrumentActivity`.
enum MusicUnderstandingAnalyzer {
    /// True when the current OS can run Music Understanding analysis.
    static var isAvailable: Bool {
        if #available(iOS 27.0, macOS 27.0, tvOS 27.0, watchOS 27.0, visionOS 27.0, *) {
            return true
        }
        return false
    }

    /// Analyze a local file and seed the native Automix overlay cache.
    /// Returns true when an overlay was seeded.
    @discardableResult
    static func analyzeAndSeed(filePath: String) async -> Bool {
        guard isAvailable else {
            return AutomixOverlayCache.seedCached(forFilePath: filePath)
        }
        let path = filePath.hasPrefix("file://")
            ? (URL(string: filePath)?.path ?? filePath)
            : filePath
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else {
            return false
        }
        // Prefer a fresh Music Understanding pass while foregrounded; otherwise
        // (or on failure) fall back to the disk cache so Automix still plans.
        if #available(iOS 27.0, macOS 27.0, tvOS 27.0, watchOS 27.0, visionOS 27.0, *),
           await isForeground()
        {
            if await analyzeAvailable(path: path) {
                return true
            }
        }
        return AutomixOverlayCache.seedCached(forFilePath: path)
    }

    /// Music Understanding needs GPU; never start a session off-screen.
    private static func isForeground() async -> Bool {
        #if canImport(UIKit)
        await MainActor.run {
            UIApplication.shared.applicationState == .active
        }
        #else
        true
        #endif
    }

    @available(iOS 27.0, macOS 27.0, tvOS 27.0, watchOS 27.0, visionOS 27.0, *)
    private static func analyzeAvailable(path: String) async -> Bool {
        #if canImport(MusicUnderstanding)
        // Re-check right before GPU work — the first await can race a lock.
        guard await isForeground() else { return false }
        do {
            let url = URL(fileURLWithPath: path)
            let asset = AVURLAsset(
                url: url,
                options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
            )
            let session = try await MusicUnderstandingSession(asset: asset)
            guard await isForeground() else { return false }
            // Omit `.instrumentActivity` — its MPS graph aborts the process.
            // Omit `.pace` for the same Metal family until Apple stabilizes it.
            let result = try await session.analyze(for: [
                .rhythm, .key, .structure, .loudness,
            ])
            let overlay = overlay(from: result)
            AutomixOverlayCache.store(overlay, forFilePath: path)
            return seedAutomixAnalysis(path: path, overlay: overlay)
        } catch {
            NSLog("[BitChord] Music Understanding failed for %@: %@", path, String(describing: error))
            return false
        }
        #else
        return false
        #endif
    }

    #if canImport(MusicUnderstanding)
    @available(iOS 27.0, macOS 27.0, tvOS 27.0, watchOS 27.0, visionOS 27.0, *)
    private static func overlay(from result: MusicUnderstandingSession.SessionResult) -> AutomixAnalysisOverlayRec {
        var bpm: Double?
        var beatConfidence: Double?
        var beatInterval: Double?
        var beats: [Double]?
        var downbeats: [Double]?
        if let rhythm = result.rhythm {
            if let value = rhythm.beatsPerMinute, value.isFinite, value > 0 {
                bpm = Double(value)
                beatInterval = 60.0 / Double(value)
                beatConfidence = 0.85
            }
            let beatTimes = rhythm.beats.compactMap { cmSeconds($0) }
            if beatTimes.count >= 2 {
                beats = beatTimes
                if bpm == nil {
                    let span = beatTimes.last! - beatTimes.first!
                    if span > 0 {
                        bpm = Double(beatTimes.count - 1) * 60.0 / span
                        beatInterval = 60.0 / bpm!
                        beatConfidence = 0.7
                    }
                }
            }
            let barTimes = rhythm.bars.compactMap { cmSeconds($0) }
            if !barTimes.isEmpty {
                downbeats = barTimes
            }
        }

        var key: String?
        var keyConfidence: Double?
        if let keyResult = result.key, let first = keyResult.ranges.first {
            key = "\(tonicName(first.value.tonic)) \(first.value.mode == .minor ? "minor" : "major")"
            keyConfidence = 0.8
        }

        var phrases: [Double]?
        var mixIn: Double?
        var outro: Double?
        var audibleStart: Double?
        var contentEnd: Double?
        if let structure = result.structure {
            let phraseStarts = structure.phrases.compactMap { cmSeconds($0.start) }
            if !phraseStarts.isEmpty {
                phrases = phraseStarts
            }
            if let firstSection = structure.sections.first {
                audibleStart = cmSeconds(firstSection.start)
                mixIn = cmSeconds(firstSection.end)
            }
            if let lastSection = structure.sections.last {
                outro = cmSeconds(lastSection.start)
                contentEnd = cmSeconds(lastSection.end)
            }
            if let firstPhrase = structure.phrases.first {
                audibleStart = audibleStart ?? cmSeconds(firstPhrase.start)
            }
        }

        // Vocal probability comes from Rust / Beat This — InstrumentActivity
        // is intentionally not requested (see analyzeAvailable).
        let vocalProbability: Double? = nil

        return AutomixAnalysisOverlayRec(
            bpm: bpm,
            beatConfidence: beatConfidence,
            beatInterval: beatInterval,
            beats: beats,
            downbeats: downbeats,
            key: key,
            keyConfidence: keyConfidence,
            phraseBoundaries: phrases,
            vocalProbability: vocalProbability,
            contentEnd: contentEnd,
            audibleStart: audibleStart,
            outroStart: outro,
            mixInTime: mixIn,
            source: "music_understanding"
        )
    }

    @available(iOS 27.0, macOS 27.0, tvOS 27.0, watchOS 27.0, visionOS 27.0, *)
    private static func cmSeconds(_ time: CMTime) -> Double? {
        guard time.isValid, !time.isIndefinite else { return nil }
        let seconds = CMTimeGetSeconds(time)
        guard seconds.isFinite, seconds >= 0 else { return nil }
        return seconds
    }

    @available(iOS 27.0, macOS 27.0, tvOS 27.0, watchOS 27.0, visionOS 27.0, *)
    private static func tonicName(_ tonic: KeyResult.Tonic) -> String {
        switch tonic {
        case .c: return "C"
        case .cSharp: return "C♯"
        case .dFlat: return "D♭"
        case .d: return "D"
        case .dSharp: return "D♯"
        case .eFlat: return "E♭"
        case .e: return "E"
        case .f: return "F"
        case .fSharp: return "F♯"
        case .gFlat: return "G♭"
        case .g: return "G"
        case .gSharp: return "G♯"
        case .aFlat: return "A♭"
        case .a: return "A"
        case .aSharp: return "A♯"
        case .bFlat: return "B♭"
        case .b: return "B"
        @unknown default: return "C"
        }
    }
    #endif
}
