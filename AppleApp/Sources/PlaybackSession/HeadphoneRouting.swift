import AVFoundation

/// macOS does not have AVAudioSession. Arbitration gives the system the same
/// start/stop context iOS supplies automatically, without selecting a device.
actor HeadphoneRouting {
    static let shared = HeadphoneRouting()
    private var active = false
    private var generation: UInt64 = 0
    private struct Result: Sendable { let changed: Bool; let succeeded: Bool }
    private var pending: Task<Result, Never>?
    private var releaseTask: Task<Void, Never>?

    func acquire(allowSwitching: Bool, restart: Bool = false) async -> Bool {
        #if os(macOS)
        releaseTask?.cancel(); releaseTask = nil
        guard allowSwitching else { release(); return false }
        if active && !restart { return false }
        let expected = generation
        let task: Task<Result, Never>
        if let pending { task = pending }
        else {
            task = Task {
                await withCheckedContinuation { continuation in
                    AVAudioRoutingArbiter.shared.begin(category: .playback) { changed, error in
                        if error != nil { PlaybackDebugLog.shared.record("AirPods routing arbitration unavailable; using current output") }
                        continuation.resume(returning: Result(changed: changed, succeeded: error == nil))
                    }
                }
            }
            pending = task
        }
        let result = await task.value
        guard expected == generation else { return false }
        pending = nil; active = result.succeeded
        return result.changed
        #else
        return false
        #endif
    }

    func releaseWhenIdle() {
        releaseTask?.cancel()
        releaseTask = Task {
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            release()
        }
    }

    func release() {
        generation &+= 1
        pending = nil; active = false
        releaseTask?.cancel(); releaseTask = nil
        #if os(macOS)
        AVAudioRoutingArbiter.shared.leave()
        #endif
    }
}
