import Foundation

/// Measures delayed main-queue work while the app is active. One outstanding
/// sample prevents a stalled thread from accumulating diagnostic callbacks.
final class LoadingMonitor: @unchecked Sendable {
    static let shared = LoadingMonitor()
    private let lock = NSLock()
    private var active = true
    private var outstanding = false
    private let timer: DispatchSourceTimer
    private init() {
        timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "app.bitchord.BitChord.loading-monitor", qos: .utility))
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.sample() }
        timer.resume()
    }
    func setActive(_ value: Bool) { lock.lock(); active = value; lock.unlock() }
    private func sample() {
        lock.lock()
        guard active, !outstanding else { lock.unlock(); return }
        outstanding = true; lock.unlock()
        let start = DispatchTime.now().uptimeNanoseconds
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let milliseconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            self.lock.lock(); self.outstanding = false; let active = self.active; self.lock.unlock()
            if active, milliseconds > 100 {
                PlaybackDebugLog.shared.record("main thread queue delay: \(Int(milliseconds)) ms")
            }
        }
    }
}
