import Foundation
#if os(iOS)
import CoreMotion
#endif

/// iOS headphone head-tracking (spec §3.3). Feeds yaw into `native-core` so
/// the widened image stays anchored to the device. Unavailable hardware,
/// denied motion permission, disconnected AirPods, and **macOS** (no
/// `CMHeadphoneMotionManager`) all fall back to yaw 0 — upstream's fixed
/// widening. Does not opt the session into platform Spatial Audio.
final class HeadTracker: NSObject {
    private var engine: PlayerEngine?
    private var running = false

#if os(iOS)
    private let manager = CMHeadphoneMotionManager()
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "bitchord.head-tracker"
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .userInteractive
        return q
    }()
#endif

    func start(engine: PlayerEngine) {
        self.engine = engine
#if os(iOS)
        guard !running else { return }
        guard manager.isDeviceMotionAvailable else { return }
        if CMHeadphoneMotionManager.authorizationStatus() == .denied { return }
        running = true
        manager.delegate = self
        startUpdatesIfConnected()
#endif
    }

    func stop() {
#if os(iOS)
        guard running else {
            resetYaw()
            return
        }
        running = false
        manager.delegate = nil
        manager.stopDeviceMotionUpdates()
#endif
        resetYaw()
    }

    private func resetYaw() {
        try? engine?.setHeadRotation(yaw: 0)
    }

#if os(iOS)
    private func startUpdatesIfConnected() {
        guard running, manager.isDeviceMotionAvailable else { return }
        manager.startDeviceMotionUpdates(to: queue) { [weak self] motion, error in
            guard let self, error == nil, let motion else { return }
            // ±π/2 rad (±90°) maps onto the DSP's −1..1 range; beyond that
            // saturates — turning past profile shouldn't swap the image.
            let halfPi = Float.pi / 2
            let yaw = min(max(Float(motion.attitude.yaw) / halfPi, -1), 1)
            try? self.engine?.setHeadRotation(yaw: yaw)
        }
    }
#endif
}

#if os(iOS)
extension HeadTracker: CMHeadphoneMotionManagerDelegate {
    func headphoneMotionManagerDidConnect(_ manager: CMHeadphoneMotionManager) {
        startUpdatesIfConnected()
    }

    func headphoneMotionManagerDidDisconnect(_ manager: CMHeadphoneMotionManager) {
        manager.stopDeviceMotionUpdates()
        resetYaw()
    }
}
#endif
