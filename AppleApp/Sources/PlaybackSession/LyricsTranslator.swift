import Foundation
import BitChordShared

/// Translation and romanisation of the lyric on screen.
///
/// Two separate actions, and the distinction is the whole point: a Japanese lyric
/// asked for *in English* is a translation, and the same lyric asked for *as
/// romaji* is a pronunciation. Offering one control for both produced requests
/// that could not be answered — a translation endpoint asked for a romanisation
/// returns a translation, which is the wrong answer presented confidently.
@MainActor
@Observable
final class LyricsTranslator {
    enum Mode: String, CaseIterable, Identifiable {
        case translate
        case romanize
        var id: String { rawValue }

        var title: String {
            switch self {
            case .translate: return "Translate"
            case .romanize: return "Romanise"
            }
        }

        var subtitle: String {
            switch self {
            case .translate: return "Show the words in another language"
            case .romanize: return "Show them in Latin script, as a pronunciation"
            }
        }

        var symbol: String {
            switch self {
            case .translate: return "character.bubble"
            case .romanize: return "textformat.abc"
            }
        }
    }

    struct Language: Identifiable, Hashable, Decodable {
        var code: String
        var name: String
        var romanizable: Bool
        var id: String { code }
    }

    /// What the last request produced, so the pane can say so.
    enum Outcome: Equatable {
        case idle
        case working
        /// Translated. [fromCache] distinguishes "already done" from "just now".
        case done(language: String, fromCache: Bool)
        /// The lyric was already in that language, or already in Latin script.
        case alreadyInLanguage(language: String)
        /// Nothing — an empty lyric, a failure, a language the endpoint lacks.
        ///
        /// Not an error, and not reported as one: this is a normal outcome and the
        /// pane says so plainly rather than showing a failure.
        case unavailable
    }

    private(set) var outcome: Outcome = .idle
    private(set) var translatedLines: [LyricLineDto]?

    private var translateLanguages: [Language] = []
    private var romanizeLanguages: [Language] = []
    private var loaded = false

    /// Languages for [mode], with the platform's own name where it has one.
    func languages(for mode: Mode) -> [Language] {
        let list = mode == .translate ? translateLanguages : romanizeLanguages
        return list.map { language in
            Language(
                code: language.code,
                // The platform's display name is localised into whatever the app is
                // set to, and the shared list's is not — so the platform's wins.
                name: Locale.current.localizedString(forIdentifier: language.code)
                    ?? language.name,
                romanizable: language.romanizable
            )
        }
    }

    /// Whether the lyric on screen is in a script that has a romanisation.
    ///
    /// A cheap all-Latin test, so the button can be absent rather than present
    /// and apologising — the overwhelmingly common case is a lyric that has
    /// nothing to romanise, and a control that always says "already romanised" is
    /// a control nobody needs.
    func canRomanize(lines: [LyricLineDto]) -> Bool {
        lines.contains { line in
            line.text.unicodeScalars.contains { scalar in
                CharacterSet.letters.contains(scalar) && !isLatin(scalar)
            }
        }
    }

    /// Run one translation or romanisation and hand back the new lines.
    func run(
        mode: Mode,
        target: Language,
        trackId: String,
        lines: [LyricLineDto],
        then: @escaping ([LyricLineDto]?) -> Void,
    ) {
        guard !lines.isEmpty else {
            outcome = .unavailable
            translatedLines = nil
            then(nil)
            return
        }
        guard let document = encode(lines) else {
            outcome = .unavailable
            then(nil)
            return
        }
        outcome = .working
        let settle: @Sendable (String, String, String, Bool) -> Void = { status, body, language, cached in
            Task { @MainActor in
                switch status {
                case "translated":
                    let decoded = self.decode(body)
                    self.translatedLines = decoded
                    self.outcome = .done(language: language, fromCache: cached)
                    then(decoded)
                case "same":
                    // Nothing to do, and nothing wrong. The original stays.
                    self.translatedLines = nil
                    self.outcome = language.isEmpty
                        ? .alreadyInLanguage(language: "")
                        : .alreadyInLanguage(language: language)
                    then(nil)
                default:
                    self.translatedLines = nil
                    self.outcome = .unavailable
                    then(nil)
                }
            }
        }
        let callback = TranslationAdapter(settle)
        if mode == .translate {
            LyricsBridge.shared.translate(
                trackId: trackId,
                linesJson: document,
                targetLanguageTag: target.code,
                callback: callback
            )
        } else {
            LyricsBridge.shared.romanize(
                trackId: trackId,
                linesJson: document,
                targetLanguageTag: target.code,
                callback: callback
            )
        }
    }

    /// Back to the lyric as fetched.
    func reset() {
        translatedLines = nil
        outcome = .idle
    }

    // MARK: - Plumbing

    func loadLanguages() {
        guard !loaded else { return }
        loaded = true
        guard let data = LyricsBridge.shared.languagesJson().data(using: .utf8),
              let listing = try? JSONDecoder().decode(LanguageListing.self, from: data)
        else { return }
        translateLanguages = listing.translate
        romanizeLanguages = listing.romanize
    }

    private struct LanguageListing: Decodable {
        let translate: [Language]
        let romanize: [Language]
    }

    private func encode(_ lines: [LyricLineDto]) -> String? {
        let document = LineList(lines: lines.map { Line(from: $0) })
        guard let data = try? JSONEncoder().encode(document) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func decode(_ document: String) -> [LyricLineDto]? {
        guard let data = document.data(using: .utf8),
              let list = try? JSONDecoder().decode(LineList.self, from: data)
        else { return nil }
        return list.lines.map { $0.toModel() }
    }

    // MARK: - Wire shape

    /**
     * The lyric as it crosses the bridge.
     *
     * A mirror rather than making [LyricLineDto] itself `Codable`: that type is a
     * Kotlin class, and its properties are not Swift `Codable` — a synthesised
     * conformance would not compile, and a hand-written one on an imported type is
     * not possible. So the shape is restated here, in the two directions, and the
     * two can be compared at a glance.
     */
    private struct LineList: Codable {
        let lines: [Line]
    }

    private final class Line: Codable {
        var timeMs: Int64
        var text: String
        var words: [Word]
        var sungUntilMs: Int64?
        var background: Line?

        struct Word: Codable {
            var startMs: Int64
            var endMs: Int64
            var text: String
        }

        // A class rather than a struct because the nesting is genuinely recursive
        // — a few provider formats put a background vocal inside a background
        // vocal — and a Swift value type cannot contain itself, not even through
        // another struct. Bounding it at one level instead would have meant picking
        // a depth nobody agreed to.

        init(from line: LyricLineDto) {
            timeMs = line.timeMs
            text = line.text
            words = line.words.map {
                Word(startMs: $0.startMs, endMs: $0.endMs, text: $0.text)
            }
            sungUntilMs = line.sungUntilMs?.int64Value
            background = line.background.map { Line(from: $0) }
        }

        func toModel() -> LyricLineDto {
            LyricLineDto(
                timeMs: timeMs,
                text: text,
                words: words.map {
                    LyricWordDto(startMs: $0.startMs, endMs: $0.endMs, text: $0.text)
                },
                sungUntilMs: sungUntilMs.map { KotlinLong(value: $0) },
                background: background?.toModel()
            )
        }
    }

    /// Whether a scalar is a letter outside the Latin blocks.
    private func isLatin(_ scalar: Unicode.Scalar) -> Bool {
        (0x0041...0x007A).contains(scalar.value)
            || (0x00C0...0x00FF).contains(scalar.value)
            || (0x0100...0x024F).contains(scalar.value)
            || (0x1E00...0x1EFF).contains(scalar.value)
    }
}

private final class TranslationAdapter: TranslationCallback {
    private let handler: @Sendable (String, String, String, Bool) -> Void
    init(_ handler: @escaping @Sendable (String, String, String, Bool) -> Void) {
        self.handler = handler
    }
    func onResult(
        status: String,
        document: String,
        sourceLanguage: String,
        fromCache: Bool
    ) {
        handler(status, document, sourceLanguage, fromCache)
    }
}
