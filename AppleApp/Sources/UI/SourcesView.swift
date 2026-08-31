import SwiftUI
import BitChordShared

struct SourcesView: View {
    @State private var indexUrl = PlatformSettings.shared.getString(key: "module_index_url", default: "")
    @State private var customUrl = PlatformSettings.shared.getString(key: "custom_source_url", default: "")
    @State private var health = "Not checked"
    @State private var modules: [ModuleRow] = []
    @State private var busy = false

    struct ModuleRow: Identifiable {
        let id: String
        let name: String
        let author: String
        let lossless: Bool
        let download: String
    }

    var body: some View {
        Form {
            Section {
                TextField("https://…", text: $customUrl)
                    .textContentType(.URL)
                Button("Test Custom Source") { testCustom() }
            } header: {
                Text("Custom HTTP Source")
            } footer: {
                Text("GET /health and GET /stream?title=&artist=&quality=LOSSLESS")
            }
            Section {
                TextField("Index URL", text: $indexUrl)
                    .textContentType(.URL)
                Button("Fetch Index") { fetchIndex() }
                LabeledContent("Health", value: health)
            } header: {
                Text("Module Index")
            }
            if !modules.isEmpty {
                Section("Modules") {
                    ForEach(modules) { row in
                        Toggle(isOn: enabledBinding(row.id)) {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(row.name)
                                    if row.lossless {
                                        Text("Hi-Res")
                                            .font(.caption2.weight(.semibold))
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(.green.opacity(0.22), in: Capsule())
                                    }
                                }
                                if !row.author.isEmpty {
                                    Text(row.author).font(.subheadline).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .onMove(perform: moveModules)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Sources")
        #if os(iOS)
        .environment(\.editMode, .constant(.active))
        #endif
        .overlay { if busy { ProgressView() } }
        .onChange(of: indexUrl) { _, value in AppSettings.shared.setModuleIndexUrl(value: value) }
        .onChange(of: customUrl) { _, value in AppSettings.shared.setCustomSourceUrl(value: value) }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 420)
        #endif
    }

    private func testCustom() {
        AppSettings.shared.setCustomSourceUrl(value: customUrl)
        busy = true
        SourceBridge.shared.health(url: customUrl, callback: HealthAdapter { ok, detail in
            Task { @MainActor in
                busy = false
                health = ok ? "Ok — \(detail)" : "Failed — \(detail)"
            }
        })
    }

    private func fetchIndex() {
        AppSettings.shared.setModuleIndexUrl(value: indexUrl)
        busy = true
        SourceBridge.shared.fetchIndex(url: indexUrl, callback: IndexAdapter { json, message in
            Task { @MainActor in
                busy = false
                if let message { health = message; return }
                health = "Index reachable"
                guard let json, let data = json.data(using: .utf8),
                      let listing = try? JSONDecoder().decode(Listing.self, from: data) else { return }
                modules = listing.modules.map {
                    ModuleRow(id: $0.id, name: $0.name, author: $0.author, lossless: $0.lossless, download: $0.download)
                }
                applyStoredOrder()
            }
        })
    }

    private func applyStoredOrder() {
        let order = PlatformSettings.shared.getString(key: "module_order", default: "")
            .split(separator: ",").map(String.init)
        guard !order.isEmpty else { return }
        modules.sort { a, b in
            let ai = order.firstIndex(of: a.id) ?? Int.max
            let bi = order.firstIndex(of: b.id) ?? Int.max
            return ai < bi
        }
    }

    private func enabledBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: {
                !Set(PlatformSettings.shared.getString(key: "module_disabled", default: "")
                    .split(separator: ",").map(String.init)).contains(id)
            },
            set: { on in
                var disabled = Set(PlatformSettings.shared.getString(key: "module_disabled", default: "")
                    .split(separator: ",").map(String.init))
                if on { disabled.remove(id) } else { disabled.insert(id) }
                PlatformSettings.shared.putString(key: "module_disabled", value: disabled.joined(separator: ","))
            }
        )
    }

    private func moveModules(from source: IndexSet, to dest: Int) {
        modules.move(fromOffsets: source, toOffset: dest)
        PlatformSettings.shared.putString(key: "module_order", value: modules.map(\.id).joined(separator: ","))
    }

    private struct Listing: Codable {
        struct Card: Codable {
            let id: String
            let name: String
            let author: String
            let version: String
            let download: String
            let lossless: Bool
        }
        let modules: [Card]
    }
}

private final class HealthAdapter: SourceBridgeHealthCallback {
    let handler: (Bool, String) -> Void
    init(_ handler: @escaping (Bool, String) -> Void) { self.handler = handler }
    func onResult(ok: Bool, detail: String) { handler(ok, detail) }
}

private final class IndexAdapter: SourceBridgeIndexCallback {
    let handler: (String?, String?) -> Void
    init(_ handler: @escaping (String?, String?) -> Void) { self.handler = handler }
    func onResult(json: String?, message: String?) { handler(json, message) }
}
