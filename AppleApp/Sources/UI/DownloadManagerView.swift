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
                                        .foregroundStyle(job.status == .failed ? .red : .secondary)
                                    if let message = job.message, job.status == .failed {
                                        Text(message).font(.caption2).foregroundStyle(.red)
                                    }
                                }
                                Spacer()
                                switch job.status {
                                case .queued, .running:
                                    Button("Cancel") { store.cancel(job.id) }
                                case .failed:
                                    Button("Retry") { store.retry(job.id) }
                                case .done:
                                    EmptyView()
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
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    if store.activeCount > 0 {
                        Button("Cancel All") {
                            for job in store.jobs where job.status == .queued || job.status == .running {
                                store.cancel(job.id)
                            }
                        }
                    } else if store.jobs.contains(where: { $0.status == .done || $0.status == .failed }) || !store.items.isEmpty {
                        Menu("Clear") {
                            if store.jobs.contains(where: { $0.status == .done || $0.status == .failed }) {
                                Button("Clear finished & failed") {
                                    store.jobs.removeAll { $0.status == .done || $0.status == .failed }
                                }
                            }
                            if !store.items.isEmpty {
                                Button("Clear downloads on this device", role: .destructive) {
                                    store.clearDownloads()
                                }
                            }
                        }
                    }
                }
            }
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
