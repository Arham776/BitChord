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
                                    if mode == .translate { UserDefaults.standard.set(language.code, forKey: "translation_language") }
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
    @AppStorage("translation_language") private var preferredLanguage = ""

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
        .onAppear { translator.loadLanguages() }
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

    private var preferredTarget: LyricsTranslator.Language? {
        let appLanguage = UserDefaults.standard.string(forKey: "app_language") ?? ""
        let code = preferredLanguage.isEmpty ? (appLanguage.isEmpty ? Locale.current.identifier : appLanguage) : preferredLanguage
        let languages = translator.languages(for: .translate)
        return languages.first { $0.code.caseInsensitiveCompare(code) == .orderedSame }
            ?? languages.first { $0.code.split(separator: "-").first == code.split(whereSeparator: { $0 == "-" || $0 == "_" }).first }
    }

    private func menu(for mode: LyricsTranslator.Mode, symbol: String) -> some View {
        Menu {
            if mode == .translate, let target = preferredTarget {
                Button("Translate to \(target.name)") {
                    translator.run(mode: .translate, target: target, trackId: trackId, lines: lines) { result in
                        if let result { onShowTranslated(result) }
                    }
                }
                Button("Choose Language…") { self.mode = mode }
            } else {
                Button { self.mode = mode } label: { Label(mode.title, systemImage: symbol) }
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

/// Upstream `LyricsSourcesDialog`: which lyric databases the player may ask.
///
/// Presented from the Now Playing more menu, so the choice lives where lyrics
/// are used rather than only in Settings. Backed by the same
/// `lyrics_sources` / `lyrics_source_order` / `prioritize_syllable_sync` keys
/// the Settings screen writes through `AppSettings` — one store, two doors —
/// and deliberately minimal here (toggles in priority order + the word-synced
/// preference + reset), because reordering UI already has a home in Settings.
///
/// The order shown is the order they are tried. The last enabled source cannot
/// be switched off: an empty set is indistinguishable from lyrics being off,
/// and there is already a switch for that.
struct LyricsSourcesSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selection = LyricsSourceNames.normalizeList(
        PlatformSettings.shared.getString(key: "lyrics_sources", default: LyricsSourceNames.defaultEnabled)
    )
    @State private var order = LyricsSourceNames.normalizeList(
        PlatformSettings.shared.getString(key: "lyrics_source_order", default: LyricsSourceNames.defaultEnabled)
    )
    @State private var syllableSync = PlatformSettings.shared.getBoolean(key: "prioritize_syllable_sync", default: true)
    @State private var paxSenixKey = PlatformSettings.shared.getSecret(key: "paxsenix_api_key") ?? ""

    /// Re-run the lookup for the track that is playing.
    ///
    /// Everything on this screen used to apply to the *next* track only: the
    /// settings were written, the current lyric was left exactly as it was, and
    /// there was no way from the player to ask again — so a wrong or missing
    /// lyric was unfixable without disabling sources globally and replaying the
    /// track. Upstream has a per-track provider picker; this is the part of it
    /// that makes the screen's own controls mean something where the listener is
    /// standing.
    var onSearchAgain: (() -> Void)? = nil

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(orderedIds, id: \.self) { id in
                        if let source = LyricsSourceOption.all.first(where: { $0.name == id }) {
                            Toggle(isOn: enabledBinding(source.name)) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(source.label)
                                    Text(source.detail)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } footer: {
                    Text("Tried top to bottom. Reorder in Settings → Lyrics → Lyrics Sources.")
                }
                if usesAuthenticatedRoutes {
                    Section {
                        SecureField("API key", text: $paxSenixKey)
                            #if os(iOS)
                            .textContentType(.password)
                            #endif
                    } header: {
                        Text("PaxSeniX Key")
                    } footer: {
                        Text("Needed for the PaxSeniX sources. Stored in the Keychain, not in preferences.")
                    }
                }
                Section {
                    Toggle("Prefer Word-Synced Lyrics", isOn: $syllableSync)
                    Button("Reset to Default") {
                        AppSettings.shared.resetLyricsSourceSettings()
                        order = LyricsSourceNames.defaultEnabled
                        selection = LyricsSourceNames.defaultEnabled
                        syllableSync = false
                    }
                } footer: {
                    Text("When on, a merely line-synced answer waits for a word-synced one further down the list.")
                }
            }
            .navigationTitle("Lyrics Sources")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if onSearchAgain != nil {
                    // Outside the List on purpose: this is an action on the
                    // track, not another setting, and it belongs next to the
                    // button that dismisses the sheet.
                    Button {
                        dismiss()
                        onSearchAgain?()
                    } label: {
                        Label("Search again for this track", systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .padding()
                }
            }
            .onChange(of: selection) { _, value in AppSettings.shared.setLyricsSources(value: value) }
            .onChange(of: order) { _, value in AppSettings.shared.setLyricsSourceOrder(value: value) }
            .onChange(of: syllableSync) { _, value in AppSettings.shared.setPrioritizeSyllableSync(value: value) }
            .onChange(of: paxSenixKey) { _, value in AppSettings.shared.setPaxSenixApiKey(value: value) }
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 480)
        #endif
    }

    private var orderedIds: [String] {
        let saved = order.split(separator: ",").map(String.init)
        let known = LyricsSourceOption.all.map(\.name)
        let fromSaved = saved.filter { known.contains($0) }
        return fromSaved + known.filter { !fromSaved.contains($0) }
    }

    private var usesAuthenticatedRoutes: Bool {
        let enabled = Set(selection.split(separator: ",").map(String.init))
        return enabled.contains("PAXSENIX_SPOTIFY") || enabled.contains("PAXSENIX_MUSIXMATCH")
    }

    private func enabledBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { Set(selection.split(separator: ",").map(String.init)).contains(id) },
            set: { on in
                let ids = orderedIds
                var enabled = Set(selection.split(separator: ",").map(String.init))
                if on {
                    enabled.insert(id)
                } else if enabled.count > 1 {
                    enabled.remove(id)
                }
                selection = ids.filter { enabled.contains($0) }.joined(separator: ",")
            }
        )
    }
}
