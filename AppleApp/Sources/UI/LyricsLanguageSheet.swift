import SwiftUI
import BitChordShared

/// Pick a language to translate or romanise into.
///
/// One sheet for both, because the two are the same gesture on the same words and
/// the difference is a mode — so the sheet's title, its search field and its list
/// all stay put while the list behind them changes.
struct LyricsLanguageSheet: View {
    @Environment(\.dismiss) private var dismiss

    let translator: LyricsTranslator
    let mode: LyricsTranslator.Mode
    let trackId: String
    let lines: [LyricLineDto]
    let onResult: ([LyricLineDto]?) -> Void

    @State private var search = ""

    private var languages: [LyricsTranslator.Language] {
        let all = translator.languages(for: mode)
        let needle = search.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return all }
        return all.filter {
            $0.name.localizedCaseInsensitiveContains(needle)
                || $0.code.localizedCaseInsensitiveContains(needle)
        }
    }

    /// Grouped by the first letter of the *displayed* name, so a localised list
    /// still reads as a list rather than as a flat wall of entries.
    private var sections: [(key: String, values: [LyricsTranslator.Language])] {
        var order: [String] = []
        var buckets: [String: [LyricsTranslator.Language]] = [:]
        for language in languages {
            let key = String(language.name.prefix(1)).uppercased()
            if buckets[key] == nil {
                buckets[key] = []
                order.append(key)
            }
            buckets[key]?.append(language)
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }

    var body: some View {
        NavigationStack {
            List {
                if languages.isEmpty {
                    ContentUnavailableView.search(text: search)
                } else {
                    ForEach(sections, id: \.key) { section in
                        Section(section.key) {
                            ForEach(section.values) { language in
                                Button {
                                    translator.run(
                                        mode: mode,
                                        target: language,
                                        trackId: trackId,
                                        lines: lines,
                                        then: onResult
                                    )
                                    dismiss()
                                } label: {
                                    HStack {
                                        Text(language.name)
                                            .foregroundStyle(.primary)
                                        Spacer()
                                        if language.code != language.name {
                                            Text(language.code)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            // The iOS-only `.navigationBarDrawer` placement is deliberately not
            // used: on macOS the field goes in the toolbar, which is where every
            // other searchable sheet in this app has it and where a Mac user looks
            // for it.
            .searchable(text: $search)
            .navigationTitle(mode.title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 480)
        #endif
        .task { translator.loadLanguages() }
    }
}

/// The button that opens it, and the line that reports what came back.
///
/// Placed on the lyrics pane rather than in settings because it is a per-track
/// action: the languages are the same every time, but whether a given lyric is
/// worth romanising is not.
struct LyricsTranslateControl: View {
    @Bindable var translator: LyricsTranslator
    let trackId: String
    let lines: [LyricLineDto]
    var onShowOriginal: () -> Void
    var onShowTranslated: ([LyricLineDto]) -> Void

    @State private var mode: LyricsTranslator.Mode?

    var body: some View {
        HStack(spacing: 8) {
            if translator.translatedLines != nil {
                Button("Show Original", action: onShowOriginal)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }

            if translator.canRomanize(lines: lines) {
                menu(for: .romanize, symbol: LyricsTranslator.Mode.romanize.symbol)
            }
            menu(for: .translate, symbol: LyricsTranslator.Mode.translate.symbol)

            if case .working = translator.outcome {
                ProgressView().controlSize(.small)
            }
        }
        .sheet(item: $mode) { chosen in
            LyricsLanguageSheet(
                translator: translator,
                mode: chosen,
                trackId: trackId,
                lines: lines
            ) { result in
                if let result { onShowTranslated(result) }
            }
        }
    }

    private func menu(for mode: LyricsTranslator.Mode, symbol: String) -> some View {
        Menu {
            Button {
                self.mode = mode
            } label: {
                Label(mode.title, systemImage: symbol)
            }
        } label: {
            Image(systemName: symbol)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(mode.subtitle)
        .accessibilityLabel(mode.title)
    }
}

/// What the last translation did, said in one line.
struct LyricsTranslationNote: View {
    let outcome: LyricsTranslator.Outcome

    var body: some View {
        if case .done(let language, let fromCache) = outcome {
            Text(name(of: language) + (fromCache ? " · already translated" : ""))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.7))
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(.white.opacity(0.10), in: Capsule())
        } else if case .alreadyInLanguage(let language) = outcome {
            Text(language.isEmpty
                 ? "Already in Latin script"
                 : "Already in \(name(of: language))")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.7))
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(.white.opacity(0.10), in: Capsule())
        } else if case .unavailable = outcome {
            Text("Could not translate this lyric")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.7))
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(.white.opacity(0.10), in: Capsule())
        }
    }

    /// The endpoint's own name for a language, where we have one.
    private func name(of code: String) -> String {
        Locale.current.localizedString(forIdentifier: code) ?? code
    }
}
