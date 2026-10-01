import Foundation

actor LaunchReadiness {
    static let shared = LaunchReadiness()
    private let started = ContinuousClock.now
    private var ready = false
    private var recordedContent = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var fallbackStarted = false

    func contentAppeared() {
        guard !recordedContent else { return }
        recordedContent = true; ready = true
        PlaybackDebugLog.shared.record("launch to first content: \(started.duration(to: .now))")
        waiting.forEach { $0.resume() }; waiting.removeAll()
    }
    func waitForContent() async {
        if ready { return }
        if !fallbackStarted {
            fallbackStarted = true
            Task {
                try? await Task.sleep(for: .seconds(2))
                // Slow/offline feeds must not starve local downloads or startup.
                finishFallback()
            }
        }
        await withCheckedContinuation { waiting.append($0) }
    }
    private func finishFallback() {
        guard !ready else { return }
        ready = true
        waiting.forEach { $0.resume() }; waiting.removeAll()
    }
}
