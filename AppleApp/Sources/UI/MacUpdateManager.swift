#if os(macOS)
import Observation
import Sparkle
import SwiftUI

/// Remember every update the listener acted on. Sparkle's native "Remind Me Later"
/// choice normally brings the same release back; for BitChord, any explicit choice
/// acknowledges that release until a newer appcast item is published.
@MainActor
private final class MacUpdateAcknowledgementDelegate: NSObject, SPUUpdaterDelegate {
    func updater(
        _ updater: SPUUpdater,
        userDidMake choice: SPUUserUpdateChoice,
        forUpdate updateItem: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        UpdateAcknowledgementStore.record(updateItem.displayVersionString)
    }

    func bestValidUpdate(in appcast: SUAppcast, for updater: SPUUpdater) -> SUAppcastItem? {
        // The project appcast is ordered newest first. If its newest release has
        // already been acknowledged, suppress it; a newer release at the top of a
        // later appcast will pass through to Sparkle's normal version selection.
        guard let newest = appcast.items.first,
              UpdateAcknowledgementStore.contains(newest.displayVersionString) else {
            return nil
        }
        return SUAppcastItem.empty()
    }
}

/// Sparkle owns the Mac download, signature check, replacement, and relaunch flow.
/// Its settings live with the About controls so people can choose scheduled checks
/// and whether verified updates should install in the background when BitChord quits.
@MainActor
@Observable
final class MacUpdateManager {
    static let shared = MacUpdateManager()

    private let acknowledgementDelegate: MacUpdateAcknowledgementDelegate
    let controller: SPUStandardUpdaterController

    private init() {
        let acknowledgementDelegate = MacUpdateAcknowledgementDelegate()
        self.acknowledgementDelegate = acknowledgementDelegate
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: acknowledgementDelegate,
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
