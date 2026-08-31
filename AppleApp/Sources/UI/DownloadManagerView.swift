import SwiftUI

struct DownloadManagerView: View {
    private var store: DownloadStore { DownloadStore.shared }

    var body: some View {
        NavigationStack {
            List {
                if store.jobs.isEmpty && store.items.isEmpty {
                    Text("No downloads yet. Save a track from Now Playing or a collection menu.")
                        .foregroundStyle(.secondary)
                }
                if !store.jobs.isEmpty {
                    Section("In progress") {
                        ForEach(store.jobs) { job in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(job.title)
                                    Text(label(job.status))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if job.status == .failed {
                                    Button("Retry") { store.retry(job.id) }
                                }
                            }
                        }
                    }
                }
                if !store.items.isEmpty {
                    Section("On this device") {
                        ForEach(store.items) { item in
                            VStack(alignment: .leading) {
                                Text(item.title)
                                Text(item.artist).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Downloads")
            .onAppear { store.refresh() }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 480)
        #endif
    }

    private func label(_ status: DownloadStore.Job.Status) -> String {
        switch status {
        case .queued: "Queued"
        case .running: "Downloading"
        case .done: "Done"
        case .failed: "Failed"
        }
    }
}
