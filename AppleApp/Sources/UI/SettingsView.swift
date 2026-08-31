import SwiftUI
import BitChordShared
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Apple Settings-style grouped form. Structure and copy follow upstream;
/// chrome is System Settings / iOS Settings: glyph wells, drill-downs, footers.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(PlaybackController.self) private var controller
    @Environment(AuthController.self) private var auth
    @Environment(AppModel.self) private var appModel

    @State private var crossfade = Int(PlatformSettings.shared.getInt(key: "crossfade_seconds", default: 0))
    @State private var spatial = PlatformSettings.shared.getBoolean(key: "spatial_audio", default: false)
    @State private var automix = PlatformSettings.shared.getBoolean(key: "smart_fade_enabled", default: false)
    @State private var skipSilence = PlatformSettings.shared.getBoolean(key: "skip_silence", default: false)
    @State private var wifiQuality = PlatformSettings.shared.getString(key: "audio_quality_wifi", default: "HIGH")
    @State private var cellQuality = PlatformSettings.shared.getString(key: "audio_quality_cellular", default: "HIGH")
    @State private var downloadQuality = PlatformSettings.shared.getString(key: "download_quality", default: "LOSSLESS")
    @State private var wifiOnlyDownloads = PlatformSettings.shared.getBoolean(key: "wifi_only_downloads", default: true)
    @State private var nerdStats = PlatformSettings.shared.getBoolean(key: "show_nerd_stats", default: false)
    @State private var canvas = PlatformSettings.shared.getBoolean(key: "animated_canvas", default: true)
    @State private var canvasCellular = PlatformSettings.shared.getBoolean(key: "canvas_over_cellular", default: false)
    @State private var reduceBlur = PlatformSettings.shared.getBoolean(key: "reduce_dynamic_blur", default: false)
    @State private var reduceAnimation = PlatformSettings.shared.getBoolean(key: "reduce_animation", default: false)
    @State private var fullBleed = PlatformSettings.shared.getBoolean(key: "full_bleed_artwork", default: true)
    @State private var syncedLyrics = PlatformSettings.shared.getBoolean(key: "synced_lyrics", default: true)
    @State private var convertVideo = PlatformSettings.shared.getBoolean(key: "convert_video_to_audio", default: true)
    @State private var swipeNext = PlatformSettings.shared.getBoolean(key: "swipe_to_play_next", default: false)
    @State private var dontRepeat = PlatformSettings.shared.getBoolean(key: "dont_repeat_suggestions", default: false)
    @State private var hideVolume = PlatformSettings.shared.getBoolean(key: "hide_volume_bar", default: false)
    @State private var theme = PlatformSettings.shared.getString(key: "theme_mode", default: "dark")
    @State private var lyricsSources = PlatformSettings.shared.getString(key: "lyrics_sources", default: "BETTER,PLUS,SIMP,LRCLIB")
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
    @State private var songCacheNote: String?
    @State private var imageCacheNote: String?

    private var metered: Bool { NetworkQuality.shared.metered }

    var body: some View {
        NavigationStack {
            settingsForm
                .navigationTitle("Settings")
                #if os(iOS)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        #endif
    }
        #if os(macOS)
        .frame(minWidth: 560, idealWidth: 620, minHeight: 720)
        #endif
        .preferredColorScheme(appModel.preferredScheme)
        .sheet(isPresented: $loginPresented) { loginSheet }
        .sheet(isPresented: $discordPresented) { DiscordLoginView() }
        .modifier(SettingsPlaybackPersist(
            controller: controller,
            crossfade: $crossfade,
            spatial: $spatial,
            automix: $automix,
            skipSilence: $skipSilence,
            playbackSpeed: $playbackSpeed
        ))
        .modifier(SettingsQualityPersist(
            wifiQuality: $wifiQuality,
            cellQuality: $cellQuality,
            downloadQuality: $downloadQuality,
            wifiOnlyDownloads: $wifiOnlyDownloads,
            cacheLimitMB: $cacheLimitMB
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
            theme: $theme
        ))
        .modifier(SettingsExtrasPersist(
            lyricsSources: $lyricsSources,
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

    private var settingsForm: some View {
        Form {
            accountSection
            audioQualitySection
            downloadsSection
            playbackSection
            appearanceSection
            storageSection
            yourDataSection
            miscellaneousSection
            aboutSection
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
        if let email = auth.accountEmail, !email.isEmpty { return email }
        if let name = auth.accountName, !name.isEmpty { return name }
        return auth.signedIn ? "Signed in" : "Not signed in"
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
        } header: {
            Text("Audio Quality")
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
        } header: {
            Text("Downloads")
        }
    }

    // MARK: - Playback

    private var playbackSection: some View {
        Section {
            if !automix {
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
                    ? "Blends every transition, timed automatically from each track. Turn off if facing overheating or lag."
                    : "Times and blends transitions automatically, no slider needed.",
                isOn: $automix
            )
            SettingsToggleLine(
                glyph: .skipSilence,
                title: "Skip Silence",
                subtitle: "Trim gaps longer than a second",
                isOn: $skipSilence
            )
            SettingsSliderRow(
                glyph: .crossfade,
                title: "Playback Speed",
                subtitle: "Slows or speeds the mix without changing pitch on the engine",
                valueText: String(format: "%.2fx", playbackSpeed),
                value: $playbackSpeed,
                range: 0.5...2.0,
                step: 0.05
            )
            SettingsToggleLine(
                glyph: .spatial,
                title: "Spatial Audio",
                subtitle: "Widens stereo tracks for a more immersive feel",
                isOn: $spatial
            )
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
        } header: {
            Text("Playback")
        } footer: {
            Text("Gapless stays on regardless. Automix replaces the crossfade slider with a pair-by-pair blend.")
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
                SettingsToggleLine(
                    glyph: .lyrics,
                    title: "Prefer Word-Synced Lyrics",
                    subtitle: "Syllable timings win the lyrics race when a source has them",
                    isOn: $syllableSync
                )
                NavigationLink {
                    LyricsSourcesView(selection: $lyricsSources)
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
                importPresented = true
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

    // MARK: - About

    private var aboutSection: some View {
        Section {
            LabeledContent("Engine", value: "native-core v\(coreVersion())")
            LabeledContent("Logic Core", value: GreetingKt.sharedGreeting())
            Link("GitHub", destination: URL(string: "https://github.com/kushagrasinghx/BitChord")!)
            Link("Developer", destination: URL(string: "https://github.com/kushagrasinghx")!)
            Link("Discord", destination: URL(string: "https://discord.gg/pDdKfrdHY6")!)
        } header: {
            Text("About")
        } footer: {
            Text("BitChord \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0")")
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
        }
    }

    private var loginSheet: some View {
        NavigationStack {
            YtMusicLoginView { header in
                auth.accept(header)
                loginPresented = false
            }
            .navigationTitle("Sign In")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { loginPresented = false }
                }
            }
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
    @State private var lastFmSession = PlatformSettings.shared.getString(key: "lastfm_session", default: "")
    @State private var lastFmEnabled = PlatformSettings.shared.getBoolean(key: "lastfm_enabled", default: false)
    @State private var lastFmScrobble = PlatformSettings.shared.getBoolean(key: "lastfm_scrobble", default: true)
    @State private var lastFmNowPlaying = PlatformSettings.shared.getBoolean(key: "lastfm_nowplaying", default: true)
    @State private var lastFmKey = PlatformSettings.shared.getString(key: "lastfm_api_key", default: "")
    @State private var lastFmSecret = PlatformSettings.shared.getString(key: "lastfm_secret", default: "")
    @State private var listenToken = PlatformSettings.shared.getString(key: "listenbrainz_token", default: "")
    @State private var listenEnabled = PlatformSettings.shared.getBoolean(key: "listenbrainz_enabled", default: false)
    @State private var discordToken = PlatformSettings.shared.getString(key: "discord_token", default: "")
    @State private var discordName = PlatformSettings.shared.getString(key: "discord_username", default: "")
    @State private var discordRpc = PlatformSettings.shared.getBoolean(key: "discord_rpc_enabled", default: true)
    @State private var discordStatus = PlatformSettings.shared.getString(key: "discord_status", default: "online")
    @State private var discordActivity = PlatformSettings.shared.getString(key: "discord_activity_type", default: "listening")
    @State private var discordNameCustom = PlatformSettings.shared.getString(key: "discord_activity_name", default: "")
    @State private var discordSwap = PlatformSettings.shared.getBoolean(key: "discord_swap_title", default: false)
    @State private var scrobbleMin = Double(PlatformSettings.shared.getInt(key: "scrobble_min_duration", default: 30))
    @State private var scrobblePercent = Double(PlatformSettings.shared.getFloat(key: "scrobble_delay_percent", default: 0.5))
    @State private var scrobbleMax = Double(PlatformSettings.shared.getInt(key: "scrobble_delay_seconds", default: 180))

    var body: some View {
        Form {
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
                    Toggle("Rich Presence", isOn: $discordRpc)
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
                }
            } header: {
                Text("Rich Presence")
            } footer: {
                Text("Show what you’re playing on your Discord profile, updating as the track does.")
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
            controller: controller
        ))
        .modifier(AccountDiscordPersist(
            discordRpc: $discordRpc,
            discordStatus: $discordStatus,
            discordActivity: $discordActivity,
            discordNameCustom: $discordNameCustom,
            discordSwap: $discordSwap,
            scrobbleMin: $scrobbleMin,
            scrobblePercent: $scrobblePercent,
            scrobbleMax: $scrobbleMax
        ))
        .onAppear {
            lastFmUser = PlatformSettings.shared.getString(key: "lastfm_username", default: "")
            lastFmSession = PlatformSettings.shared.getString(key: "lastfm_session", default: "")
            discordToken = PlatformSettings.shared.getString(key: "discord_token", default: "")
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

    var body: some View {
        List {
            Section {
                ForEach(orderedIds, id: \.self) { id in
                    if let source = LyricsSourceOption.all.first(where: { $0.id == id }) {
                        Toggle(isOn: enabledBinding(source.id)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(source.title)
                                Text(source.subtitle)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .onMove(perform: move)
            } footer: {
                Text("BitChord races the sources you leave on and keeps the best match. Drag to change race order. Word-synced lyrics win when present.")
            }
        }
        .navigationTitle("Lyrics Sources")
        #if os(iOS)
        .environment(\.editMode, .constant(.active))
        #endif
    }

    private var orderedIds: [String] {
        let current = selection.split(separator: ",").map(String.init)
        let known = LyricsSourceOption.all.map(\.id)
        return current.filter { known.contains($0) } + known.filter { !current.contains($0) }
    }

    private func move(from source: IndexSet, to dest: Int) {
        var ids = orderedIds
        ids.move(fromOffsets: source, toOffset: dest)
        let enabled = Set(selection.split(separator: ",").map(String.init))
        selection = ids.filter { enabled.contains($0) }.joined(separator: ",")
    }

    private func enabledBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { Set(selection.split(separator: ",").map(String.init)).contains(id) },
            set: { on in
                var ids = orderedIds
                var enabled = Set(selection.split(separator: ",").map(String.init))
                if on { enabled.insert(id) } else { enabled.remove(id) }
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
        case person, sources, wifi, cellular, download
        case crossfade, automix, skipSilence, spatial, equalizer, nerd, video
        case theme, reduceMotion, reduceBlur, fullBleed, canvas, lyrics, lyricsSources
        case storage, clearSongs, clearImages
        case swipe, dontRepeat, hideVolume
        case discord, listenBrainz, lastFm
        case replay, genres, export, importData
    }

    var kind: Kind

    var body: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(fill)
            .frame(width: 29, height: 29)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
    }

    private var symbol: String {
        switch kind {
        case .person: "person.fill"
        case .sources: "square.stack.3d.up.fill"
        case .wifi: "wifi"
        case .cellular: "antenna.radiowaves.left.and.right"
        case .download: "arrow.down.circle.fill"
        case .crossfade: "waveform"
        case .automix: "sparkles"
        case .skipSilence: "speaker.slash.fill"
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
        }
    }

    private var fill: Color {
        switch kind {
        case .person: .blue
        case .sources: .orange
        case .wifi: .blue
        case .cellular: .green
        case .download: Color(red: 0.20, green: 0.48, blue: 0.96)
        case .crossfade: .purple
        case .automix: Color(red: 0.93, green: 0.27, blue: 0.48)
        case .skipSilence: .gray
        case .spatial: .teal
        case .equalizer: .orange
        case .nerd: .indigo
        case .video: .purple
        case .theme: .gray
        case .reduceMotion: .orange
        case .reduceBlur: .gray
        case .fullBleed: .blue
        case .canvas: Color(red: 0.93, green: 0.27, blue: 0.48)
        case .lyrics: .blue
        case .lyricsSources: .teal
        case .storage: .gray
        case .clearSongs, .clearImages: Color(red: 0.94, green: 0.27, blue: 0.27)
        case .swipe: .blue
        case .dontRepeat: .orange
        case .hideVolume: .gray
        case .discord: Color(red: 0.35, green: 0.40, blue: 0.87)
        case .listenBrainz: Color(red: 0.20, green: 0.60, blue: 0.86)
        case .lastFm: Color(red: 0.83, green: 0.18, blue: 0.18)
        case .replay: .indigo
        case .genres: .orange
        case .export, .importData: .gray
        }
    }
}

private struct AudioQualityOption: Identifiable {
    let id: String
    let title: String
    let detail: String

    static let stream: [AudioQualityOption] = [
        .init(id: "LOW", title: "Low", detail: "64 kbps · uses the least data"),
        .init(id: "MEDIUM", title: "Medium", detail: "128 kbps · a lighter stream"),
        .init(id: "HIGH", title: "High", detail: "Best available for this connection"),
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

private struct LyricsSourceOption: Identifiable {
    let id: String
    let title: String
    let subtitle: String

    static let all: [LyricsSourceOption] = [
        .init(id: "BETTER", title: "BetterLyrics", subtitle: "Word-synced lines from community timings"),
        .init(id: "PLUS", title: "LyricsPlus", subtitle: "Enhanced LRC and Apple Music timings"),
        .init(id: "SIMP", title: "SimpMusic", subtitle: "Community lyrics with syllable timings"),
        .init(id: "LRCLIB", title: "LRCLIB", subtitle: "Open timed lyrics library"),
    ]

    static func summary(_ raw: String) -> String {
        let enabled = Set(raw.split(separator: ",").map(String.init))
        let names = all.filter { enabled.contains($0.id) }.map(\.title)
        if names.isEmpty { return "None — no lyrics will be fetched" }
        return names.joined(separator: ", ")
    }
}

private struct SettingsPlaybackPersist: ViewModifier {
    var controller: PlaybackController
    @Binding var crossfade: Int
    @Binding var spatial: Bool
    @Binding var automix: Bool
    @Binding var skipSilence: Bool
    @Binding var playbackSpeed: Double

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
            .onChange(of: automix) { _, value in AppSettings.shared.setSmartFadeEnabled(value: value) }
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
    @Binding var wifiQuality: String
    @Binding var cellQuality: String
    @Binding var downloadQuality: String
    @Binding var wifiOnlyDownloads: Bool
    @Binding var cacheLimitMB: Int

    func body(content: Content) -> some View {
        content
            .onChange(of: wifiQuality) { _, value in AppSettings.shared.setAudioQualityWifi(value: value) }
            .onChange(of: cellQuality) { _, value in AppSettings.shared.setAudioQualityCellular(value: value) }
            .onChange(of: downloadQuality) { _, value in AppSettings.shared.setDownloadQuality(value: value) }
            .onChange(of: wifiOnlyDownloads) { _, value in AppSettings.shared.setWifiOnlyDownloads(value: value) }
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
    @Binding var theme: String

    func body(content: Content) -> some View {
        content
            .onChange(of: nerdStats) { _, value in AppSettings.shared.setShowNerdStats(value: value) }
            .onChange(of: canvas) { _, value in AppSettings.shared.setAnimatedCanvas(value: value) }
            .onChange(of: canvasCellular) { _, value in AppSettings.shared.setCanvasOverCellular(value: value) }
            .onChange(of: reduceBlur) { _, value in AppSettings.shared.setReduceDynamicBlur(value: value) }
            .onChange(of: reduceAnimation) { _, value in AppSettings.shared.setReduceAnimation(value: value) }
            .onChange(of: fullBleed) { _, value in AppSettings.shared.setFullBleedArtwork(value: value) }
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
            .onChange(of: jiosaavn) { _, value in AppSettings.shared.setJiosaavnEnabled(value: value) }
            .onChange(of: stopBackground) { _, value in AppSettings.shared.setStopWhenBackgrounded(value: value) }
            .onChange(of: syllableSync) { _, value in AppSettings.shared.setPrioritizeSyllableSync(value: value) }
            .onChange(of: language) { _, value in
                PlatformSettings.shared.putString(key: "app_language", value: value)
                appModel.appLanguage = value
            }
            .onChange(of: spotifyCookie) { _, value in AppSettings.shared.setSpotifySpdc(value: value) }
            .onChange(of: replayGenres) { _, value in
                PlatformSettings.shared.putBoolean(key: "replay_genres", value: value)
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
    @Binding var scrobbleMin: Double
    @Binding var scrobblePercent: Double
    @Binding var scrobbleMax: Double

    func body(content: Content) -> some View {
        content
            .onChange(of: discordRpc) { _, value in AppSettings.shared.setDiscordRpcEnabled(value: value) }
            .onChange(of: discordStatus) { _, value in AppSettings.shared.setDiscordStatus(value: value) }
            .onChange(of: discordActivity) { _, value in AppSettings.shared.setDiscordActivityType(value: value) }
            .onChange(of: discordNameCustom) { _, value in AppSettings.shared.setDiscordActivityName(value: value) }
            .onChange(of: discordSwap) { _, value in AppSettings.shared.setDiscordSwapTitle(value: value) }
            .onChange(of: scrobbleMin) { _, value in AppSettings.shared.setScrobbleMinDuration(value: Swift.Int32(value)) }
            .onChange(of: scrobblePercent) { _, value in AppSettings.shared.setScrobbleDelayPercent(value: Float(value)) }
            .onChange(of: scrobbleMax) { _, value in AppSettings.shared.setScrobbleDelaySeconds(value: Swift.Int32(value)) }
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
