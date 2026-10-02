import Foundation
import Network
import Observation
import BitChordShared

/// Wi-Fi vs cellular (metered) for per-network quality ceilings.
@MainActor
@Observable
final class NetworkQuality {
    static let shared = NetworkQuality()
    private(set) var metered = false
    private(set) var connected = true
    @ObservationIgnored private let monitor = NWPathMonitor()

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let expensive = path.isExpensive || path.isConstrained
            Task { @MainActor in
                self?.metered = expensive; self?.connected = path.status == .satisfied
                AppSettings.shared.setMeteredConnection(value: KotlinBoolean(bool: expensive))
                DownloadStore.shared.networkPolicyChanged()
            }
        }
        monitor.start(queue: DispatchQueue.global(qos: .utility))
    }

    var maxKbps: Swift.Int32 {
        AppSettings.shared.effectiveAudioQuality(metered: metered).maxKbps
    }

    var canvasAllowed: Bool {
        let enabled = PlatformSettings.shared.getBoolean(key: "animated_canvas", default: true)
        if !enabled { return false }
        if metered {
            return PlatformSettings.shared.getBoolean(key: "canvas_over_cellular", default: false)
        }
        return true
    }
}
