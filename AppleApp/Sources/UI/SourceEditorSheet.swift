import SwiftUI
import BitChordShared

/// Add or edit a source that has an address.
///
/// Test is offered rather than required: a server that happens to be asleep is
/// still worth saving, and refusing to store it until it answers would make
/// setting one up from a coffee shop impossible. What Test does buy is the
/// difference between "not answering" and "answering, but not with something
/// this app can use" — a manifest missing its `stream` resource is a mistake
/// worth hearing about before the first track rather than after it.
struct SourceEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ToastCenter.self) private var toast

    /// The config being edited, or a blank one for a new source.
    let config: ConfigDocument

    var onSaved: () async -> Void

    @State private var url = ""
    @State private var name = ""
    @State private var testing = false
    @State private var result: TestOutcome?
    @State private var saving = false

    struct TestOutcome {
        var name: String
        var detail: String
    }

    private var isNew: Bool { config.id.isEmpty }

    /// The kind's name, passed to the registry as a string.
    ///
    /// Deliberately not the shared enum: a name crosses the bridge without the
    /// host needing a case for it, so a kind added to the registry becomes
    /// editable here without a second list kept in step on this side.
    private var kindName: String { config.kind }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://…", text: $url)
                        .textContentType(.URL)
                        #if os(iOS)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        #endif
                    TextField("Name (optional)", text: $name)
                } header: {
                    Text("Address")
                } footer: {
                    Text(urlHelp)
                }

                Section {
                    Button {
                        test()
                    } label: {
                        HStack {
                            Text("Test")
                            Spacer()
                            if testing { ProgressView().controlSize(.small) }
                        }
                    }
                    .disabled(testing || normalised.isEmpty)

                    if let result, !testing {
                        Label {
                            Text(result.detail)
                        } icon: {
                            Image(systemName: icon(for: result.name))
                                .foregroundStyle(colour(for: result.name))
                        }
                        .font(.subheadline)
                    }

                    Button(isNew ? "Add" : "Save") { save() }
                        .disabled(normalised.isEmpty || saving)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(isNew ? "Add an addon" : "Edit source")
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
        .frame(minWidth: 460, minHeight: 380)
        #endif
        .onAppear {
            url = config.baseUrl
            name = config.label
        }
    }

    /// The URL as it will be stored.
    ///
    /// Trailing slashes go: two sources that differ only by one are two rows that
    /// look like one, and the duplicate check that stops a source being added
    /// twice would not see them as the same.
    private var normalised: String {
        url.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// What the kind actually needs, said before the field rather than after a
    /// failure.
    private var urlHelp: String {
        switch config.kind {
        case "MODULE":
            return "The module index — the JSON document listing plugins. Each plugin ships a JavaScript file that BitChord runs to search and stream."
        case "CUSTOM_MODULE":
            return "A module index configured by an earlier build. Still works, but new sources should be addons."
        default:
            return "Paste the addon's URL — either its root or its manifest.json. BitChord reads what it can search and stream, then asks it for tracks over plain HTTP."
        }
    }

    private func icon(for name: String) -> String {
        switch name {
        case "ok": return "checkmark.circle.fill"
        case "rejected": return "exclamationmark.triangle.fill"
        default: return "wifi.slash"
        }
    }

    private func colour(for name: String) -> Color {
        // Only a rejection is coloured. A server that is merely down will be up
        // again without anyone doing anything, and painting that red trains
        // people to ignore the colour by the time it means something.
        name == "rejected" ? .red : .secondary
    }

    // MARK: - Actions

    /// Test the address *as typed*, without saving it.
    ///
    /// A source that has never been stored has no id, and the probe takes a
    /// config rather than an id precisely so this is possible — otherwise the
    /// only way to find out whether a pasted URL is any good would be to save it
    /// and then remove it again.
    private func test() {
        guard !normalised.isEmpty else { return }
        testing = true
        result = nil
        SourceResolverBridge.shared.probeCandidate(
            kind: kindName, baseUrl: normalised, label: name,
            callback: Verdict { ok, message in
                Task { @MainActor in
                    testing = false
                    let detail = message ?? ""
                    result = TestOutcome(
                        name: ok ? "ok" : "rejected",
                        // An empty detail is not a pass: the sheet has to say
                        // something when the server answered with nothing usable,
                        // or a blank line reads as a result.
                        detail: detail.isEmpty
                            ? (ok
                                ? "Reachable"
                                : "The server answered, but not with something BitChord can use")
                            : detail,
                    )
                }
            }
        )
    }

    private func save() {
        guard !normalised.isEmpty else { return }
        // Refuse a second copy of a source already configured. Same address,
        // different trailing slash, or written as its manifest rather than its
        // root — all the same source, and all of them would otherwise end up as
        // two rows in a list where the order is the whole point.
        if SourceResolverBridge.shared.isDuplicate(
            url: normalised, exceptId: config.id.nilIfEmpty
        ) {
            toast.show("That address is already configured", kind: .failure)
            return
        }
        saving = true
        SourceResolverBridge.shared.save(
            id: config.id.nilIfEmpty ?? UUID().uuidString,
            kind: kindName,
            label: name,
            baseUrl: normalised,
            enabled: config.enabled,
            callback: Saved { ok, message in
                Task { @MainActor in
                    saving = false
                    guard ok else {
                        toast.show(message ?? "Could not save this source", kind: .failure)
                        return
                    }
                    await onSaved()
                    dismiss()
                }
            }
        )
    }
}

extension String {
    /// Nil rather than an empty string, for a bridge parameter that means
    /// "except nothing".
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

// MARK: - Bridge callbacks

/// The shared bridges take protocols rather than closures, so each gets a small
/// adapter. Named for what it carries rather than for the bridge it serves, so
/// the file reads as one per question.
private final class Verdict: SourceResolverBridgeActionCallback {
    private let handler: (Bool, String?) -> Void
    init(_ handler: @escaping (Bool, String?) -> Void) { self.handler = handler }
    func onResult(ok: Bool, message: String?) { handler(ok, message) }
}

private final class Saved: SourceResolverBridgeActionCallback {
    private let handler: (Bool, String?) -> Void
    init(_ handler: @escaping (Bool, String?) -> Void) { self.handler = handler }
    func onResult(ok: Bool, message: String?) { handler(ok, message) }
}
