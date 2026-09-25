import SwiftUI
import BitChordShared

/// Where the app is allowed to get audio from.
///
/// The order is fixed rather than something to argue with: the addons a listener
/// added are tried first, because those are the sources chosen on purpose, and
/// YouTube Music last, since it needs no setup and has the whole catalogue
/// behind it. Nothing on this screen downloads code, and nothing on it can teach
/// the app a new way to behave after it has shipped — an addon answers questions
/// with JSON, and this app is the only thing here running anything.
///
/// This replaces a screen built on four loose settings keys (`module_index_url`,
/// `module_disabled`, `module_order`, `custom_source_url`). That could not show
/// an addon at all, could not rank anything, and had no notion of a source
/// being *reachable* — so the one piece of feedback that tells someone a URL
/// they just pasted in was any good simply did not exist. The registry holds all
/// of it now.
struct SourcesView: View {
    @Environment(ToastCenter.self) private var toast

    /// Re-read whenever the registry says it changed, which is the only thing
    /// that should be able to change it.
    @State private var configs: [ConfigDocument] = []
    /// Last known reachability, filled in as the probes come back.
    @State private var health: [String: Health] = [:]
    @State private var probing = Set<String>()
    @State private var editing: ConfigDocument?
    /// The confirm JioSaavn opens before it is opted into — see `onConfirmJioSaavn`.
    @State private var confirmingJioSaavn = false
    /// iOS only: `EditMode` does not exist on macOS, where the list is reordered
    /// by click-to-move instead.
    #if os(iOS)
    @State private var editMode: EditMode = .inactive
    #endif

    struct Health {
        var name: String
        var detail: String
    }

    var body: some View {
        List {
            Section {
                rowsView
                Button {
                    editing = .newAddon()
                } label: {
                    Label("Add an addon", systemImage: "plus.circle")
                }
            } header: {
                Text("Sources, tried in this order")
            } footer: {
                orderFooter
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.inset)
        #endif
        .navigationTitle("Sources")
        #if os(iOS)
        // The addons' priority is drag-reorderable, so edit mode is needed — but
        // an explicit Reorder control rather than a mode the user cannot leave.
        .environment(\.editMode, $editMode)
        .toolbar {
            if addonCount > 1 {
                ToolbarItem(placement: .automatic) {
                    Button(editMode == .active ? "Done" : "Reorder") {
                        withAnimation { editMode = editMode == .inactive ? .active : .inactive }
                    }
                }
            }
        }
        #endif
        .task { await reload() }
        .refreshable { await reload() }
        .sheet(item: $editing) { config in
            SourceEditorSheet(config: config) { await reload() }
        }
        .confirmationDialog(
            jioSaavnWarning,
            isPresented: $confirmingJioSaavn,
            titleVisibility: .visible
        ) {
            Button("Enable JioSaavn", role: .destructive) { setEnabled(jioSaavnId, true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("BitChord will still prefer its copy when the match is the same recording. It will not when it is not.")
        }
    }

    /// The rows, one at a time, each carrying its own health and its own switch.
    ///
    /// Broken out of `body` because the row takes eight things and the type
    /// checker gives up on the whole `List` when it is inlined with them.
    @ViewBuilder
    private var rowsView: some View {
        ForEach(Array(rows.enumerated()), id: \.element.id) { index, config in
            SourceRow(
                position: index + 1,
                config: config,
                health: health[config.id],
                probing: probing.contains(config.id),
                // The ceiling outranks the health line: a source that is not going
                // to be asked at all is not usefully described by whether its
                // server answered a probe.
                skippedByQuality: config.enabled && !ceilingPermits(config.kind),
                onMetered: isMetered,
                ceiling: ceilingLabel,
                onClick: config.needsServer ? { editing = config } : nil,
                // YouTube gets no switch at all. It needs no configuration, so a
                // switch off it would be a switch hiding itself — and
                // `SourceRegistry.setEnabled` refuses it there for the same reason.
                onToggle: toggle(for: config),
                // The grip is last in the row and deliberately outside the
                // dimming: a source switched off still has a position worth
                // setting for when it is switched back on.
                handle: config.kind == "ADDON" ? { AnyView(dragHandle(config.id)) } : nil
            )
        }
        .onMove(perform: moveAddons)
    }

    @ViewBuilder
    private var orderFooter: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("If a source does not have a track or cannot be reached, BitChord tries the next one. Sources above YouTube can replace its recording when they return a better version.")
            if cappedByQuality {
                Text("This connection is set below High quality, so streams are transcoded to fit that limit. Downloads are unaffected.")
            } else if !anyLosslessSource {
                Text("No enabled source can provide lossless audio. Add an addon to play lossless files without transcoding.")
            }
        }
        .foregroundStyle(.secondary)
    }

    /// Nil for a source that cannot be switched off, which the row renders as a
    /// label rather than a switch.
    private func toggle(for config: ConfigDocument) -> ((Bool) -> Void)? {
        if config.kind == "YOUTUBE" { return nil }
        return { on in
            // JioSaavn is opt-in because its catalogue matching can select a
            // different recording, so the switch asks first.
            if config.kind == "JIOSAAVN", on, !config.enabled {
                confirmingJioSaavn = true
            } else {
                setEnabled(config.id, on)
            }
        }
    }

    private var jioSaavnWarning: String {
        "JioSaavn matches by searching its own catalogue, which can select a different version of a song — a live take, a remix, the wrong release. YouTube's own recording is what you picked; this is not it."
    }

    // MARK: - The list

    /// The addons first, in the order the listener dragged them, then everything
    /// else ranked by kind.
    ///
    /// Split out because only the addons' order is the listener's. Everything
    /// else ranks by kind, which is fixed in `SourceKind` and not something a
    /// drag should be able to argue with — a gesture that let JioSaavn be
    /// dragged above an addon would be offering a choice the resolver does not
    /// actually honour.
    ///
    /// Still one continuously numbered list. The numbers say what order the
    /// sources are tried in, and restarting the count under a second heading
    /// would break the one thing this screen is for.
    private var rows: [ConfigDocument] {
        let addons = configs.filter { $0.kind == "ADDON" }
        let fixed = configs.filter { $0.kind != "ADDON" }
            .sorted { lhs, rhs in
                SourceResolverBridge.shared.rankOf(kind: lhs.kind)
                    < SourceResolverBridge.shared.rankOf(kind: rhs.kind)
            }
        return addons + fixed
    }

    private var addonCount: Int { configs.filter { $0.kind == "ADDON" }.count }

    private var jioSaavnId: String? { configs.first { $0.kind == "JIOSAAVN" }?.id }

    // MARK: - The ceiling in force right now

    /// The only ceiling this screen can speak for. The rows below are switches the
    /// listener set once, and whether a source is *reached* also depends on which
    /// connection is up — so it is asked live rather than read from a switch.
    ///
    /// Both questions are asked of the shared module rather than assembled from
    /// the two per-network settings here, because that derivation is where a
    /// mobile-data choice ends up following someone onto Wi-Fi.
    private var ceilingName: String { SourceResolverBridge.shared.activeCeiling() }

    private var ceilingLabel: String { AudioQuality(name: ceilingName).label }

    private var cappedByQuality: Bool { ceilingName != "LOSSLESS" }

    private func ceilingPermits(_ kind: String) -> Bool {
        SourceResolverBridge.shared.activeCeilingPermits(kind: kind)
    }

    /// Asked of the kinds rather than of one source, so a source added later
    /// answers this on its own terms instead of being invisible to it.
    private var anyLosslessSource: Bool {
        configs.contains { $0.enabled && $0.isComplete && $0.canServeLossless }
    }

    // MARK: - Loading and probing

    private func reload() async {
        let listed = await withCheckedContinuation {
            (continuation: CheckedContinuation<[ConfigDocument], Never>) in
            SourceResolverBridge.shared.configs(
                callback: ListingReader { json in
                    guard let json, let data = json.data(using: .utf8),
                          let listing = try? JSONDecoder().decode(Listing.self, from: data)
                    else { continuation.resume(returning: []); return }
                    continuation.resume(returning: listing.sources)
                }
            )
        }
        configs = listed
        await probeAll()
    }

    /// Probe everything with a server to reach, one at a time.
    ///
    /// Sequentially rather than all at once, because these are third-party
    /// servers and a burst of simultaneous requests is what gets a listener's
    /// address noticed. The probes are cheap when they succeed and slow when they
    /// do not, and a screen that shows a spinner per row beats one that shows
    /// every server at once.
    private func probeAll() async {
        for config in configs where config.needsServer && config.isComplete {
            if Task.isCancelled { return }
            probing.insert(config.id)
            let answer = await probe(config.id)
            health[config.id] = answer
            probing.remove(config.id)
        }
    }

    private func probe(_ id: String) async -> Health {
        await withCheckedContinuation { continuation in
            SourceResolverBridge.shared.health(
                configId: id,
                callback: HealthProbe { _, name, detail in
                    continuation.resume(returning: Health(name: name, detail: detail))
                }
            )
        }
    }

    private func setEnabled(_ id: String?, _ enabled: Bool) {
        guard let id else { return }
        SourceResolverBridge.shared.setEnabled(
            configId: id, enabled: enabled,
            callback: NoReply { _, _ in }
        )
        Task { await reload() }
    }

    // MARK: - Reordering

    #if os(iOS)
    private func moveAddons(from source: IndexSet, to dest: Int) {
        // Only the addons' relative order is the listener's to set, and the
        // registry stores exactly that — so the gesture is applied to the addon
        // subsequence and the fixed ranks behind it are left alone.
        var ordered = rows
        ordered.move(fromOffsets: source, toOffset: dest)
        let ids = ordered.filter { $0.kind == "ADDON" }.map(\.id)
        SourceResolverBridge.shared.reorderAddons(
            orderedIds: ids, callback: NoReply { _, _ in }
        )
    }

    /// macOS has no `EditMode` and no drag-to-reorder in a `List`, so the handle
    /// moves the row up or down instead. The same outcome, reached the way the
    /// platform allows.
    private func dragHandle(_ id: String) -> some View {
        #if os(macOS)
        return AnyView(
            Menu {
                Button("Move Up") { nudge(id, by: -1) }
                Button("Move Down") { nudge(id, by: 1) }
            } label: {
                Image(systemName: "line.3.horizontal")
                    .foregroundStyle(.secondary)
                    .help("Change this addon's position")
            }
        )
        #else
        return AnyView(EmptyView())
        #endif
    }

    private func nudge(_ id: String, by offset: Int) {
        var ordered = rows
        guard let from = ordered.firstIndex(where: { $0.id == id }) else { return }
        let to = from + offset
        guard to >= 0, to < ordered.count else { return }
        ordered.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        let ids = ordered.filter { $0.kind == "ADDON" }.map(\.id)
        SourceResolverBridge.shared.reorderAddons(
            orderedIds: ids, callback: NoReply { _, _ in }
        )
        Task { await reload() }
    }
    #else
    private func moveAddons(from source: IndexSet, to dest: Int) {}
    private func dragHandle(_ id: String) -> some View { EmptyView() }
    private func nudge(_ id: String, by offset: Int) {}
    #endif

    // MARK: - Wire types

    private struct Listing: Codable {
        let sources: [ConfigDocument]
    }
}

/// One configured source, as the shared registry describes it.
struct ConfigDocument: Codable, Identifiable, Hashable {
    let id: String
    let kind: String
    let label: String
    let displayName: String
    let baseUrl: String
    var enabled: Bool
    let isComplete: Bool
    let needsServer: Bool
    let canServeLossless: Bool
    let labels: [String]

    /// A blank addon, for the "Add" row.
    static func newAddon() -> ConfigDocument {
        ConfigDocument(
            id: "", kind: "ADDON", label: "", displayName: "Addon",
            baseUrl: "", enabled: true, isComplete: false,
            needsServer: true, canServeLossless: true, labels: []
        )
    }
}

// MARK: - The row

/// One source: where it sits, what it is, whether it answers, and whether it is
/// wanted.
private struct SourceRow: View {
    let position: Int
    let config: ConfigDocument
    let health: SourcesView.Health?
    let probing: Bool
    let skippedByQuality: Bool
    let onMetered: Bool
    let ceiling: String
    let onClick: (() -> Void)?
    /// Nil for a source that cannot be switched off, which gets a label instead.
    let onToggle: ((Bool) -> Void)?
    let handle: (() -> AnyView)?

    var body: some View {
        // Dimmed for the same reason an off source is: it is not in the walk. The
        // switch stays where the listener left it, so the row reads "on, but not
        // today" rather than "off".
        let dimmed = !config.enabled || skippedByQuality

        HStack(spacing: 10) {
            Text("\(position)")
                .font(.body)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 20, alignment: .trailing)
                .opacity(dimmed ? 0.4 : 1)

            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.primary)
                .frame(width: 26)
                .opacity(dimmed ? 0.4 : 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(config.displayName)
                    .font(.body)
                    .lineLimit(1)
                statusLine
                    .font(.subheadline)
                    .foregroundStyle(lineColour)
                    .lineLimit(2)
            }
            .opacity(dimmed ? 0.4 : 1)

            Spacer(minLength: 8)

            if let onToggle {
                Toggle("", isOn: Binding(get: { config.enabled }, set: onToggle))
                    .labelsHidden()
            } else {
                Text("Always on")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if let handle { handle() }
        }
        .padding(.vertical, 5)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .onTapGesture { onClick?() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var icon: String {
        switch config.kind {
        case "ADDON", "MODULE", "CUSTOM_MODULE": return "puzzlepiece.extension"
        case "JIOSAAVN": return "waveform"
        default: return "play.circle"
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        if !config.isComplete {
            Text("Tap to finish setting up")
        } else if config.kind == "JIOSAAVN" {
            Text("May match the wrong version of a song. Enable at your own risk.")
        } else if skippedByQuality {
            Text("Not used on \(onMetered ? "mobile data" : "Wi-Fi") · quality is set to \(ceiling)")
        } else if probing {
            Text("Checking…").foregroundStyle(.secondary)
        } else if let health {
            switch health.name {
            case "ok":
                Text([health.detail, config.labels.prefix(3).joined(separator: " · ")]
                    .filter { !$0.isEmpty }
                    .joined(separator: " · "))
            case "rejected":
                Text(health.detail)
            default:
                Text("Can’t reach it right now · \(health.detail)")
            }
        } else if config.needsServer {
            Text("Checking…").foregroundStyle(.secondary)
        } else {
            Text(config.labels.prefix(3).joined(separator: " · "))
        }
    }

    /// Only a rejection is coloured, and only when it is what the line actually
    /// says. A server that is merely down will be up again without anyone doing
    /// anything, and painting that red trains people to ignore the colour by the
    /// time it means something.
    private var lineColour: Color {
        guard !skippedByQuality, !probing, config.isComplete,
              config.kind != "JIOSAAVN", health?.name == "rejected"
        else { return .secondary }
        return .red
    }

    private var accessibilityLabel: String {
        var parts = ["Position \(position)", config.displayName]
        parts.append(config.enabled ? "On" : "Off")
        if skippedByQuality { parts.append("Not used on this connection") }
        if let health, health.name == "rejected" { parts.append(health.detail) }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Helpers

/// The shared `AudioQuality`, wrapped so the screen can read the ceiling without
/// hard-coding its cases.
struct AudioQuality {
    var name: String

    var label: String {
        switch name {
        case "LOW": return "Low"
        case "MEDIUM": return "Medium"
        case "HIGH": return "High"
        default: return "Lossless"
        }
    }
}


// MARK: - Bridge callbacks

private final class ListingReader: SourceResolverBridgeConfigsCallback {
    private let handler: (String?) -> Void
    init(_ handler: @escaping (String?) -> Void) { self.handler = handler }
    func onResult(json: String?) { handler(json) }
}

private final class HealthProbe: SourceResolverBridgeHealthCallback {
    private let handler: (String, String, String) -> Void
    init(_ handler: @escaping (String, String, String) -> Void) { self.handler = handler }
    func onResult(configId: String, health: String, detail: String) {
        handler(configId, health, detail)
    }
}

private final class NoReply: SourceResolverBridgeActionCallback {
    private let handler: (Bool, String?) -> Void
    init(_ handler: @escaping (Bool, String?) -> Void) { self.handler = handler }
    func onResult(ok: Bool, message: String?) { handler(ok, message) }
}

/// The shared kind's place in the walk, by name.
///
/// Asked of the enum rather than mirrored in a host-side table, so a kind added
/// to the registry sorts correctly here without a second list to keep in step.
/// Whether the connection up right now is the metered one.
///
/// Read alongside the ceiling because the row's "not used on …" line has to name
/// *which* connection, and a ceiling on its own cannot say that.
private var isMetered: Bool {
    SourceResolverBridge.shared.activeConnectionIsMetered()
}
