import SwiftUI
import BitChordShared
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Apple Settings-style grouped form. Structure and copy follow upstream;
/// settings appear directly in one grouped form, with drill-downs for dedicated screens.
struct SettingsView: View {
    var embedded: Bool = false
    @Environment(\.dismiss) private var dismiss
    @Environment(PlaybackController.self) private var controller
    @Environment(AuthController.self) private var auth
    @Environment(AppModel.self) private var appModel

    @State private var crossfade = Int(PlatformSettings.shared.getInt(key: "crossfade_seconds", default: 0))
    @AppStorage("dolby_atmos") private var dolbyAtmos = true
    @State private var spatial = PlatformSettings.shared.getBoolean(key: "spatial_audio", default: false)
    @State private var automix = PlatformSettings.shared.getBoolean(key: "smart_fade_enabled", default: true)
    @State private var automixSequence = PlatformSettings.shared.getBoolean(key: "automix_smart_sequence", default: true)
    @State private var trimEdges = PlatformSettings.shared.getBoolean(key: "trim_edge_silence", default: false)
    @State private var skipNonMusic = PlatformSettings.shared.getBoolean(key: "skip_non_music", default: false)
    @State private var skipSilence = PlatformSettings.shared.getBoolean(key: "skip_silence", default: false)
    @State private var wifiQuality = PlatformSettings.shared.getString(key: "audio_quality_wifi", default: "LOSSLESS")
    @State private var cellQuality = PlatformSettings.shared.getString(key: "audio_quality_cellular", default: "LOSSLESS")
    @State private var downloadQuality = PlatformSettings.shared.getString(key: "download_quality", default: "LOSSLESS")
    @State private var wifiOnlyDownloads = PlatformSettings.shared.getBoolean(key: "wifi_only_downloads", default: true)
    @State private var nerdStats = PlatformSettings.shared.getBoolean(key: "show_nerd_stats", default: false)
    @State private var canvas = PlatformSettings.shared.getBoolean(key: "animated_canvas", default: true)
    @State private var canvasCellular = PlatformSettings.shared.getBoolean(key: "canvas_over_cellular", default: false)
    @State private var reduceBlur = PlatformSettings.shared.getBoolean(key: "reduce_dynamic_blur", default: false)
    @State private var update = UpdateChecker.shared
    /// The release being shown, and nil when nothing is.
    @State private var updateSheet: AppReleaseUpdate?
    @State private var reduceAnimation = PlatformSettings.shared.getBoolean(key: "reduce_animation", default: false)
    @State private var fullBleed = PlatformSettings.shared.getBoolean(key: "full_bleed_artwork", default: true)
    @AppStorage("lyrics_blur") private var lyricsBlur = true
    @AppStorage("translation_language") private var translationLanguage = ""
    @State private var syncedLyrics = PlatformSettings.shared.getBoolean(key: "synced_lyrics", default: true)
    @State private var convertVideo = PlatformSettings.shared.getBoolean(key: "convert_video_to_audio", default: true)
    @State private var swipeNext = PlatformSettings.shared.getBoolean(key: "swipe_to_play_next", default: false)
    @State private var dontRepeat = PlatformSettings.shared.getBoolean(key: "dont_repeat_suggestions", default: false)
    @State private var hideVolume = PlatformSettings.shared.getBoolean(key: "hide_volume_bar", default: false)
    @State private var hideSongStatus = PlatformSettings.shared.getBoolean(key: "hide_song_status", default: false)
    @State private var outputPcm = PlaybackController.migrateOutputPcmMode()
    @State private var matchSourceRate = PlatformSettings.shared.getBoolean(key: "match_source_sample_rate", default: true)
    @State private var bitPerfect = PlatformSettings.shared.getBoolean(key: "bit_perfect_output", default: false)
    @State private var preferUsbDac = PlatformSettings.shared.getBoolean(key: "prefer_usb_dac", default: false)
    @State private var loudness = PlatformSettings.shared.getBoolean(key: "loudness_normalization", default: false)
    @State private var automixPerf = PlatformSettings.shared.getString(key: "automix_performance", default: "BALANCED")
    @State private var highPerf = PlatformSettings.shared.getBoolean(key: "high_performance_mode", default: false)
    @State private var refreshRate: Int = Int(PlatformSettings.shared.getInt(key: "performance_refresh_rate", default: 60))
    @State private var showPerfWarning = false
    @State private var localFolderName: String? = SettingsView.storedLocalFolderName()
    @State private var pickingFolder = false
    @State private var filterNonMusic = PlatformSettings.shared.getBoolean(key: "filter_non_music_audio", default: true)
    @State private var exportDownloads = PlatformSettings.shared.getBoolean(key: "export_downloads", default: false)
    @State private var smartAlign = PlatformSettings.shared.getBoolean(key: "smart_version_alignment", default: true)
    @State private var legacyMesh = PlatformSettings.shared.getBoolean(key: "legacy_mesh_gradient", default: false)
    @State private var preferMusicOnly = PlatformSettings.shared.getBoolean(key: "prefer_music_only", default: false)
    @State private var confirmImport = false
    @State private var theme = PlatformSettings.shared.getString(key: "theme_mode", default: "dark")
    @State private var lyricsSources = LyricsSourceNames.normalizeList(
        PlatformSettings.shared.getString(key: "lyrics_sources", default: LyricsSourceNames.defaultEnabled)
    )
    @State private var lyricsSourceOrder = LyricsSourceNames.normalizeList(
        PlatformSettings.shared.getString(key: "lyrics_source_order", default: LyricsSourceNames.defaultEnabled)
    )
    @State private var playbackSpeed = Double(PlatformSettings.shared.getFloat(key: "playback_speed", default: 1))
    @State private var jiosaavn = PlatformSettings.shared.getBoolean(key: "jiosaavn_enabled", default: true)
    @State private var stopBackground = PlatformSettings.shared.getBoolean(key: "stop_when_backgrounded", default: false)
    @State private var syllableSync = PlatformSettings.shared.getBoolean(key: "prioritize_syllable_sync", default: true)
    @State private var language = PlatformSettings.shared.getString(key: "app_language", default: "")
    @State private var spotifyCookie = PlatformSettings.shared.getString(key: "spotify_spdc_token", default: "")
    @State private var replayGenres = PlatformSettings.shared.getBoolean(key: "replay_genres", default: true)
    @State private var exportPresented = false
    @State private var importPresented = false
    @State private var backupNote: String?
    @State private var cacheLimitMB = SettingsView.cacheLimitMegabytes()
    @State private var loginPresented = false
    @State private var discordPresented = false
    /// The Automix models offer, raised when Automix is switched on without the
    /// beat model that makes it worth having.
    @State private var offerModelsSheet = false
    @State private var songCacheNote: String?
    @State private var imageCacheNote: String?
    /// The settings search box. Empty means "no filter", not "nothing" — clearing
    /// it must bring the whole screen back.
    @State private var search = ""

    private var metered: Bool { NetworkQuality.shared.metered }

    var body: some View {
        Group {
            if embedded {
                settingsForm
                    .navigationTitle("Settings")
                    .searchable(text: $search, prompt: "Search settings")
            } else {
                NavigationStack {
                    settingsForm
                        .navigationTitle("Settings")
                        .searchable(text: $search, prompt: "Search settings")
                        #if os(iOS)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { dismiss() }
                            }
                        }
                        #endif
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 560, idealWidth: 620, minHeight: 720)
        #endif
        .preferredColorScheme(appModel.preferredScheme)
        .onChange(of: dolbyAtmos) { _, value in AppSettings.shared.setDolbyAtmos(value: value) }
        .onAppear {
            // The tuner holds a display link while high performance is on, so it
            // has to be (re)applied every time this screen appears — and a value
            // written by another build that is not a rate offered here snaps to
            // 60 rather than requesting a mode the picker cannot name.
            if !PerformanceTuner.supportedRates.contains(refreshRate) { refreshRate = 60 }
            PerformanceTuner.shared.apply(highPerformance: highPerf, refreshRateHz: refreshRate)
            localFolderName = SettingsView.storedLocalFolderName()
        }
        .onChange(of: lyricsBlur) { _, value in AppSettings.shared.setLyricsBlur(value: value) }
        .onChange(of: translationLanguage) { _, value in AppSettings.shared.setTranslationLanguage(value: value) }
        .sheet(isPresented: $loginPresented) { loginSheet }
        .sheet(isPresented: $discordPresented) { DiscordLoginView() }
        // The offer again, from inside Settings, when Automix is switched on with
        // no beat model to time it. Presented here rather than through the root
        // binding because on macOS this screen is its own window and has no root
        // view above it.
        .sheet(isPresented: $offerModelsSheet) { AutomixModelsSheet() }
        .modifier(SettingsPlaybackPersist(
            controller: controller,
            crossfade: $crossfade,
            spatial: $spatial,
            automix: $automix,
            automixSequence: $automixSequence,
            automixPerf: $automixPerf,
            skipSilence: $skipSilence,
            playbackSpeed: $playbackSpeed,
            onAutomixEnabled: {
                if appModel.mayAskForAutomixModels() { offerModelsSheet = true }
            }
        ))
        .modifier(SettingsQualityPersist(
            controller: controller,
            wifiQuality: $wifiQuality,
            cellQuality: $cellQuality,
            downloadQuality: $downloadQuality,
            wifiOnlyDownloads: $wifiOnlyDownloads,
            cacheLimitMB: $cacheLimitMB,
            outputPcm: $outputPcm,
            matchSourceRate: $matchSourceRate,
            bitPerfect: $bitPerfect,
            preferUsbDac: $preferUsbDac,
            loudness: $loudness
        ))
        .modifier(SettingsExperiencePersist(
            controller: controller,
            appModel: appModel,
            nerdStats: $nerdStats,
            canvas: $canvas,
            canvasCellular: $canvasCellular,
            reduceBlur: $reduceBlur,
            reduceAnimation: $reduceAnimation,
            fullBleed: $fullBleed,
            syncedLyrics: $syncedLyrics,
            convertVideo: $convertVideo,
            swipeNext: $swipeNext,
            dontRepeat: $dontRepeat,
            hideVolume: $hideVolume,
            legacyMesh: $legacyMesh,
            preferMusicOnly: $preferMusicOnly,
            theme: $theme
        ))
        .modifier(SettingsAdvancedPersist(
            controller: controller,
            smartAlign: $smartAlign,
            hideSongStatus: $hideSongStatus,
            exportDownloads: $exportDownloads,
            filterNonMusic: $filterNonMusic,
            highPerf: $highPerf,
            refreshRate: $refreshRate,
            reduceAnimation: $reduceAnimation,
            reduceBlur: $reduceBlur
        ))
        .modifier(SettingsExtrasPersist(
            lyricsSources: $lyricsSources,
            lyricsSourceOrder: $lyricsSourceOrder,
            jiosaavn: $jiosaavn,
            stopBackground: $stopBackground,
            syllableSync: $syllableSync,
            language: $language,
            spotifyCookie: $spotifyCookie,
            replayGenres: $replayGenres,
            appModel: appModel
        ))
        .fileExporter(
            isPresented: $exportPresented,
            document: SettingsBackupFile(text: BitChordBackup.exportText()),
            contentType: .json,
            defaultFilename: BitChordBackup.suggestedName()
        ) { result in
            if case .success = result { backupNote = "Settings exported" }
        }
        .fileImporter(isPresented: $importPresented, allowedContentTypes: [.json]) { result in
            guard case .success(let url) = result else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            if let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) {
                BitChordBackup.importText(text)
                backupNote = "Imported — reopen Settings to see them"
            }
        }
    }

    /// The sections of this screen, in order, with what a listener might type to
    /// find them.
    ///
    /// The terms live here rather than in the rows they describe, for the same
    /// reason the section titles do: a search index kept next to the setting it
    /// describes cannot drift from it, and one kept in a table elsewhere does.
    enum SettingsSection: String, CaseIterable, Identifiable {
        case account, audioQuality, downloads, playback
        case appearance, performance, localMusic, storage, yourData, miscellaneous, advanced, about

        var id: String { rawValue }

        var title: String {
            switch self {
            case .account: return "Account & Integrations"
            case .audioQuality: return "Audio Quality"
            case .downloads: return "Downloads"
            case .playback: return "Playback"
            case .appearance: return "Appearance"
            case .performance: return "Performance"
            case .localMusic: return "Local Music"
            case .storage: return "Storage"
            case .yourData: return "Your Data"
            case .miscellaneous: return "Miscellaneous"
            case .advanced: return "Advanced Options"
            case .about: return "About"
            }
        }

        /// What is *in* the section, in the words a listener would use.
        ///
        /// The section titles are things like "Playback" and "Storage", which
        /// nobody types when they mean "crossfade". Without these the search box
        /// only finds the nine words already on screen.
        var terms: [String] {
            switch self {
            case .account:
                return ["sign in", "login", "google", "discord", "rich presence",
                        "scrobbling", "last.fm", "lastfm", "listenbrainz", "spotify",
                        "canvas", "paxsenix", "api key", "account", "profile",
                        "primary artist", "album artist", "track artist", "scrobble artist"]
            case .audioQuality:
                return ["quality", "lossless", "flac", "bitrate", "bitrate cap",
                        "wifi", "wi-fi", "cellular", "mobile data", "metered",
                        "transcode", "streaming quality", "pcm", "bit depth",
                        "output precision", "float", "usb", "dac", "headphone",
                        "loudness", "normalize", "normalization", "replaygain", "lufs"]
            case .downloads:
                return ["download", "downloaded", "offline", "wifi only",
                        "over cellular", "save", "storage location", "cache",
                        "export", "compatible", "music folder", "visible"]
            case .playback:
                return ["crossfade", "gapless", "automix", "autoplay", "skip silence",
                        "playback speed", "speed", "spatial audio", "fade", "sounds",
                        "equalizer", "eq", "volume", "sleep timer", "queue", "repeat",
                        "shuffle", "scrobble", "smart sequencing", "sequencing",
                        "automix performance", "cpu", "threads",
                        "automix models", "models", "model", "onnx", "beat", "downbeat",
                        "vocal", "download models",
                        "battery", "prefer music only", "music video"]
            case .appearance:
                return ["theme", "dark mode", "light mode", "appearance", "colour",
                        "color", "accent", "transparency", "reduce motion",
                        "reduce transparency", "animation", "full bleed", "artwork",
                        "dynamic blur", "contrast", "mesh", "gradient", "legacy",
                        "backdrop", "single wash"]
            case .performance:
                return ["performance", "high performance", "refresh rate",
                        "frame rate", "hz", "smooth", "battery", "proMotion",
                        "display", "animation"]
            case .localMusic:
                return ["local music", "local library", "folder", "scan", "files",
                        "offline", "filter", "podcast", "recording", "ringtone",
                        "voice", "non-music", "all audio folders"]
            case .storage:
                return ["storage", "cache", "clear cache", "local library",
                        "local music", "library", "folder", "scan", "space", "disk",
                        "webdav", "remote library", "nextcloud", "owncloud", "nas",
                        "self hosted", "share", "server"]
            case .yourData:
                return ["backup", "export", "import", "reset", "privacy", "data",
                        "pinned playlists", "delete", "erase"]
            case .miscellaneous:
                return ["language", "lyrics", "sources", "video", "lyric video",
                        "swipe", "suggestions", "volume bar", "lyrics source", "translation language", "blur unfocused lyrics",
                        "spotify canvas", "jiosaavn", "background", "stop when backgrounded",
                        "listen together", "party", "jam", "party code", "invite",
                        "party server", "in sync", "synchronise", "synchronize",
                        "hide song status", "playing from", "played by", "caption"]
            case .advanced:
                return ["advanced", "version", "alignment", "waveform", "sync",
                        "audio", "video", "intro", "skit", "debug", "bitrate", "codec"]
            case .about:
                return ["about", "version", "credits", "licence", "license",
                        "acknowledgements", "privacy policy", "github"]
            }
        }
    }

    private func shows(_ section: SettingsSection) -> Bool {
        SettingsSearchBridge.shared.matches(
            query: search,
            title: section.title,
            termsCsv: section.terms.joined(separator: "\u{1F}")
        )
    }

    private var visibleSections: [SettingsSection] {
        SettingsSection.allCases.filter(shows)
    }

    @ViewBuilder
    private func sectionContents(_ section: SettingsSection) -> some View {
        switch section {
        case .account: accountSection
        case .audioQuality: audioQualitySection
        case .downloads: downloadsSection
        case .playback: playbackSection
        case .appearance: appearanceSection
        case .performance: performanceSection
        case .localMusic: localMusicSection
        case .storage: storageSection
        case .yourData: yourDataSection
        case .miscellaneous: miscellaneousSection
        case .advanced: advancedSection
        case .about: aboutSection
        }
    }

    private var settingsForm: some View {
        Form {
            ForEach(visibleSections) { section in
                sectionContents(section)
            }
            if !search.isEmpty && visibleSections.isEmpty {
                ContentUnavailableView.search(text: search)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Account

    private var accountSection: some View {
        Section {
            NavigationLink {
                AccountIntegrationsView(loginPresented: $loginPresented, discordPresented: $discordPresented)
            } label: {
                SettingsLine(
                    glyph: .person,
                    title: "Account & Integrations",
                    subtitle: accountSubtitle
                ) {
                    EmptyView()
                }
            }
        }
    }

    private var accountSubtitle: String {
        // "Session saved, not restored" rather than "Not signed in", because the
        // two call for opposite actions and this row is where the listener looks
        // to find out which one they are in.
        if let reason = auth.sessionUnavailableReason { return reason }
        if let email = auth.accountEmail, !email.isEmpty { return email }
        if let name = auth.accountName, !name.isEmpty { return name }
        return auth.signedIn ? "Signed in" : "Not signed in"
    }

    /// What the Listen Together row says.
    ///
    /// Says what the feature is rather than how to start it, because a settings row
    /// is a label for a thing and not a call to action — the screen it opens is where
    /// the button is.
    private var listenTogetherSubtitle: String {
        let party = PartyStore.shared
        if party.inParty { return "In a party · \(party.code)" }
        return "Share a code and play the same music, in time"
    }

    /// How many are listening, when it is more than one person.
    ///
    /// A count of one is not news — a party of one is a person alone, which is what
    /// they already know — so the badge appears only once somebody else is there.
    private var partyBadge: String? {
        let party = PartyStore.shared
        let count = party.state.members.count
        return party.inParty && count > 1 ? "\(count)" : nil
    }

    // MARK: - Audio quality

    private var audioQualitySection: some View {
        Section {
            NavigationLink {
                SourcesView()
            } label: {
                SettingsLine(
                    glyph: .sources,
                    title: "Sources",
                    subtitle: "Where audio comes from, and in what order"
                ) {
                    EmptyView()
                }
            }
            Picker("Sound Mode", selection: Binding(get: { controller.soundMode }, set: { controller.updateSoundMode($0) })) {
                Text("Transparent").tag("TRANSPARENT")
                Text("Enhanced").tag("ENHANCED")
            }
            if controller.soundMode == "ENHANCED" {
                Picker("Clarity Preset", selection: Binding(get: { controller.clarityPreset }, set: { controller.updateClarity(preset: $0) })) {
                    Text("Reference").tag("REFERENCE")
                    Text("Speaker").tag("SPEAKER")
                    Text("Headphone").tag("HEADPHONE")
                    Text("DAC").tag("DAC")
                }
                VStack(alignment: .leading) {
                    Text("Clarity Mix · \(Int(controller.clarityWet * 100))%")
                    Slider(value: Binding(get: { controller.clarityWet }, set: { controller.updateClarity(wet: $0) }), in: 0...1)
                }
                Picker("Normalization", selection: Binding(get: { controller.loudnessMode }, set: { controller.updateLoudnessMode($0) })) {
                    Text("Off").tag("OFF")
                    Text("Track").tag("TRACK")
                    Text("Album").tag("ALBUM")
                }
            }
            Text(controller.soundMode == "TRANSPARENT" ? "Preserves the recording. Playback speed, Automix and crossfade keep their own settings." : "Reference clarity adds tonal contour, centered bass and gentle width. Manual EQ and spatial remain optional.")
                .font(.footnote).foregroundStyle(.secondary)
            qualityRow(
                glyph: .wifi,
                title: "On Wi-Fi",
                badge: metered ? nil : "In Use",
                selection: $wifiQuality,
                options: AudioQualityOption.stream
            )
            qualityRow(
                glyph: .cellular,
                title: "On Mobile Data",
                badge: metered ? "In Use" : nil,
                selection: $cellQuality,
                options: AudioQualityOption.stream
            )
            Text("Lossless includes Hi-Res when an enabled source supplies it. Audio Pipeline shows the format actually decoded.")
                .font(.footnote).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 10) {
                SettingsLine(
                    glyph: .precision,
                    title: "Output Precision",
                    subtitle: outputPrecisionSubtitle
                ) {
                    EmptyView()
                }
                Picker("Output Precision", selection: $outputPcm) {
                    Text("PCM 16").tag("PCM_16")
                    Text("Float 32").tag("FLOAT_32")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.leading, 41)
            }
            .padding(.vertical, 4)
            SettingsToggleLine(
                glyph: .precision,
                title: "Match Source Sample Rate",
                subtitle: "Request each track’s native rate from the output route",
                isOn: $matchSourceRate
            )
            #if os(macOS)
            SettingsToggleLine(
                glyph: .precision,
                title: "Bit-perfect Output",
                subtitle: "Bypasses app volume, DSP and transitions for supported lossless stereo",
                isOn: $bitPerfect
            )
            #endif
            SettingsSubToggle(title: "Prefer USB DAC", isOn: $preferUsbDac)
            SettingsToggleLine(glyph: .dolby, title: "Dolby Atmos",
                subtitle: "Use Apple’s renderer when a source provides supported Dolby audio", isOn: $dolbyAtmos)
                .disabled(!AppleDolbyRenderer.available)


        } header: {
            Text("Audio Quality")
        } footer: {
            Text("Match Source Sample Rate asks the route to switch clock families between tracks. Bit-perfect output is available on macOS when the DAC grants exclusive access and the lossless source format is supported. The Audio Pipeline readout shows what is actually in effect.")
        }
    }

    /// What the output is doing right now, read off the engine rather than the
    /// setting — the setting is the request, and this is the answer.
    private var outputPrecisionSubtitle: String {
        let device = controller.outputDevice
        guard device.started else { return "Requested \(Self.pcmLabel(outputPcm))" }
        let actual = Self.pcmLabel(device.sampleFormat)
        var parts = [actual]
        if device.sampleFormat != outputPcm {
            parts.append("requested \(Self.pcmLabel(outputPcm))")
        }
        if !device.name.isEmpty { parts.append(device.name) }
        if device.sampleRate > 0 {
            let khz = Double(device.sampleRate) / 1000
            parts.append(String(format: khz == khz.rounded() ? "%.0f kHz" : "%.1f kHz", khz))
        }
        return parts.joined(separator: " · ")
    }

    private static func pcmLabel(_ mode: String) -> String {
        switch mode {
        case "FLOAT_32": return "Float 32"
        case "PCM_16": return "PCM 16"
        case "PCM_24": return "PCM 24"
        default: return "PCM 16"
        }
    }

    // MARK: - Downloads

    private var downloadsSection: some View {
        Section {
            qualityRow(
                glyph: .download,
                title: "Download Quality",
                subtitle: "\(AudioQualityOption.label(downloadQuality, in: AudioQualityOption.download)) per track, whatever the connection",
                selection: $downloadQuality,
                options: AudioQualityOption.download
            )
            SettingsSubToggle(
                title: "Download over Wi-Fi Only",
                isOn: $wifiOnlyDownloads,
                badge: (wifiOnlyDownloads && metered) ? "Blocking" : nil
            )
            SettingsToggleLine(
                glyph: .sharedFolder,
                title: "Export Compatible Downloads",
                subtitle: exportDownloads
                    ? "Music/BitChord — visible to other music apps"
                    : "Keeps downloads where other music apps can see them",
                isOn: $exportDownloads
            )
        } header: {
            Text("Downloads")
        } footer: {
            Text("Exported downloads live in the shared Music folder. Private ones stay inside BitChord's own storage.")
        }
    }

    // MARK: - Playback

    private var playbackSection: some View {
        Section {
            // Automix decides its own length from each pair of tracks, so it
            // replaces the manual slider rather than needing it set to anything
            // first — upstream's rule, which is why the slider goes away
            // entirely instead of greying out.
            if automix {
                Text("Automix times every transition itself; the crossfade slider returns when Automix is off.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                SettingsSliderRow(
                    glyph: .crossfade,
                    title: "Crossfade",
                    subtitle: "Blends one track into the next",
                    valueText: crossfade == 0 ? "Off" : "\(crossfade)s",
                    value: Binding(
                        get: { Double(crossfade) },
                        set: { crossfade = Int($0.rounded()) }
                    ),
                    range: 0...12,
                    step: 1
                )
            }
            SettingsToggleLine(
                glyph: .automix,
                title: "Automix [Beta]",
                subtitle: automix
                    ? (AutomixModelStore.shared.beatInstalled
                        ? "Blends every transition, timed automatically from each track. Turn off if facing overheating or lag."
                        : "Blends every transition automatically. The beat model is not installed, so timing comes from tempo analysis — install it below for transitions that land on the beat.")
                    : "Times and blends transitions automatically, no slider needed.",
                isOn: $automix
            )
            if automix {
                SettingsToggleLine(
                    glyph: .automix,
                    title: "Smart Sequencing",
                    subtitle: "Order upcoming list tracks and Autoplay suggestions for smooth transitions, listening taste and freshness. Takes priority over Shuffle; manually queued tracks keep their order.",
                    isOn: $automixSequence
                )
            }
            NavigationLink {
                AutomixPerformancePage(selection: $automixPerf)
            } label: {
                SettingsLine(
                    glyph: .cpu,
                    title: "Automix Performance",
                    subtitle: "Background analysis budget — \(Self.automixPerfLabel(automixPerf)), \(controller.automixInferenceThreads) thread\(controller.automixInferenceThreads == 1 ? "" : "s")"
                ) {
                    Text(Self.automixPerfLabel(automixPerf))
                        .foregroundStyle(.secondary)
                }
            }
            NavigationLink {
                AutomixModelsPage()
            } label: {
                SettingsLine(
                    glyph: .models,
                    title: "Automix Models",
                    subtitle: Self.automixModelsSubtitle
                ) {
                    EmptyView()
                }
            }
            Toggle("Trim Leading and Trailing Silence", isOn: $trimEdges)
                .onChange(of: trimEdges) { _, value in
                    PlatformSettings.shared.putBoolean(key: "trim_edge_silence", value: value)
                    controller.refreshPlaybackRegions()
                }
            Toggle("Skip Non-Music Segments", isOn: $skipNonMusic)
                .onChange(of: skipNonMusic) { _, value in
                    PlatformSettings.shared.putBoolean(key: "skip_non_music", value: value)
                    controller.refreshPlaybackRegions()
                }
            Text("Non-music segments and audible boundaries are always used by Automix.")
                .font(.caption).foregroundStyle(.secondary)
            NavigationLink("Diagnostic Reports") { DiagnosticReportsView() }
            SettingsToggleLine(
                glyph: .skipSilence,
                title: "Skip Silence",
                subtitle: "Trim gaps longer than a second",
                isOn: $skipSilence
            )
            SettingsSliderRow(
                glyph: .speed,
                title: "Playback Speed",
                subtitle: "Slows or speeds the mix without changing pitch on the engine",
                valueText: String(format: "%.2fx", playbackSpeed),
                value: $playbackSpeed,
                range: 0.5...2.0,
                step: 0.05
            )
            SettingsToggleLine(
                glyph: .spatial,
                title: "BitChord spatial effect",
                subtitle: "Optional stereo widening and head tracking. Suspended when Apple reports Spatial Audio is enabled.",
                isOn: $spatial
            )
            Text("Apple’s Headphone Accommodations, Adaptive Audio and Conversation Awareness are managed in system Accessibility, AirPods settings and Control Center. BitChord keeps your manual EQ choices.")
                .font(.caption).foregroundStyle(.secondary)
#if os(iOS)
            SettingsToggleLine(
                glyph: .musicOnly,
                title: "Play Alongside Other Apps",
                subtitle: "Keep other apps audible alongside BitChord. This can prevent iOS Lock Screen, Control Center and headphone controls from controlling BitChord. Turn off to give BitChord audio priority. Applies immediately while playing, or on the next play.",
                isOn: Binding(
                    get: { controller.mixWithOtherAudio },
                    set: { controller.setMixWithOtherAudio($0) }
                )
            )
#endif
            NavigationLink {
                EqualizerView()
            } label: {
                SettingsLine(
                    glyph: .equalizer,
                    title: "Equalizer",
                    subtitle: "Ten-band EQ on the mixed output"
                ) {
                    EmptyView()
                }
            }
            SettingsToggleLine(
                glyph: .nerd,
                title: "Show Stats for Nerds",
                subtitle: "Codec, bitrate and sample rate on the player",
                isOn: $nerdStats
            )
            SettingsToggleLine(
                glyph: .video,
                title: "Stop Converting Video Songs to Audio",
                subtitle: "Plays a music-video upload as itself instead of swapping it for its catalogue audio release",
                isOn: Binding(
                    get: { !convertVideo },
                    set: { convertVideo = !$0 }
                )
            )
            SettingsToggleLine(
                glyph: .musicOnly,
                title: "Prefer Music Only",
                subtitle: "Starts a music-video result on its catalogue audio release instead of the video's own upload",
                isOn: $preferMusicOnly
            )
        } header: {
            Text("Playback")
        } footer: {
            Text("Gapless stays on at 0s. Automix picks timing per track; crossfade sets the manual blend length.")
        }
    }

    private static func automixPerfLabel(_ mode: String) -> String {
        switch mode {
        case "EFFICIENT": return "Efficient"
        case "PERFORMANCE": return "Performance"
        default: return "Balanced"
        }
    }

    /// What the Automix Models row says without opening it.
    ///
    /// State rather than instruction: "Not installed" is the fact, and the row's
    /// destination is where the action is — a subtitle that also shouts "tap here"
    /// is a settings row pretending to be a button.
    private static var automixModelsSubtitle: String {
        let store = AutomixModelStore.shared
        let beat = store.status(of: .beat).isInstalled
        let vocals = store.status(of: .vocals).isInstalled
        switch (beat, vocals) {
        case (true, true):
            return "Beat, downbeat and vocal models installed — \(AutomixModelStore.bytes(store.totalBytesOnDisk)) on disk"
        case (true, false):
            return "Beat model installed; vocal detection can be added for vocal-clash avoidance"
        case (false, true):
            return "Vocal model installed; the beat model is what times transitions"
        case (false, false):
            return "Not installed — Automix falls back to tempo analysis"
        }
    }

    // MARK: - Appearance

    private var appearanceSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                SettingsLine(glyph: .theme, title: "Appearance") { EmptyView() }
                Picker("Appearance", selection: $theme) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.leading, 41)
            }
            .padding(.vertical, 4)
            SettingsToggleLine(
                glyph: .reduceMotion,
                title: "Reduce Animation",
                subtitle: "Freezes the main player's gradient instead of drifting",
                isOn: $reduceAnimation
            )
            SettingsToggleLine(
                glyph: .reduceBlur,
                title: "Reduce Dynamic Blur",
                subtitle: "Swaps frosted glass for solid fills across the app",
                isOn: $reduceBlur
            )
            SettingsToggleLine(
                glyph: .fullBleed,
                title: "Full-Screen Cover Art",
                subtitle: "Runs the cover to the edges of the player instead of a square sleeve",
                isOn: $fullBleed
            )
            SettingsToggleLine(
                glyph: .mesh,
                title: "Legacy Mesh Gradient",
                subtitle: "The single-wash backdrop instead of colours sampled from the artwork",
                isOn: $legacyMesh
            )
            SettingsToggleLine(
                glyph: .canvas,
                title: "Animated Cover Art",
                subtitle: "Plays the looping video some releases ship instead of a still sleeve",
                isOn: $canvas
            )
            if canvas {
                SettingsSubToggle(title: "Play Animated Cover over Cellular", isOn: $canvasCellular)
            }
            SettingsToggleLine(
                glyph: .lyrics,
                title: "Synced Lyrics",
                subtitle: "Lights up the words on the player as they’re sung",
                isOn: $syncedLyrics
            )
            if syncedLyrics {
                SettingsToggleLine(glyph: .reduceBlur, title: "Blur Unfocused Lyrics",
                                   subtitle: "Softens lines away from the words being sung", isOn: $lyricsBlur)
                NavigationLink {
                    TranslationPreferenceView(selection: $translationLanguage, translator: controller.lyricsTranslator)
                } label: {
                    SettingsLine(glyph: .lyricsSources, title: "Translation Language",
                                 subtitle: translationLanguage.isEmpty ? "Follow the app language" : (Locale.current.localizedString(forIdentifier: translationLanguage) ?? translationLanguage)) { EmptyView() }
                }
                SettingsToggleLine(
                    glyph: .lyrics,
                    title: "Prefer Word-Synced Lyrics",
                    subtitle: "Syllable timings win the lyrics race when a source has them",
                    isOn: $syllableSync
                )
                NavigationLink {
                    LyricsSourcesView(selection: $lyricsSources, order: $lyricsSourceOrder, syllableSync: $syllableSync)
                } label: {
                    SettingsLine(
                        glyph: .lyricsSources,
                        title: "Lyrics Sources",
                        subtitle: LyricsSourceOption.summary(lyricsSources)
                    ) {
                        EmptyView()
                    }
                }
            }
        } header: {
            Text("Appearance")
        }
    }

    // MARK: - Performance

    private var performanceSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { highPerf },
                set: { enabled in
                    // Turning it on is the consequential direction — a sustained
                    // high refresh rate costs real battery — so that way goes
                    // through the warning first. Turning it off just stops.
                    if enabled { showPerfWarning = true } else { highPerf = false }
                }
            )) {
                SettingsLine(
                    glyph: .performance,
                    title: "High Performance Mode",
                    subtitle: highPerf
                        ? "Holding \(refreshRate) Hz"
                        : "Requests a sustained high refresh rate"
                ) {
                    EmptyView()
                }
            }
            .padding(.vertical, 2)
            if highPerf {
                VStack(alignment: .leading, spacing: 10) {
                    SettingsLine(glyph: .refreshRate, title: "Refresh Rate") { EmptyView() }
                    Picker("Refresh Rate", selection: $refreshRate) {
                        ForEach(PerformanceTuner.supportedRates, id: \.self) { rate in
                            Text("\(rate) Hz").tag(rate)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .padding(.leading, 41)
                }
                .padding(.vertical, 4)
            }
        } header: {
            Text("Performance")
        } footer: {
            Text("High Performance Mode holds the display at the chosen refresh rate instead of letting the system vary it. Expect noticeably shorter battery life while it is on.")
        }
        .alert("Higher refresh rate?", isPresented: $showPerfWarning) {
            Button("Cancel", role: .cancel) {}
            Button("Turn On") { highPerf = true }
        } message: {
            Text("Holding a high refresh rate keeps the display working harder the whole time BitChord is open, and the battery drains faster for it. Turn it on anyway?")
        }
    }

    // MARK: - Local music

    private var localMusicSection: some View {
        Section {
            Button {
                pickLocalFolder()
            } label: {
                SettingsLine(
                    glyph: .folder,
                    title: "Folder",
                    subtitle: localFolderName ?? "No folder chosen"
                ) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
            if localFolderName != nil {
                Button {
                    AppSettings.shared.setLocalLibraryPath(value: "")
                    localFolderName = nil
                } label: {
                    SettingsLine(
                        glyph: .localMusic,
                        title: "Use All Audio Folders",
                        subtitle: "Forgets the chosen folder"
                    ) {
                        EmptyView()
                    }
                }
                .buttonStyle(.plain)
            }
            SettingsToggleLine(
                glyph: .filter,
                title: "Filter Non-Music Audio",
                subtitle: "Hides clips under 30 seconds, ringtones, podcasts and recorder output",
                isOn: $filterNonMusic
            )
        } header: {
            Text("Local Music")
        } footer: {
            Text("BitChord watches the folder you choose for music files. Filtering keeps everything that is not a song out of the list.")
        }
        .fileImporter(isPresented: $pickingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                LocalLibrary.shared.scanPicked(url)
                localFolderName = SettingsView.storedLocalFolderName()
                    ?? url.lastPathComponent
            }
        }
    }

    private func pickLocalFolder() {
        #if os(macOS)
        LocalLibrary.shared.chooseFolder()
        localFolderName = SettingsView.storedLocalFolderName()
        #else
        pickingFolder = true
        #endif
    }

    /// The chosen library folder's display name, from the persisted bookmark.
    ///
    /// Read from the bookmark rather than held in state: the library owns the
    /// bookmark and this screen only reports it, so resolving it fresh is what
    /// keeps the row honest after a pick made from the Library tab.
    static func storedLocalFolderName() -> String? {
        let stored = PlatformSettings.shared.getString(key: "local_library_path", default: "")
        guard !stored.isEmpty, let data = Data(base64Encoded: stored) else { return nil }
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) else { return nil }
        let name = url.lastPathComponent
        return name.isEmpty ? nil : name
    }

    // MARK: - Storage

    private var storageSection: some View {
        Section {
            SettingsSliderRow(
                glyph: .storage,
                title: "Song Cache Limit",
                subtitle: cacheLimitMB > 2048
                    ? "Up to \(Self.formatCache(cacheLimitMB)) of downloaded audio kept on disk."
                    : "Downloaded audio kept on disk for instant seeking and replays",
                valueText: Self.formatCache(cacheLimitMB),
                value: Binding(
                    get: { Double(cacheLimitMB) },
                    set: { cacheLimitMB = Int($0.rounded()) }
                ),
                range: 512...10240,
                step: 512
            )
            Button {
                Task {
                    await StreamFileCache.shared.clear()
                    await MainActor.run { songCacheNote = "Song cache cleared" }
                }
            } label: {
                SettingsLine(
                    glyph: .clearSongs,
                    title: "Clear Song Cache",
                    subtitle: songCacheNote ?? "Frees space used by downloaded audio"
                ) {
                    EmptyView()
                }
            }
            .buttonStyle(.plain)
            Button {
                ArtworkCache.shared.clear()
                imageCacheNote = "Image cache cleared"
            } label: {
                SettingsLine(
                    glyph: .clearImages,
                    title: "Clear Image Cache",
                    subtitle: imageCacheNote ?? "Frees space used by album artwork"
                ) {
                    EmptyView()
                }
            }
            .buttonStyle(.plain)
        } header: {
            Text("Storage")
        }
    }

    // MARK: - Your data

    private var yourDataSection: some View {
        Section {
            Button {
                appModel.replayPresented = true
            } label: {
                SettingsLine(
                    glyph: .replay,
                    title: "Replay",
                    subtitle: "Your top songs, artists, albums and genres"
                ) {
                    EmptyView()
                }
            }
            .buttonStyle(.plain)
            SettingsToggleLine(
                glyph: .genres,
                title: "Work Out Genres",
                subtitle: replayGenres
                    ? "Asks Last.fm what an artist plays — their name is sent, nothing else"
                    : "Replay's genre chart is hidden while this is off",
                isOn: $replayGenres
            )
            Button {
                exportPresented = true
            } label: {
                SettingsLine(
                    glyph: .export,
                    title: "Export Data",
                    subtitle: backupNote ?? "Settings and listening history, as one JSON file"
                ) {
                    EmptyView()
                }
            }
            .buttonStyle(.plain)
            Button {
                confirmImport = true
            } label: {
                SettingsLine(
                    glyph: .importData,
                    title: "Import Data",
                    subtitle: "Restores non-secret preferences"
                ) {
                    EmptyView()
                }
            }
            .buttonStyle(.plain)
        } header: {
            Text("Your Data")
        }
        // Asked before the picker opens rather than after a file is chosen: the
        // thing being confirmed is that this device's own data is about to be
        // replaced, and that is true whichever file gets picked.
        .alert("Replace this device's data?", isPresented: $confirmImport) {
            Button("Cancel", role: .cancel) {}
            Button("Choose File") { importPresented = true }
        } message: {
            Text("Importing a backup replaces the settings and listening history on this device. This cannot be undone.")
        }
    }

    // MARK: - Miscellaneous

    private var miscellaneousSection: some View {
        Section {
            SettingsToggleLine(
                glyph: .swipe,
                title: "Play Next on Swipe",
                subtitle: swipeNext
                    ? "Swiping a song plays it next"
                    : "Swiping a song adds it to the end of the queue when disabled",
                isOn: $swipeNext
            )
            SettingsToggleLine(
                glyph: .dontRepeat,
                title: "Don’t Repeat Songs in Current Session",
                subtitle: "AutoPlay won’t suggest a song already played or suggested this session",
                isOn: $dontRepeat
            )
            SettingsToggleLine(
                glyph: .hideVolume,
                title: "Hide Volume Bar",
                subtitle: "Removes the volume slider from the main player",
                isOn: $hideVolume
            )
            SettingsToggleLine(
                glyph: .songStatus,
                title: "Hide Song Status",
                subtitle: "Hides the “Playing from” caption on the main player",
                isOn: $hideSongStatus
            )
            SettingsToggleLine(
                glyph: .sources,
                title: "JioSaavn",
                subtitle: "Race JioSaavn for high-bitrate matches alongside YouTube Music",
                isOn: $jiosaavn
            )
            SettingsToggleLine(
                glyph: .video,
                title: "Stop When Backgrounded",
                subtitle: "Pauses playback when the app leaves the foreground",
                isOn: $stopBackground
            )
            NavigationLink {
                ListenTogetherView()
            } label: {
                SettingsLine(
                    glyph: .listenTogether,
                    title: "Listen together",
                    subtitle: listenTogetherSubtitle,
                    badge: partyBadge
                ) {
                    EmptyView()
                }
            }
            NavigationLink {
                SpotifyCanvasAuthView(cookie: $spotifyCookie)
            } label: {
                SettingsLine(
                    glyph: .canvas,
                    title: "Spotify Canvas",
                    subtitle: spotifyCookie.isEmpty ? "Optional sp_dc cookie for motion art" : "Cookie saved"
                ) {
                    EmptyView()
                }
            }
            Picker(selection: $language) {
                Text("System").tag("")
                Text("English").tag("en")
                Text("Spanish").tag("es")
                Text("French").tag("fr")
                Text("German").tag("de")
                Text("Portuguese").tag("pt")
                Text("Hindi").tag("hi")
                Text("Japanese").tag("ja")
                Text("Korean").tag("ko")
                Text("Chinese").tag("zh-Hans")
            } label: {
                SettingsLine(glyph: .theme, title: "App Language", subtitle: "Follows system unless you pick one") {
                    EmptyView()
                }
            }
            SecureField("Spotify sp_dc cookie (optional canvas)", text: $spotifyCookie)
        } header: {
            Text("Miscellaneous")
        } footer: {
            Text("When enabled, closing the app from the recent apps screen will also stop music playback.")
        }
    }

    // MARK: - Advanced options

    private var advancedSection: some View {
        Section {
            SettingsToggleLine(
                glyph: .align,
                title: "Smart Version Alignment",
                subtitle: "Keeps your place when switching between versions of a track",
                isOn: $smartAlign
            )
        } header: {
            Text("Advanced Options")
        } footer: {
            Text("A version switch resumes where you left off. With this off it restarts from the top, since no alignment is attempted.")
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        Section {
            LabeledContent("Engine", value: "native-core v\(coreVersion())")
            LabeledContent("Logic Core", value: GreetingKt.sharedGreeting())
            LabeledContent("Version", value: update.currentVersion)
            #if os(macOS)
            MacUpdateSettings()
            #else
            updateRow
            #endif
            Link("GitHub", destination: URL(string: "https://github.com/bagumamartin/BitChord")!)
            Link("Developer", destination: URL(string: "https://github.com/bagumamartin")!)
            Link("Discord", destination: URL(string: "https://discord.gg/pDdKfrdHY6")!)
        } header: {
            Text("About")
        } footer: {
            Text("BitChord \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0")")
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
        }
        .sheet(item: $updateSheet) { release in
            UpdateSheet(release: release)
                .environment(update)
        }
    }

    /// The update row, which is three things depending on what is known.
    ///
    /// A release is offered with its version in the subtitle rather than as a badge:
    /// an update notice that is only a coloured dot asks the reader to guess, and the
    /// one question here is "what is it".
    @ViewBuilder
    private var updateRow: some View {
        if let release = update.available {
            Button {
                updateSheet = release
            } label: {
                SettingsLine(
                    glyph: .update,
                    title: release.version,
                    subtitle: "A newer BitChord is out"
                ) {
                    Image(.bchChevronRight)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 12, height: 12)
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
        } else {
            Button {
                Task { await update.check() }
            } label: {
                if update.checking {
                    ProgressView().controlSize(.small)
                } else {
                    SettingsLine(
                        glyph: .update,
                        title: "Check for Updates",
                        subtitle: update.problem ?? "BitChord \(update.comparableVersion)"
                    ) {
                        EmptyView()
                    }
                }
            }
            .disabled(update.checking)
        }
    }

    private var loginSheet: some View {
        NavigationStack {
            YtMusicLoginView(
                onCaptured: { session, done in
                    auth.accept(session) { accepted in
                        if accepted { loginPresented = false }
                        done(accepted)
                    }
                },
                onDismiss: { loginPresented = false }
            )
        }
        #if os(macOS)
        .frame(minWidth: 720, minHeight: 640)
        #endif
    }

    @ViewBuilder
    private func qualityRow(
        glyph: SettingsGlyph.Kind,
        title: String,
        subtitle: String? = nil,
        badge: String? = nil,
        selection: Binding<String>,
        options: [AudioQualityOption]
    ) -> some View {
        #if os(macOS)
        Picker(selection: selection) {
            ForEach(options) { option in
                Text(option.title).tag(option.id)
            }
        } label: {
            SettingsLine(glyph: glyph, title: title, subtitle: subtitle, badge: badge) {
                EmptyView()
            }
        }
        .pickerStyle(.menu)
        #else
        NavigationLink {
            QualityPickerPage(title: title, selection: selection, options: options)
        } label: {
            SettingsLine(glyph: glyph, title: title, subtitle: subtitle, badge: badge) {
                Text(AudioQualityOption.label(selection.wrappedValue, in: options))
                    .foregroundStyle(.secondary)
            }
        }
        #endif
    }

    private static func cacheLimitMegabytes() -> Int {
        let bytes = PlatformSettings.shared.getLong(key: "audio_cache_limit_bytes", default: Int64(512) * 1024 * 1024)
        return max(512, Int(bytes / (1024 * 1024)))
    }

    private static func formatCache(_ mb: Int) -> String {
        if mb >= 1024 {
            let gb = Double(mb) / 1024
            return String(format: gb == floor(gb) ? "%.0f GB" : "%.1f GB", gb)
        }
        return "\(mb) MB"
    }
}

// MARK: - Account & integrations

private struct AccountIntegrationsView: View {
    @Environment(AuthController.self) private var auth
    @Environment(PlaybackController.self) private var controller
    @Binding var loginPresented: Bool
    @Binding var discordPresented: Bool

    @State private var lastFmUser = PlatformSettings.shared.getString(key: "lastfm_username", default: "")
    @State private var lastFmSession = PlatformSettings.shared.getSecret(key: "lastfm_session") ?? ""
    @State private var lastFmEnabled = PlatformSettings.shared.getBoolean(key: "lastfm_enabled", default: false)
    @State private var lastFmScrobble = PlatformSettings.shared.getBoolean(key: "lastfm_scrobble", default: true)
    @State private var lastFmNowPlaying = PlatformSettings.shared.getBoolean(key: "lastfm_nowplaying", default: true)
    @State private var lastFmKey = PlatformSettings.shared.getSecret(key: "lastfm_api_key") ?? ""
    @State private var lastFmSecret = PlatformSettings.shared.getSecret(key: "lastfm_secret") ?? ""
    @State private var listenToken = PlatformSettings.shared.getSecret(key: "listenbrainz_token") ?? ""
    @State private var listenEnabled = PlatformSettings.shared.getBoolean(key: "listenbrainz_enabled", default: false)
    @State private var discordToken = PlatformSettings.shared.getSecret(key: "discord_token") ?? ""
    @State private var discordName = PlatformSettings.shared.getString(key: "discord_username", default: "")
    @State private var discordRpc = PlatformSettings.shared.getBoolean(key: "discord_rpc_enabled", default: true)
    @State private var discordStatus = PlatformSettings.shared.getString(key: "discord_status", default: "online")
    @State private var discordActivity = PlatformSettings.shared.getString(key: "discord_activity_type", default: "listening")
    @State private var discordNameCustom = PlatformSettings.shared.getString(key: "discord_activity_name", default: "")
    @State private var discordSwap = PlatformSettings.shared.getBoolean(key: "discord_swap_title", default: false)
    @State private var discordUseDetails = PlatformSettings.shared.getBoolean(key: "discord_use_details", default: false)
    @State private var discordAdvanced = PlatformSettings.shared.getBoolean(key: "discord_advanced_mode", default: false)
    @State private var discordButton1Text = PlatformSettings.shared.getString(key: "discord_button_1_text", default: "")
    @State private var discordButton1Visible = PlatformSettings.shared.getBoolean(key: "discord_button_1_visible", default: true)
    @State private var discordButton2Text = PlatformSettings.shared.getString(key: "discord_button_2_text", default: "")
    @State private var discordButton2Visible = PlatformSettings.shared.getBoolean(key: "discord_button_2_visible", default: true)
    @State private var discordInfoDismissed = PlatformSettings.shared.getBoolean(key: "discord_info_dismissed", default: false)
    @State private var scrobbleMin = Double(PlatformSettings.shared.getInt(key: "scrobble_min_duration", default: 30))
    @State private var scrobblePercent = Double(PlatformSettings.shared.getFloat(key: "scrobble_delay_percent", default: 0.5))
    @State private var scrobbleMax = Double(PlatformSettings.shared.getInt(key: "scrobble_delay_seconds", default: 180))
    @State private var scrobblePrimary = PlatformSettings.shared.getString(key: "scrobble_primary_artist", default: "track")

    var body: some View {
        Form {
            // A session that is saved but could not be put back, said out loud.
            //
            // This is the only place it can be seen, and it matters: the failure
            // is invisible everywhere else. The account row says "Not signed in",
            // the library says signed out, and every request goes out anonymous —
            // with nothing on screen to say that a session is *there* and merely
            // unrestored, which is a different thing from never having signed in
            // and the one thing the listener cannot work out for themselves.
            if let reason = auth.sessionUnavailableReason {
                Section {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(reason)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 2)
                }
            }
            Section {
                if auth.signedIn {
                    HStack(spacing: 14) {
                        accountAvatar
                        VStack(alignment: .leading, spacing: 3) {
                            Text(auth.accountName ?? "Signed in")
                                .font(.headline)
                            if let email = auth.accountEmail, !email.isEmpty {
                                Text(email)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 6)

                    // Upstream's `listen_as`, and the reason the account avatar
                    // is not just a picture: a Google account can own several
                    // YouTube channels and they have separate libraries,
                    // histories and scrobbles. Worth a row of its own even with
                    // one channel, because it says which one is in effect —
                    // and with one channel there is nothing to choose, so the
                    // row is hidden rather than shown as a dead end.
                    if (auth.listeningAs?.profiles.count ?? 0) > 1 {
                        NavigationLink {
                            AccountProfileSheet(scopedAccountId: auth.listeningAs?.id)
                        } label: {
                            SettingsLine(
                                glyph: .listenAs,
                                title: "Listen As",
                                subtitle: auth.listeningAs?.activeProfile?.subtitle
                                    ?? auth.listeningAs?.displayName
                                    ?? "Signed in"
                            ) {
                                EmptyView()
                            }
                        }
                    }
                } else {
                    Button {
                        loginPresented = true
                    } label: {
                        SettingsLine(
                            glyph: .person,
                            title: "Sign In",
                            subtitle: "Get personalized recommendations"
                        ) {
                            EmptyView()
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            if auth.signedIn {
                Section {
                    Button("Sign Out", role: .destructive, action: auth.signOut)
                }
            }

            Section {
                Button {
                    discordPresented = true
                } label: {
                    SettingsLine(
                        glyph: .discord,
                        title: "Discord",
                        subtitle: discordSubtitle
                    ) {
                        EmptyView()
                    }
                }
                .buttonStyle(.plain)
                if !discordToken.isEmpty {
                    if !discordInfoDismissed {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Discord has no API for an app to set your presence, so this signs in as your account and speaks its protocol. Your token is stored on this device and only ever sent to Discord — but it is your whole account, and automating one is against Discord's terms of service. Bans for presence alone aren't a thing anyone reports; it's still your call.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            Button("Dismiss") { discordInfoDismissed = true }
                                .font(.footnote.weight(.semibold))
                        }
                    }
                    Toggle("Rich Presence", isOn: $discordRpc)
                    Toggle("Lead with the song", isOn: $discordUseDetails)
                    Toggle("Customise the card", isOn: $discordAdvanced)
                    if discordAdvanced {
                        Picker("Status", selection: $discordStatus) {
                            Text("Online").tag("online")
                            Text("Idle").tag("idle")
                            Text("Do Not Disturb").tag("dnd")
                            Text("Invisible").tag("invisible")
                        }
                        Picker("Activity", selection: $discordActivity) {
                            Text("Listening").tag("listening")
                            Text("Playing").tag("playing")
                            Text("Watching").tag("watching")
                            Text("Competing").tag("competing")
                        }
                        TextField("Activity name", text: $discordNameCustom)
                        Toggle("Swap title and artist", isOn: $discordSwap)
                        Toggle("First button", isOn: $discordButton1Visible)
                        TextField("First button text", text: $discordButton1Text)
                            .disabled(!discordButton1Visible)
                        Toggle("Second button", isOn: $discordButton2Visible)
                        TextField("Second button text", text: $discordButton2Text)
                            .disabled(!discordButton2Visible)
                    } else {
                        Toggle("Swap title and artist", isOn: $discordSwap)
                    }
                }
            } header: {
                Text("Rich Presence")
            } footer: {
                Text(discordAdvanced
                     ? "{song_name}, {artist_name} and {album_name} are replaced with the track. The first button opens the song on YouTube Music, the second this project."
                     : "Show what you’re playing on your Discord profile, updating as the track does.")
            }

            Section {
                Toggle(isOn: $listenEnabled) {
                    SettingsLine(
                        glyph: .listenBrainz,
                        title: "ListenBrainz",
                        subtitle: listenEnabled && !listenToken.isEmpty
                            ? "Connected"
                            : "Enter a token to enable"
                    ) {
                        EmptyView()
                    }
                }
                SecureField("User token", text: $listenToken)
                    .textContentType(.password)
                SettingsSliderRow(
                    glyph: .lastFm,
                    title: "Minimum duration",
                    subtitle: "Songs shorter than this won't scrobble",
                    valueText: "\(Int(scrobbleMin))s",
                    value: $scrobbleMin,
                    range: 10...120,
                    step: 5
                )
                SettingsSliderRow(
                    glyph: .lastFm,
                    title: "Scrobble after",
                    subtitle: "Fraction of the track before a scrobble is sent",
                    valueText: "\(Int(scrobblePercent * 100))%",
                    value: $scrobblePercent,
                    range: 0.25...0.9,
                    step: 0.05
                )
                SettingsSliderRow(
                    glyph: .lastFm,
                    title: "Scrobble delay cap",
                    subtitle: "Cap on scrobble delay in seconds",
                    valueText: "\(Int(scrobbleMax))s",
                    value: $scrobbleMax,
                    range: 30...480,
                    step: 10
                )
                Picker(selection: $scrobblePrimary) {
                    Text("Track artist").tag("track")
                    Text("Album artist").tag("album")
                } label: {
                    SettingsLine(
                        glyph: .lastFm,
                        title: "Primary Artist",
                        subtitle: scrobblePrimary == "album"
                            ? "Scrobbles the lead name alone (“A, B & C” as “A”)"
                            : "Scrobbles the full credit as the catalogue gave it"
                    ) {
                        EmptyView()
                    }
                }
            } header: {
                Text("Scrobbling")
            } footer: {
                Text("Scrobble your listens to Last.fm and ListenBrainz.")
            }

            Section {
                Toggle(isOn: $lastFmEnabled) {
                    SettingsLine(
                        glyph: .lastFm,
                        title: "Last.fm",
                        subtitle: lastFmSession.isEmpty
                            ? "Tap to sign in"
                            : "Signed in as \(lastFmUser)"
                    ) {
                        EmptyView()
                    }
                }
                if lastFmEnabled && !lastFmSession.isEmpty {
                    Toggle("Scrobble Tracks", isOn: $lastFmScrobble)
                    Toggle("Now Playing", isOn: $lastFmNowPlaying)
                    Button("Sign Out of Last.fm", role: .destructive) {
                        lastFmSession = ""
                        lastFmUser = ""
                        lastFmEnabled = false
                        AppSettings.shared.setLastFmSession(value: "")
                        AppSettings.shared.setLastFmUsername(value: "")
                    }
                } else {
                    Button("Authorise Last.fm") { controller.authoriseLastFm() }
                }
                TextField("API key", text: $lastFmKey)
                SecureField("Shared secret", text: $lastFmSecret)
            } footer: {
                Text("An API key and shared secret are required to authorise. Don’t share them.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Account & Integrations")
        .modifier(AccountScrobblePersist(
            lastFmEnabled: $lastFmEnabled,
            lastFmScrobble: $lastFmScrobble,
            lastFmNowPlaying: $lastFmNowPlaying,
            lastFmKey: $lastFmKey,
            lastFmSecret: $lastFmSecret,
            listenToken: $listenToken,
            listenEnabled: $listenEnabled,
            scrobblePrimary: $scrobblePrimary,
            controller: controller
        ))
        .modifier(AccountDiscordPersist(
            discordRpc: $discordRpc,
            discordStatus: $discordStatus,
            discordActivity: $discordActivity,
            discordNameCustom: $discordNameCustom,
            discordSwap: $discordSwap,
            discordUseDetails: $discordUseDetails,
            discordAdvanced: $discordAdvanced,
            discordButton1Text: $discordButton1Text,
            discordButton1Visible: $discordButton1Visible,
            discordButton2Text: $discordButton2Text,
            discordButton2Visible: $discordButton2Visible,
            discordInfoDismissed: $discordInfoDismissed,
            scrobbleMin: $scrobbleMin,
            scrobblePercent: $scrobblePercent,
            scrobbleMax: $scrobbleMax
        ))
        .onAppear {
            lastFmUser = PlatformSettings.shared.getString(key: "lastfm_username", default: "")
            lastFmSession = PlatformSettings.shared.getSecret(key: "lastfm_session") ?? ""
            discordToken = PlatformSettings.shared.getSecret(key: "discord_token") ?? ""
            discordName = PlatformSettings.shared.getString(key: "discord_username", default: "")
        }
    }

    private var discordSubtitle: String {
        if discordToken.isEmpty { return "Tap to connect" }
        if !discordRpc { return "Connected, presence off" }
        if !discordName.isEmpty { return "Sharing as @\(discordName)" }
        return "Sharing your listens"
    }

    @ViewBuilder
    private var accountAvatar: some View {
        if let url = auth.accountPhotoUrl.flatMap(URL.init(string:)) {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                SettingsGlyph(kind: .person)
            }
            .frame(width: 52, height: 52)
            .clipShape(Circle())
        } else {
            SettingsGlyph(kind: .person)
                .scaleEffect(1.4)
        }
    }
}

// MARK: - Lyrics sources

private struct LyricsSourcesView: View {
    @Binding var selection: String
    @Binding var order: String
    @Binding var syllableSync: Bool
    /// The key for the two authenticated PaxSeniX routes.
    ///
    /// Held here rather than in the ordinary settings because it is a bearer
    /// credential, and this is the only screen where it belongs: a source
    /// configured from a list of names, not a row anybody types into.
    @State private var paxSenixKey = PlatformSettings.shared.getSecret(key: "paxsenix_api_key") ?? ""
    /// iOS-only: `EditMode` does not exist on macOS, where the list is reordered
    /// by click-to-move instead.
    #if os(iOS)
    @State private var editMode: EditMode = .inactive
    #endif

    var body: some View {
        List {
            Section {
                ForEach(orderedIds, id: \.self) { id in
                    if let source = LyricsSourceOption.all.first(where: { $0.name == id }) {
                        Toggle(isOn: enabledBinding(source.id)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(source.label)
                                Text(source.detail)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .onMove(perform: move)
            } footer: {
                Text("Tried in this order — drag to reorder. The highest-priority source to answer at all wins, unless Prefer Word-Synced Lyrics says to keep looking for a word-synced one.")
            }
            if usesAuthenticatedRoutes {
                Section {
                    SecureField("API key", text: $paxSenixKey)
                        #if os(iOS)
                        .textContentType(.password)
                        #endif
                    if !paxSenixKey.isEmpty {
                        Button("Remove Key", role: .destructive) {
                            paxSenixKey = ""
                            AppSettings.shared.setPaxSenixApiKey(value: "")
                        }
                    }
                } header: {
                    Text("PaxSeniX Key")
                } footer: {
                    Text("PaxSeniX Spotify and PaxSeniX Musixmatch reach two catalogues Apple Music does not carry, and both need a key from paxsenix.org. Everything else on this list works without one. Stored in the Keychain, not in preferences.")
                }
            }
            Section {
                Button("Reset to Default") {
                    AppSettings.shared.resetLyricsSourceSettings()
                    order = LyricsSourceNames.defaultEnabled
                    selection = LyricsSourceNames.defaultEnabled
                    syllableSync = false
                }
            }
        }
        .navigationTitle("Lyrics Sources")
        #if os(iOS)
        // Reordering the provider list needs edit mode, but forcing it active
        // left the user with no way out of it. An explicit control is what
        // Music does for exactly this.
        .environment(\.editMode, $editMode)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button(editMode == .active ? "Done" : "Reorder") {
                    withAnimation { editMode = editMode == .active ? .inactive : .active }
                }
            }
        }
        #endif
        .onAppear {
            order = LyricsSourceNames.normalizeList(order)
            selection = LyricsSourceNames.normalizeList(selection)
        }
        .onChange(of: paxSenixKey) { _, value in
            AppSettings.shared.setPaxSenixApiKey(value: value)
        }
    }

    private var orderedIds: [String] {
        let saved = LyricsSourceNames.normalizeList(order).split(separator: ",").map(String.init)
        let known = LyricsSourceOption.all.map(\.name)
        let fromSaved = saved.filter { known.contains($0) }
        return fromSaved + known.filter { !fromSaved.contains($0) }
    }

    /// Whether a key is worth asking about at all.
    ///
    /// Asked rather than always shown: with neither authenticated source enabled
    /// the field is a credential box for a host this app is not contacting, and a
    /// row that does nothing is worse than no row.
    private var usesAuthenticatedRoutes: Bool {
        let enabled = Set(LyricsSourceNames.normalizeList(selection)
            .split(separator: ",").map(String.init))
        return enabled.contains("PAXSENIX_SPOTIFY") || enabled.contains("PAXSENIX_MUSIXMATCH")
    }

    private func move(from source: IndexSet, to dest: Int) {
        var ids = orderedIds
        ids.move(fromOffsets: source, toOffset: dest)
        order = ids.joined(separator: ",")
        let enabled = Set(selection.split(separator: ",").map(String.init))
        selection = ids.filter { enabled.contains($0) }.joined(separator: ",")
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

private struct QualityPickerPage: View {
    let title: String
    @Binding var selection: String
    let options: [AudioQualityOption]

    var body: some View {
        List {
            ForEach(options) { option in
                Button {
                    selection = option.id
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(option.title)
                                .foregroundStyle(.primary)
                            Text(option.detail)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if selection == option.id {
                            Image(systemName: "checkmark")
                                .fontWeight(.semibold)
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                }
            }
        }
        .navigationTitle(title)
    }
}

private struct AutomixPerformancePage: View {
    @Binding var selection: String

    private let modes = [
        ("EFFICIENT", "Efficient", "1 analysis thread · kindest to battery"),
        ("BALANCED", "Balanced", "2 threads · the default"),
        ("PERFORMANCE", "Performance", "4 threads · fastest transitions, warmest phone"),
    ]

    var body: some View {
        List {
            ForEach(modes, id: \.0) { mode in
                Button {
                    selection = mode.0
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(mode.1)
                                .foregroundStyle(.primary)
                            Text(mode.2)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if selection == mode.0 {
                            Image(systemName: "checkmark")
                                .fontWeight(.semibold)
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                }
            }
        }
        .navigationTitle("Automix Performance")
    }
}

private struct SpotifyCanvasAuthView: View {
    @Binding var cookie: String

    var body: some View {
        Form {
            Section {
                SecureField("sp_dc cookie", text: $cookie)
                    .textContentType(.password)
            } header: {
                Text("Spotify Canvas Setup")
            } footer: {
                Text("Paste the sp_dc cookie from an open Spotify web session. BitChord uses it only to look up looping motion art. Leave blank to skip.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Spotify Canvas")
    }
}

// MARK: - Rows

private struct SettingsLine<Trailing: View>: View {
    var glyph: SettingsGlyph.Kind
    var title: String
    var subtitle: String? = nil
    var badge: String? = nil
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            SettingsGlyph(kind: glyph)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(title)
                    if let badge {
                        Text(badge.uppercased())
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor, in: Capsule())
                    }
                }
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.vertical, 3)
    }
}

private struct SettingsToggleLine: View {
    var glyph: SettingsGlyph.Kind
    var title: String
    var subtitle: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            SettingsLine(glyph: glyph, title: title, subtitle: subtitle) {
                EmptyView()
            }
        }
        .padding(.vertical, 2)
    }
}

private struct SettingsSubToggle: View {
    var title: String
    @Binding var isOn: Bool
    var badge: String? = nil

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: 8) {
                Text(title)
                if let badge {
                    Text(badge.uppercased())
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange, in: Capsule())
                }
            }
        }
        .padding(.leading, 41)
        .padding(.vertical, 2)
    }
}

private struct SettingsSliderRow: View {
    var glyph: SettingsGlyph.Kind
    var title: String
    var subtitle: String
    var valueText: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsLine(glyph: glyph, title: title, subtitle: subtitle) {
                Text(valueText)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: $value, in: range, step: step)
                .padding(.leading, 41)
        }
        .padding(.vertical, 4)
    }
}

private struct SettingsGlyph: View {
    enum Kind {
        case person, listenAs, sources, wifi, cellular, download
        case crossfade, automix, skipSilence, spatial, dolby, equalizer, nerd, video, speed
        case theme, reduceMotion, reduceBlur, fullBleed, canvas, lyrics, lyricsSources
        case storage, clearSongs, clearImages
        case swipe, dontRepeat, hideVolume
        case discord, listenBrainz, lastFm
        case replay, genres, export, importData, listenTogether
        case update
        case precision, loudness, sharedFolder, cpu, musicOnly, models
        case performance, refreshRate, folder, localMusic, filter
        case songStatus, align, mesh
    }

    var kind: Kind

    var body: some View {
        Group {
            if let asset { Image(asset).resizable().scaledToFit() }
            else { Image(systemName: symbol).font(.system(size: 21)) }
        }
        .foregroundStyle(.primary)
        .frame(width: 29, height: 29)
        .accessibilityHidden(true)
    }

    private var asset: String? {
        switch kind {
        case .dolby: "bch-dolby"
        case .performance: "bch-performance"
        case .refreshRate: "bch-frame-rate"
        case .download: "bch-download"
        case .lyrics: "bch-lyrics"
        case .localMusic: "bch-library"
        case .musicOnly: "bch-music-note"
        case .dontRepeat: "bch-clock"
        default: "bch-settings-\(symbolName)"
        }
    }
    private var symbolName: String {
        switch kind {
        case .person: "person"
        case .listenAs, .listenTogether: "groups"
        case .sources: "extension"
        case .wifi: "wifi"
        case .cellular: "signal_cellular_alt"
        case .crossfade: "waves"
        case .automix, .models: "auto_awesome"
        case .skipSilence, .hideVolume: "volume_off"
        case .dolby: "surround_sound"
        case .spatial: "surround_sound"
        case .equalizer, .align: "tune"
        case .nerd, .replay: "bar_chart"
        case .video: "smart_display"
        case .theme: "brightness_4"
        case .reduceMotion: "motion_photos_off"
        case .reduceBlur: "blur_off"
        case .fullBleed: "fullscreen"
        case .canvas: "animation"
        case .lyricsSources: "language"
        case .storage: "storage"
        case .clearSongs, .clearImages: "delete_sweep"
        case .swipe: "playlist_play"
        case .genres: "local_offer"
        case .export: "file_upload"
        case .importData, .update: "file_download"
        case .loudness, .precision: "graphic_eq"
        case .sharedFolder, .folder: "folder"
        case .filter: "filter_alt"
        case .songStatus: "visibility_off"
        case .mesh: "gradient"
        case .speed, .performance: "speed"
        case .refreshRate: "monitor"
        case .cpu: "memory"
        case .discord: "chat"
        case .listenBrainz: "cloud"
        case .lastFm: "history"
        default: "settings"
        }
    }

    private var symbol: String {
        switch kind {
        case .person: "person.fill"
        case .listenAs: "person.2.fill"
        case .sources: "square.stack.3d.up.fill"
        case .wifi: "wifi"
        case .cellular: "antenna.radiowaves.left.and.right"
        case .download: "arrow.down.circle.fill"
        case .crossfade: "waveform"
        case .speed: "gauge.with.dots.needle.67percent"
        case .automix: "sparkles"
        case .skipSilence: "speaker.slash.fill"
        case .dolby: "hifispeaker.2.fill"
        case .spatial: "hifispeaker.2.fill"
        case .equalizer: "slider.vertical.3"
        case .nerd: "chart.bar.fill"
        case .video: "play.rectangle.fill"
        case .theme: "circle.lefthalf.filled"
        case .reduceMotion: "figure.walk.motion"
        case .reduceBlur: "circle.hexagongrid.fill"
        case .fullBleed: "arrow.up.left.and.arrow.down.right"
        case .canvas: "livephoto"
        case .lyrics: "text.alignleft"
        case .lyricsSources: "globe"
        case .storage: "internaldrive.fill"
        case .clearSongs: "trash.fill"
        case .clearImages: "photo.on.rectangle.angled"
        case .swipe: "text.line.first.and.arrowtriangle.forward"
        case .dontRepeat: "arrow.uturn.backward"
        case .hideVolume: "speaker.wave.2.fill"
        case .discord: "bubble.left.and.bubble.right.fill"
        case .listenBrainz: "cloud.fill"
        case .lastFm: "clock.arrow.circlepath"
        case .replay: "chart.bar.fill"
        case .genres: "tag.fill"
        case .export: "square.and.arrow.up.fill"
        case .importData: "square.and.arrow.down.fill"
        // Two people and a sound wave, because the alternative — a single person —
        // reads as a profile picture and this row is not about a profile.
        case .listenTogether: "person.2.wave.2.fill"
        // An arrow down into a tray, which is what "a newer build is here" looks like
        // and is not the gear everybody expects an update row to be.
        case .update: "arrow.down.app.fill"
        case .precision: "waveform.path.ecg"
        case .loudness: "speaker.wave.3.fill"
        case .sharedFolder: "folder.fill.badge.plus"
        case .cpu: "cpu.fill"
        // A brain rather than a chip: this row is about what the analysis knows,
        // not about the hardware that runs it — `cpu` already sits one row above.
        case .models: "brain"
        case .musicOnly: "music.note"
        case .performance: "gauge.with.dots.needle.100percent"
        case .refreshRate: "display"
        case .folder: "folder.fill"
        case .localMusic: "music.note.list"
        case .filter: "line.3.horizontal.decrease.circle.fill"
        case .songStatus: "eye.slash.fill"
        case .align: "arrow.left.and.right"
        case .mesh: "paintbrush.pointed.fill"
        }
    }


}

private struct AudioQualityOption: Identifiable {
    let id: String
    let title: String
    let detail: String

    static let stream: [AudioQualityOption] = [
        .init(id: "LOW", title: "Low", detail: "64 kbps · uses the least data"),
        .init(id: "MEDIUM", title: "Medium", detail: "Best available · ~171 kbps Opus"),
        .init(id: "HIGH", title: "High", detail: "JioSaavn up to 320 kbps · YouTube fallback"),
        .init(id: "LOSSLESS", title: "Lossless", detail: "Lossless and Hi-Res from sources that supply them"),
    ]

    static let download: [AudioQualityOption] = [
        .init(id: "STANDARD", title: "Standard", detail: "128 kbps AAC"),
        .init(id: "HIGH", title: "High", detail: "Best AAC the source will give"),
        .init(id: "LOSSLESS", title: "Lossless", detail: "Keeps FLAC when a source has it"),
    ]

    static func label(_ id: String, in options: [AudioQualityOption]) -> String {
        options.first { $0.id == id }?.title ?? id.capitalized
    }
}

/// One lyrics source, as the shared module describes it.
///
/// The list, the labels, the subtitles and the order all come from
/// `AppSettings.lyricsSourceCatalogJson()` rather than a copy held here. This
/// screen used to keep its own, and the three sources added along with the ISRC
/// pass did not appear in it — so the feature was on by default and had no row
/// anywhere to be found, switched off, or read about.
struct LyricsSourceOption: Identifiable, Decodable {
    let name: String
    let label: String
    let detail: String
    let wordSynced: Bool
    let enabled: Bool

    var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name, label, detail, wordSynced, enabled
    }

    /// Every source, in the order the shared module puts them.
    static var all: [LyricsSourceOption] {
        let json = AppSettings.shared.lyricsSourceCatalogJson()
        guard let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([LyricsSourceOption].self, from: data)
        else {
            // An empty list rather than a hard-coded fallback: a fallback here
            // would be the stale copy all over again, and the symptom would be a
            // settings screen that looks fine and controls nothing.
            return []
        }
        return decoded
    }

    static func summary(_ raw: String) -> String {
        let enabled = Set(LyricsSourceNames.normalizeList(raw).split(separator: ",").map(String.init))
        let names = all.filter { enabled.contains($0.name) }.map(\.label)
        if names.isEmpty { return "None — no lyrics will be fetched" }
        return names.joined(separator: ", ")
    }
}

private struct SettingsPlaybackPersist: ViewModifier {
    var controller: PlaybackController
    @Binding var crossfade: Int
    @Binding var spatial: Bool
    @Binding var automix: Bool
    @Binding var automixSequence: Bool
    @Binding var automixPerf: String
    @Binding var skipSilence: Bool
    @Binding var playbackSpeed: Double
    /// Raised when Automix goes on. The models are what make Automix's timing real,
    /// so switching it on with none installed is the one moment the question is
    /// worth asking again.
    var onAutomixEnabled: () -> Void = {}

    func body(content: Content) -> some View {
        content
            .onChange(of: crossfade) { _, value in
                AppSettings.shared.setCrossfadeSeconds(value: Swift.Int32(value))
                controller.updateCrossfade(seconds: value)
            }
            .onChange(of: spatial) { _, value in
                AppSettings.shared.setSpatialAudio(value: value)
                controller.updateSpatial(enabled: value)
            }
            .onChange(of: automix) { _, value in
                AppSettings.shared.setSmartFadeEnabled(value: value)
                controller.setAutomixEnabled(value)
                if value { onAutomixEnabled() }
            }
            .onChange(of: automixSequence) { _, value in
                PlatformSettings.shared.putBoolean(key: "automix_smart_sequence", value: value)
                controller.smartSequencingPreferenceChanged()
            }
            .onChange(of: automixPerf) { _, value in
                controller.setAutomixPerformanceMode(value)
            }
            .onChange(of: skipSilence) { _, value in
                AppSettings.shared.setSkipSilence(value: value)
                controller.updateSkipSilence(enabled: value)
            }
            .onChange(of: playbackSpeed) { _, value in
                AppSettings.shared.setPlaybackSpeed(value: Float(value))
                controller.updateSpeed(Float(value))
            }
    }
}

private struct SettingsQualityPersist: ViewModifier {
    var controller: PlaybackController
    @Binding var wifiQuality: String
    @Binding var cellQuality: String
    @Binding var downloadQuality: String
    @Binding var wifiOnlyDownloads: Bool
    @Binding var cacheLimitMB: Int
    @Binding var outputPcm: String
    @Binding var matchSourceRate: Bool
    @Binding var bitPerfect: Bool
    @Binding var preferUsbDac: Bool
    @Binding var loudness: Bool

    func body(content: Content) -> some View {
        content
            .onChange(of: wifiQuality) { _, value in AppSettings.shared.setAudioQualityWifi(value: value) }
            .onChange(of: cellQuality) { _, value in AppSettings.shared.setAudioQualityCellular(value: value) }
            .onChange(of: downloadQuality) { _, value in AppSettings.shared.setDownloadQuality(value: value) }
            .onChange(of: wifiOnlyDownloads) { _, value in
                AppSettings.shared.setWifiOnlyDownloads(value: value)
                DownloadStore.shared.networkPolicyChanged()
            }
            .onChange(of: outputPcm) { _, value in controller.updateOutputPcmMode(value) }
            .onChange(of: matchSourceRate) { _, value in controller.updateMatchSourceSampleRate(value) }
            .onChange(of: bitPerfect) { _, value in controller.updateBitPerfectOutput(value) }
            .onChange(of: preferUsbDac) { _, value in controller.updatePreferUsbDac(value) }
            .onChange(of: loudness) { _, value in controller.updateLoudnessNormalization(value) }
            .onChange(of: cacheLimitMB) { _, value in
                AppSettings.shared.setAudioCacheLimitBytes(value: Swift.Int64(value) * 1024 * 1024)
                Task { await StreamFileCache.shared.trim() }
            }
    }
}

private struct SettingsExperiencePersist: ViewModifier {
    var controller: PlaybackController
    var appModel: AppModel
    @Binding var nerdStats: Bool
    @Binding var canvas: Bool
    @Binding var canvasCellular: Bool
    @Binding var reduceBlur: Bool
    @Binding var reduceAnimation: Bool
    @Binding var fullBleed: Bool
    @Binding var syncedLyrics: Bool
    @Binding var convertVideo: Bool
    @Binding var swipeNext: Bool
    @Binding var dontRepeat: Bool
    @Binding var hideVolume: Bool
    @Binding var legacyMesh: Bool
    @Binding var preferMusicOnly: Bool
    @Binding var theme: String

    func body(content: Content) -> some View {
        content
            .onChange(of: nerdStats) { _, value in AppSettings.shared.setShowNerdStats(value: value) }
            .onChange(of: canvas) { _, value in
                AppSettings.shared.setAnimatedCanvas(value: value)
                controller.refreshCanvasLookup()
            }
            .onChange(of: canvasCellular) { _, value in
                AppSettings.shared.setCanvasOverCellular(value: value)
                controller.refreshCanvasLookup()
            }
            .onChange(of: reduceBlur) { _, value in AppSettings.shared.setReduceDynamicBlur(value: value) }
            .onChange(of: reduceAnimation) { _, value in AppSettings.shared.setReduceAnimation(value: value) }
            .onChange(of: fullBleed) { _, value in AppSettings.shared.setFullBleedArtwork(value: value) }
            .onChange(of: legacyMesh) { _, value in PlatformSettings.shared.putBoolean(key: "legacy_mesh_gradient", value: value) }
            .onChange(of: preferMusicOnly) { _, value in controller.updatePreferMusicOnly(value) }
            .onChange(of: syncedLyrics) { _, value in AppSettings.shared.setSyncedLyrics(value: value) }
            .onChange(of: convertVideo) { _, value in AppSettings.shared.setConvertVideoToAudio(value: value) }
            .onChange(of: swipeNext) { _, value in AppSettings.shared.setSwipeToPlayNext(value: value) }
            .onChange(of: dontRepeat) { _, value in AppSettings.shared.setDontRepeatSuggestions(value: value) }
            .onChange(of: hideVolume) { _, value in
                AppSettings.shared.setHideVolumeBar(value: value)
                controller.hideVolumeBar = value
            }
            .onChange(of: theme) { _, value in
                AppSettings.shared.setThemeMode(value: value)
                appModel.themeMode = value
            }
    }
}

private struct SettingsExtrasPersist: ViewModifier {
    @Binding var lyricsSources: String
    @Binding var lyricsSourceOrder: String
    @Binding var jiosaavn: Bool
    @Binding var stopBackground: Bool
    @Binding var syllableSync: Bool
    @Binding var language: String
    @Binding var spotifyCookie: String
    @Binding var replayGenres: Bool
    var appModel: AppModel

    func body(content: Content) -> some View {
        content
            .onChange(of: lyricsSources) { _, value in AppSettings.shared.setLyricsSources(value: value) }
            .onChange(of: lyricsSourceOrder) { _, value in AppSettings.shared.setLyricsSourceOrder(value: value) }
            .onChange(of: jiosaavn) { _, value in AppSettings.shared.setJiosaavnEnabled(value: value) }
            .onChange(of: stopBackground) { _, value in AppSettings.shared.setStopWhenBackgrounded(value: value) }
            .onChange(of: syllableSync) { _, value in AppSettings.shared.setPrioritizeSyllableSync(value: value) }
            .onChange(of: language) { _, value in
                PlatformSettings.shared.putString(key: "app_language", value: value)
                appModel.appLanguage = value
            }
            .onChange(of: spotifyCookie) { _, value in AppSettings.shared.setSpotifySpdc(value: value) }
            .onChange(of: replayGenres) { _, value in AppSettings.shared.setReplayGenres(value: value) }
    }
}

/// Persists the settings that live outside the classic groups: the Advanced
/// Options section, the Local Music filter, the Downloads export switch, the
/// song-status caption, and the Performance section.
private struct SettingsAdvancedPersist: ViewModifier {
    var controller: PlaybackController
    @Binding var smartAlign: Bool
    @Binding var hideSongStatus: Bool
    @Binding var exportDownloads: Bool
    @Binding var filterNonMusic: Bool
    @Binding var highPerf: Bool
    @Binding var refreshRate: Int
    @Binding var reduceAnimation: Bool
    @Binding var reduceBlur: Bool

    func body(content: Content) -> some View {
        content
            .onChange(of: smartAlign) { _, value in controller.setSmartVersionAlignment(value) }
            .onChange(of: hideSongStatus) { _, value in controller.updateHideSongStatus(value) }
            // The read side is `DownloadStore.folder`: on, downloads land in the
            // shared Music/BitChord folder where other music apps can see them;
            // off, they stay in BitChord's own storage.
            .onChange(of: exportDownloads) { _, value in PlatformSettings.shared.putBoolean(key: "export_downloads", value: value) }
            // The read side is the local-library scan, which drops rows that
            // fail `LocalMusicEligibility` while this is on.
            .onChange(of: filterNonMusic) { _, value in PlatformSettings.shared.putBoolean(key: "filter_non_music_audio", value: value) }
            .onChange(of: highPerf) { _, value in
                PlatformSettings.shared.putBoolean(key: "high_performance_mode", value: value)
                if value {
                    // Upstream's rule: a sustained high refresh rate and frozen
                    // gradients are opposites, so enabling this unfreezes both.
                    // Each write flows through its own persist above.
                    reduceAnimation = false
                    reduceBlur = false
                }
                PerformanceTuner.shared.apply(highPerformance: value, refreshRateHz: refreshRate)
            }
            .onChange(of: refreshRate) { _, value in
                PlatformSettings.shared.putInt(key: "performance_refresh_rate", value: Swift.Int32(value))
                PerformanceTuner.shared.apply(highPerformance: highPerf, refreshRateHz: value)
            }
    }
}

private struct AccountScrobblePersist: ViewModifier {
    @Binding var lastFmEnabled: Bool
    @Binding var lastFmScrobble: Bool
    @Binding var lastFmNowPlaying: Bool
    @Binding var lastFmKey: String
    @Binding var lastFmSecret: String
    @Binding var listenToken: String
    @Binding var listenEnabled: Bool
    @Binding var scrobblePrimary: String
    var controller: PlaybackController

    func body(content: Content) -> some View {
        content
            .onChange(of: lastFmEnabled) { _, value in
                AppSettings.shared.setLastFmEnabled(value: value)
                if value { controller.authoriseLastFm() }
            }
            .onChange(of: lastFmScrobble) { _, value in AppSettings.shared.setLastFmScrobble(value: value) }
            .onChange(of: lastFmNowPlaying) { _, value in AppSettings.shared.setLastFmNowPlaying(value: value) }
            .onChange(of: lastFmKey) { _, value in AppSettings.shared.setLastFmApiKey(value: value) }
            .onChange(of: lastFmSecret) { _, value in AppSettings.shared.setLastFmSecret(value: value) }
            .onChange(of: listenToken) { _, value in AppSettings.shared.setListenBrainzToken(value: value) }
            .onChange(of: scrobblePrimary) { _, value in controller.updateScrobblePrimaryArtist(value) }
            .onChange(of: listenEnabled) { _, value in
                if value && listenToken.isEmpty { return }
                AppSettings.shared.setListenBrainzEnabled(value: value)
            }
    }
}

private struct AccountDiscordPersist: ViewModifier {
    @Binding var discordRpc: Bool
    @Binding var discordStatus: String
    @Binding var discordActivity: String
    @Binding var discordNameCustom: String
    @Binding var discordSwap: Bool
    @Binding var discordUseDetails: Bool
    @Binding var discordAdvanced: Bool
    @Binding var discordButton1Text: String
    @Binding var discordButton1Visible: Bool
    @Binding var discordButton2Text: String
    @Binding var discordButton2Visible: Bool
    @Binding var discordInfoDismissed: Bool
    @Binding var scrobbleMin: Double
    @Binding var scrobblePercent: Double
    @Binding var scrobbleMax: Double

    func body(content: Content) -> some View {
        content
            .modifier(AccountDiscordCardPersist(
                discordRpc: $discordRpc,
                discordStatus: $discordStatus,
                discordActivity: $discordActivity,
                discordNameCustom: $discordNameCustom,
                discordSwap: $discordSwap,
                discordUseDetails: $discordUseDetails,
                discordAdvanced: $discordAdvanced
            ))
            .modifier(AccountDiscordButtonsPersist(
                discordButton1Text: $discordButton1Text,
                discordButton1Visible: $discordButton1Visible,
                discordButton2Text: $discordButton2Text,
                discordButton2Visible: $discordButton2Visible,
                discordInfoDismissed: $discordInfoDismissed,
                scrobbleMin: $scrobbleMin,
                scrobblePercent: $scrobblePercent,
                scrobbleMax: $scrobbleMax
            ))
    }
}

private struct AccountDiscordCardPersist: ViewModifier {
    @Binding var discordRpc: Bool
    @Binding var discordStatus: String
    @Binding var discordActivity: String
    @Binding var discordNameCustom: String
    @Binding var discordSwap: Bool
    @Binding var discordUseDetails: Bool
    @Binding var discordAdvanced: Bool

    func body(content: Content) -> some View {
        content
            .onChange(of: discordRpc) { _, value in AppSettings.shared.setDiscordRpcEnabled(value: value) }
            .onChange(of: discordStatus) { _, value in AppSettings.shared.setDiscordStatus(value: value) }
            .onChange(of: discordActivity) { _, value in AppSettings.shared.setDiscordActivityType(value: value) }
            .onChange(of: discordNameCustom) { _, value in AppSettings.shared.setDiscordActivityName(value: value) }
            .onChange(of: discordSwap) { _, value in AppSettings.shared.setDiscordSwapTitle(value: value) }
            .onChange(of: discordUseDetails) { _, value in AppSettings.shared.setDiscordUseDetails(value: value) }
            .onChange(of: discordAdvanced) { _, value in AppSettings.shared.setDiscordAdvancedMode(value: value) }
    }
}

private struct AccountDiscordButtonsPersist: ViewModifier {
    @Binding var discordButton1Text: String
    @Binding var discordButton1Visible: Bool
    @Binding var discordButton2Text: String
    @Binding var discordButton2Visible: Bool
    @Binding var discordInfoDismissed: Bool
    @Binding var scrobbleMin: Double
    @Binding var scrobblePercent: Double
    @Binding var scrobbleMax: Double

    func body(content: Content) -> some View {
        content
            .onChange(of: discordButton1Text) { _, value in AppSettings.shared.setDiscordButton1Text(value: value) }
            .onChange(of: discordButton1Visible) { _, value in AppSettings.shared.setDiscordButton1Visible(value: value) }
            .onChange(of: discordButton2Text) { _, value in AppSettings.shared.setDiscordButton2Text(value: value) }
            .onChange(of: discordButton2Visible) { _, value in AppSettings.shared.setDiscordButton2Visible(value: value) }
            .onChange(of: discordInfoDismissed) { _, value in AppSettings.shared.setDiscordInfoDismissed(value: value) }
            .onChange(of: scrobbleMin) { _, value in AppSettings.shared.setScrobbleMinDuration(value: Swift.Int32(value)) }
            .onChange(of: scrobblePercent) { _, value in AppSettings.shared.setScrobbleDelayPercent(value: Float(value)) }
            .onChange(of: scrobbleMax) { _, value in AppSettings.shared.setScrobbleDelaySeconds(value: Swift.Int32(value)) }
    }
}

/// Holds the display at a sustained high refresh rate while High Performance
/// Mode is on, by keeping a display link alive that requests the chosen
/// frame-rate range.
///
/// A retained link rather than a one-shot request: the range is a property of a
/// live link, so with nothing holding one the system falls back to its own
/// policy. Invalidated the moment the mode turns off, which is what hands the
/// policy back. The system still clamps to what the panel can do — asking for
/// 120 Hz on a 60 Hz screen is a request, not a mode switch.
final class PerformanceTuner {
    static let shared = PerformanceTuner()

    /// The rates the picker offers. Fixed rather than queried off the panel:
    /// the system clamps the request to what the hardware can do, so offering a
    /// rate the screen cannot reach degrades to the screen's own maximum.
    static let supportedRates = [60, 90, 120]

    #if os(iOS)
    private var link: CADisplayLink?
    #endif

    func apply(highPerformance: Bool, refreshRateHz: Int) {
        #if os(iOS)
        link?.invalidate()
        link = nil
        guard highPerformance else { return }
        let clamped = min(max(refreshRateHz, 30), 240)
        let link = CADisplayLink(target: self, selector: #selector(tick))
        if #available(iOS 15.0, *) {
            let max = Float(clamped)
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: max, preferred: max)
        } else {
            link.preferredFramesPerSecond = min(clamped, 60)
        }
        link.add(to: .main, forMode: .common)
        self.link = link
        #else
        // macOS varies the refresh itself (ProMotion is the panel's own
        // policy); there is no per-app hold to request, so the persisted key is
        // the whole of the setting there.
        _ = (highPerformance, refreshRateHz)
        #endif
    }

    #if os(iOS)
    @objc private func tick() {}
    #endif
}

/// Whether a scanned file counts as music, ported 1:1 from upstream
/// `LocalMediaRepository.isEligibleLocalMusic`.
///
/// Media scanners mark notification sounds and voice notes as music, so the
/// scan needs a second gate of its own: at least 30 seconds long, a music
/// container, and nowhere under an alarms / notifications / ringtones /
/// podcasts / audiobooks / recordings path. Kept beside the toggle that
/// controls it so the rule and its switch cannot drift apart; the scan calls
/// this per file while `filter_non_music_audio` is on.
enum LocalMusicEligibility {
    static let minDurationSeconds = 30.0

    static let musicExtensions: Set<String> = [
        "mp3", "m4a", "flac", "ogg", "opus", "aac", "webm",
    ]

    static let nonMusicPathSegments = [
        "/alarms/",
        "/notifications/",
        "/ringtones/",
        "/podcasts/",
        "/audiobooks/",
        "/recordings/",
        "/voice recorder/",
        "/sound_recorder/",
        "/call_rec/",
        "/whatsapp voice notes/",
    ]

    static func isEligible(durationSeconds: Double, displayName: String, path: String?) -> Bool {
        if durationSeconds < minDurationSeconds { return false }
        let fileName: String = {
            if let path, let last = path.split(separator: "/").last, !last.isEmpty {
                return String(last)
            }
            return displayName
        }()
        guard let ext = fileName.split(separator: ".").last.map({ $0.lowercased() }),
              musicExtensions.contains(ext)
        else {
            return false
        }
        guard let path else { return true }
        let normalized = path.replacingOccurrences(of: "\\", with: "/").lowercased()
        return !nonMusicPathSegments.contains { normalized.contains($0) }
    }
}

private struct SettingsBackupFile: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var text: String
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws {
        text = String(data: configuration.file.regularFileContents ?? Data(), encoding: .utf8) ?? "{}"
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

@MainActor
private enum BitChordBackup {
    static func suggestedName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return "bitchord-backup-\(formatter.string(from: Date()))"
    }

    static func exportText() -> String {
        var prefs = AppSettings.shared.exportPrefsJson()
        let genres = PlatformSettings.shared.getBoolean(key: "replay_genres", default: true)
        if prefs.hasSuffix("}") {
            let insert = "\"replay_genres\":\"\(genres)\""
            prefs = prefs == "{}" ? "{\(insert)}" : String(prefs.dropLast()) + ",\(insert)}"
        }
        let listening = ListeningStore.shared.exportJSON().flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return "{\"app\":\"bitchord\",\"version\":1,\"prefs\":\(prefs),\"listening\":\(listening)}"
    }

    static func importText(_ raw: String) {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            AppSettings.shared.importPrefsJson(raw: raw)
            return
        }
        if let listening = obj["listening"],
           let payload = try? JSONSerialization.data(withJSONObject: listening) {
            ListeningStore.shared.importJSON(payload)
        }
        if let prefs = obj["prefs"],
           let payload = try? JSONSerialization.data(withJSONObject: prefs),
           let text = String(data: payload, encoding: .utf8) {
            AppSettings.shared.importPrefsJson(raw: text)
            if let map = prefs as? [String: Any] {
                let flag = (map["replay_genres"] as? String) ?? (map["replay_genres"] as? Bool).map { $0 ? "true" : "false" }
                if let flag { PlatformSettings.shared.putBoolean(key: "replay_genres", value: flag == "true") }
            }
            return
        }
        AppSettings.shared.importPrefsJson(raw: raw)
    }
}


private struct TranslationPreferenceView: View {
    @Binding var selection: String
    let translator: LyricsTranslator
    @State private var search = ""
    var body: some View {
        List {
            Button { selection = "" } label: {
                HStack { Text("Follow the App Language"); Spacer(); if selection.isEmpty { Image(systemName: "checkmark") } }
            }
            ForEach(translator.languages(for: .translate).filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }) { language in
                Button { selection = language.code } label: {
                    HStack { Text(language.name); Spacer(); if selection == language.code { Image(systemName: "checkmark") } }
                }
            }
        }
        .foregroundStyle(.primary)
        .navigationTitle("Translation Language")
        .searchable(text: $search)
        .onAppear { translator.loadLanguages() }
    }
}
