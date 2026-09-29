import Foundation

// Deterministic scheduling barriers: no timing assumptions about downloads.
let gate = PlaybackLoadSubmissionGate()
let entered = DispatchSemaphore(value: 0)
let release = DispatchSemaphore(value: 0)
let done = DispatchSemaphore(value: 0)
let lock = NSLock()
var operations: [String] = []
func record(_ operation: String) { lock.withLock { operations.append(operation) } }

gate.advance(to: 1) { record("stop-1") }
DispatchQueue.global().async {
    gate.performIfCurrent(generation: 1) {
        entered.signal()
        release.wait()
        record("load-1")
    }
    done.signal()
}
precondition(entered.wait(timeout: .now() + 3) == .success)
// A new selection must not block behind a decoder currently opening a file.
gate.advance(to: 2) { record("stop-2") }
release.signal()
precondition(done.wait(timeout: .now() + 3) == .success)
gate.performIfCurrent(generation: 2) { record("load-2") }
gate.performIfCurrent(generation: 1) { record("stale-load") }
precondition(operations == ["stop-1", "load-1", "stop-2", "load-2"], "\(operations)")

// Finishing analysis after the listener rearranges the queue cannot re-arm it.
gate.setQueueRevision(1)
gate.setQueueRevision(2)
gate.performIfCurrent(generation: 2, revision: 1) { record("stale-plan") }
gate.performIfCurrent(generation: 2, revision: 2) { record("current-plan") }
precondition(operations.last == "current-plan" && !operations.contains("stale-plan"))

// Automatic handoffs invalidate old quality upgrades without stopping the mix.
gate.invalidate(to: 3)
gate.performIfCurrent(generation: 2) { record("stale-swap") }
precondition(!operations.contains("stale-swap"))
print("PASS: in-flight load ordering, stale selections, queue revisions and handoff invalidation")
