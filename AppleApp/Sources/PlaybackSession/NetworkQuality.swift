import Foundation
import Network
import BitChordShared

/// Wi-Fi vs cellular (metered) for per-network quality ceilings.
@MainActor
final class NetworkQuality {
    static let shared = NetworkQuality()
    private(set) var metered = false
    private let monitor = NWPathMonitor()

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let expensive = path.isExpensive || path.isConstrained
            Task { @MainActor in self?.metered = expensive }
        }
        monitor.start(queue: DispatchQueue.global(qos: .utility))
    }

    var maxKbps: Swift.Int32 {
        let key = metered ? "audio_quality_cellular" : "audio_quality_wifi"
        switch PlatformSettings.shared.getString(key: key, default: "HIGH") {
        case "LOW": return 64
        case "MEDIUM": return 128
        default: return Swift.Int32.max
        }
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
