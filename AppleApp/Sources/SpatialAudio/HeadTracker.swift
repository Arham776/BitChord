import Foundation
#if os(iOS)
import CoreMotion
#endif

/// iOS headphone head-tracking (spec §3.3). Feeds yaw into `native-core` so
/// the widened image stays anchored to the device. Unavailable hardware,
/// denied motion permission, disconnected AirPods, and **macOS** (no
/// `CMHeadphoneMotionManager`) all fall back to yaw 0 — upstream's fixed
/// widening. Does not opt the session into platform Spatial Audio.
@MainActor
final class HeadTracker: NSObject {
    private var engine: PlayerEngine?
    private var running = false
    private var motionGeneration: UInt64 = 0
    private var referenceYaw: Double?

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
        let permission = CMHeadphoneMotionManager.authorizationStatus()
        guard permission != .denied && permission != .restricted else { resetYaw(); return }
        // Register before checking availability so disconnected headphones can
        // connect later without the user toggling the effect off and on.
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
        motionGeneration &+= 1
        manager.delegate = nil
        manager.stopDeviceMotionUpdates()
#endif
        resetYaw()
    }

    private func resetYaw() {
        referenceYaw = nil
        try? engine?.setHeadRotation(yaw: 0)
    }

#if os(iOS)
    private func startUpdatesIfConnected() {
        guard running, manager.isDeviceMotionAvailable else { return }
        motionGeneration &+= 1
        let generation = motionGeneration
        manager.startDeviceMotionUpdates(to: queue) { [weak self] motion, error in
            let rawYaw = motion?.attitude.yaw
            let failed = error != nil
            Task { @MainActor in
                guard let self, self.running, self.motionGeneration == generation else { return }
                guard !failed, let rawYaw else { self.resetYaw(); return }
                if self.referenceYaw == nil { self.referenceYaw = rawYaw }
                let relative = atan2(sin(rawYaw - (self.referenceYaw ?? rawYaw)), cos(rawYaw - (self.referenceYaw ?? rawYaw)))
                let yaw = min(max(Float(relative) / (Float.pi / 2), -1), 1)
                try? self.engine?.setHeadRotation(yaw: yaw)
            }
        }
    }
#endif
}

#if os(iOS)
extension HeadTracker: CMHeadphoneMotionManagerDelegate {
    nonisolated func headphoneMotionManagerDidConnect(_ manager: CMHeadphoneMotionManager) {
        Task { @MainActor in self.resetYaw(); self.startUpdatesIfConnected() }
    }

    nonisolated func headphoneMotionManagerDidDisconnect(_ manager: CMHeadphoneMotionManager) {
        Task { @MainActor in self.motionGeneration &+= 1; self.manager.stopDeviceMotionUpdates(); self.resetYaw() }
    }
}
#endif
