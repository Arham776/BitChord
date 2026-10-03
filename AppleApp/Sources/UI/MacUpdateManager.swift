#if os(macOS)
import Observation
import Sparkle
import SwiftUI

/// Sparkle owns the Mac download, signature check, replacement, and relaunch flow.
/// Its settings live with the About controls so people can choose scheduled checks
/// and whether verified updates should install in the background when BitChord quits.
@MainActor
@Observable
final class MacUpdateManager {
    static let shared = MacUpdateManager()

    let controller: SPUStandardUpdaterController

    private init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    var updater: SPUUpdater { controller.updater }

    func checkNow() {
        controller.checkForUpdates(nil)
    }
}

struct MacUpdateSettings: View {
    @State private var manager = MacUpdateManager.shared
    @State private var checksAutomatically = true
    @State private var installsAutomatically = false

    var body: some View {
        Group {
            Button("Check for Updates") {
                manager.checkNow()
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Toggle("Check for updates automatically", isOn: $checksAutomatically)
            .onChange(of: checksAutomatically) { _, value in
                manager.updater.automaticallyChecksForUpdates = value
            }

            Toggle("Download and install updates automatically", isOn: $installsAutomatically)
            .onChange(of: installsAutomatically) { _, value in
                manager.updater.automaticallyDownloadsUpdates = value
            }
        }
        .task {
            checksAutomatically = manager.updater.automaticallyChecksForUpdates
            installsAutomatically = manager.updater.automaticallyDownloadsUpdates
        }
    }
}
#endif
