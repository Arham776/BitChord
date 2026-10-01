import Foundation
import AVFoundation

@main struct VerifyRouting {
    static func main() async throws {
        let observer = MacAudioRoutes(changed: {}, disconnected: {})
        let route = MacAudioRoutes.current()
        guard route.device != 0 else { fatalError("No system audio route") }
        print("PASS CoreAudio route observation; output=\(route.name) transport=\(route.kind)")
        withExtendedLifetime(observer) {}
        let changed = await HeadphoneRouting.shared.acquire(allowSwitching: true)
        print("macOS routing arbitration completed; changedDevice=\(changed)")
        _ = await HeadphoneRouting.shared.acquire(allowSwitching: true)
        await HeadphoneRouting.shared.release()
        let explicit = await HeadphoneRouting.shared.acquire(allowSwitching: false)
        guard !explicit else { fatalError("Explicit output choice was arbitrated") }
        print("PASS repeated participation and explicit-device opt-out")
    }
}
