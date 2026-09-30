import Foundation

enum Failure: Error { case transient, invalidated, ineligible }

@MainActor
final class FakeSession: NowPlayingSessionDriver {
    var canBecomeApplicationPrimary = true
    var isApplicationPrimary = false
    var isSystemPrimary = false
    var publications = 0
    var promotions = 0
    var failures: [Failure] = []
    var promotionFailure: Failure?
    var holdPublication = false
    var holdPromotion = false
    var publication: CheckedContinuation<Void, Error>?
    var promotion: CheckedContinuation<Void, Error>?
    var publicationCompletedCancelled = false
    var eligibilityChanged: (@MainActor () -> Void)?

    func publish() async throws {
        publications += 1
        if !failures.isEmpty { throw failures.removeFirst() }
        if holdPublication {
            try await withCheckedThrowingContinuation { publication = $0 }
        }
        publicationCompletedCancelled = Task.isCancelled
        isApplicationPrimary = true
    }

    func promote() async throws {
        precondition(isApplicationPrimary, "Promotion must follow publication")
        promotions += 1
        if let promotionFailure { throw promotionFailure }
        if holdPromotion {
            try await withCheckedThrowingContinuation { promotion = $0 }
        }
        isSystemPrimary = true
    }

    func classify(_ error: Error) -> NowPlayingClaimFailure {
        switch error as? Failure {
        case .invalidated: return .invalidated
        case .ineligible: return .ineligible
        default: return .transient
        }
    }
    func observeEligibility(_ changed: @escaping @MainActor () -> Void) { eligibilityChanged = changed }
    func stopObserving() { eligibilityChanged = nil }
}

@MainActor
final class Harness {
    var ready = true
    var readiness: AudioSessionReadiness?
    var foreground = true
    var sessions: [FakeSession] = [FakeSession()]
    var created = 0
    var delays: [UInt64] = []
    var sleepers: [CheckedContinuation<Void, Error>] = []
    var logs: [String] = []
    lazy var lifecycle = NowPlayingLifecycle(
        makeSession: { [unowned self] in
            precondition(created < sessions.count, "Unexpected session recreation")
            defer { created += 1 }
            return sessions[created]
        },
        audioReady: { [unowned self] in readiness?.isActive ?? ready },
        foreground: { [unowned self] in foreground },
        sleep: { [unowned self] delay in
            delays.append(delay)
            try await withCheckedThrowingContinuation { sleepers.append($0) }
        },
        log: { [unowned self] in logs.append($0) }
    )
    func play(_ id: String = "track-a") {
        lifecycle.update(contentID: id, playing: true)
        lifecycle.request(reason: "playback")
    }
    func pause() { lifecycle.update(contentID: lifecycle.contentID, playing: false) }
    func wake() { sleepers.removeFirst().resume() }
    func saw(_ text: String) -> Bool { logs.contains { $0.contains(text) } }
}

@MainActor
func until(_ label: String, _ predicate: () -> Bool) async {
    for _ in 0..<10_000 {
        if predicate() { return }
        await Task.yield()
    }
    preconditionFailure("Timed out: \(label)")
}

@main
struct Verify {
    @MainActor
    static func main() async {
        // Control real readiness transitions while activation is blocked on a
        // worker, as it is when AVAudioSession talks to the audio daemon.
        let readiness = AudioSessionReadiness()
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let blockedActivation = Task.detached {
            try readiness.activate {
                entered.signal()
                release.wait()
                return 48_000
            }
        }
        await until("activation barrier") { entered.wait(timeout: .now()) == .success }
        let pendingActivation = Harness()
        pendingActivation.readiness = readiness
        pendingActivation.play()
        precondition(pendingActivation.created == 0 && !readiness.isActive)
        readiness.invalidate() // Interruption/reset before activation returns.
        release.signal()
        do {
            _ = try await blockedActivation.value
            preconditionFailure("Invalidated activation must fail")
        } catch AudioSessionReadiness.ActivationError.invalidatedDuringActivation {
            precondition(!readiness.isActive)
        } catch { preconditionFailure("Unexpected activation error: \(error)") }
        do {
            try readiness.activate { throw Failure.transient }
            preconditionFailure("Activation errors must propagate")
        } catch { precondition(!readiness.isActive) }
        let format = try! readiness.activate { 44_100 }
        precondition(format == 44_100 && readiness.isActive)
        pendingActivation.play()
        await until("successful activation published") { pendingActivation.sessions[0].promotions == 1 }

        // Failed activation and restored metadata cannot create a session.
        let activation = Harness()
        activation.ready = false
        activation.play()
        precondition(activation.created == 0)
        activation.ready = true
        activation.pause()
        activation.lifecycle.request(reason: "foreground")
        precondition(activation.created == 0)
        activation.play()
        await until("activation recovery") { activation.sessions[0].promotions == 1 }

        // Explicit preparation registers commands before engine play without
        // claiming prominence, and still requires successful audio activation.
        let prepared = Harness()
        prepared.lifecycle.update(contentID: "prepared-track", playing: false)
        prepared.ready = false
        prepared.lifecycle.prepare()
        precondition(prepared.created == 0)
        prepared.ready = true
        prepared.lifecycle.prepare()
        precondition(prepared.created == 1)
        precondition(prepared.sessions[0].publications == 0 && prepared.sessions[0].promotions == 0)
        prepared.lifecycle.request(reason: "foreground")
        precondition(prepared.sessions[0].publications == 0)
        prepared.play("prepared-track")
        await until("prepared playback published") { prepared.sessions[0].promotions == 1 }
        precondition(prepared.created == 1)

        // Pause during an uncooperative system call blocks the next request.
        let pause = Harness()
        let pausedDriver = pause.sessions[0]
        pausedDriver.holdPublication = true
        pause.play()
        await until("publication barrier") { pausedDriver.publication != nil }
        pause.pause()
        pausedDriver.publication!.resume()
        await until("stale publication completed") { pausedDriver.isApplicationPrimary }
        precondition(pausedDriver.promotions == 0)
        pause.play()
        await until("resume uses retained session") { pausedDriver.promotions == 1 }
        precondition(pause.created == 1)

        // Resuming before an uncancellable publication finishes reuses it.
        let overlap = Harness()
        overlap.sessions[0].holdPublication = true
        overlap.play()
        await until("overlapping publication barrier") { overlap.sessions[0].publication != nil }
        overlap.pause()
        overlap.play()
        overlap.lifecycle.request(reason: "foreground")
        for _ in 0..<100 { await Task.yield() }
        precondition(overlap.sessions[0].publications == 1)
        overlap.sessions[0].publication!.resume()
        await until("overlapping resume finished") { overlap.sessions[0].promotions == 1 }
        precondition(overlap.created == 1)

        // Old completions, including failures, must not affect a new lifecycle.
        let stop = Harness()
        let oldDriver = stop.sessions[0]
        oldDriver.holdPublication = true
        stop.sessions.append(FakeSession())
        stop.play()
        await until("old publication barrier") { oldDriver.publication != nil }
        stop.lifecycle.stop()
        precondition(oldDriver.eligibilityChanged == nil)
        stop.play("track-b")
        await until("new session primary") { stop.sessions[1].promotions == 1 }
        oldDriver.publication!.resume(throwing: Failure.transient)
        for _ in 0..<100 { await Task.yield() }
        precondition(oldDriver.promotions == 0 && stop.delays.isEmpty)
        precondition(stop.lifecycle.contentID == "track-b" && stop.created == 2)

        // A late successful old publication can change the framework's primary
        // selection. The active session recovers on an application-status edge.
        let supersededSuccess = Harness()
        supersededSuccess.sessions[0].holdPublication = true
        supersededSuccess.sessions.append(FakeSession())
        supersededSuccess.play()
        await until("superseded success barrier") { supersededSuccess.sessions[0].publication != nil }
        supersededSuccess.lifecycle.stop()
        supersededSuccess.play("new-playback")
        await until("replacement primary before old completion") { supersededSuccess.sessions[1].promotions == 1 }
        supersededSuccess.sessions[0].publication!.resume()
        await until("old publication returned success") { supersededSuccess.sessions[0].isApplicationPrimary }
        precondition(supersededSuccess.sessions[0].publicationCompletedCancelled)
        supersededSuccess.sessions[1].isApplicationPrimary = false
        supersededSuccess.sessions[1].eligibilityChanged?()
        await until("application primary restored") { supersededSuccess.sessions[1].publications == 2 }
        precondition(supersededSuccess.created == 2 && supersededSuccess.sessions[0].promotions == 0)

        // A late prominence response after pause cannot publish success.
        let promotion = Harness()
        promotion.sessions[0].holdPromotion = true
        promotion.play()
        await until("promotion barrier") { promotion.sessions[0].promotion != nil }
        promotion.pause()
        promotion.sessions[0].promotion!.resume()
        await until("late promotion finished") { promotion.sessions[0].isSystemPrimary }
        precondition(!promotion.saw("prominence granted"))

        // Only publication failures receive the two bounded timed retries.
        let retries = Harness()
        retries.sessions[0].failures = [.transient, .transient, .transient]
        retries.play()
        await until("first retry") { retries.sleepers.count == 1 }
        // Track identity/artwork changes must not reset the retry budget.
        retries.lifecycle.update(contentID: "same-title-other-recording", playing: true)
        precondition(retries.lifecycle.contentID == "same-title-other-recording")
        retries.wake()
        await until("second retry") { retries.sleepers.count == 1 }
        retries.wake()
        await until("bounded exhaustion") { retries.saw("retries exhausted") }
        precondition(retries.delays == [1_000_000_000, 5_000_000_000])
        precondition(retries.sessions[0].publications == 3 && retries.created == 1)
        retries.lifecycle.request(reason: "foreground")
        await until("new foreground attempt") { retries.sessions[0].promotions == 1 }

        let prominence = Harness()
        prominence.sessions[0].promotionFailure = .transient
        prominence.play()
        await until("prominence refusal") { prominence.saw("prominence failed") }
        precondition(prominence.delays.isEmpty && prominence.sessions[0].publications == 1)

        // Stop/pause during retry sleep must prevent another publication.
        let sleeping = Harness()
        sleeping.sessions[0].failures = [.transient]
        sleeping.play()
        await until("retry sleep") { sleeping.sleepers.count == 1 }
        sleeping.lifecycle.stop()
        sleeping.wake()
        for _ in 0..<100 { await Task.yield() }
        precondition(sleeping.sessions[0].publications == 1)

        // Invalidation gets one replacement, even across subsequent play events.
        let invalidation = Harness()
        invalidation.sessions[0].failures = [.invalidated]
        invalidation.sessions.append(FakeSession())
        invalidation.play()
        await until("replacement published") { invalidation.sessions[1].promotions == 1 }
        precondition(invalidation.created == 2 && invalidation.delays.isEmpty)
        invalidation.sessions[1].isApplicationPrimary = false
        invalidation.sessions[1].failures = [.invalidated]
        invalidation.lifecycle.request(reason: "foreground")
        await until("second invalidation refused") { invalidation.saw("invalidated again") }
        precondition(invalidation.created == 2)

        // Eligibility transitions wake an ineligible session without polling.
        let eligibility = Harness()
        eligibility.sessions[0].canBecomeApplicationPrimary = false
        eligibility.play()
        await until("ineligible check") { eligibility.saw("publication ineligible") }
        precondition(eligibility.sessions[0].publications == 0 && eligibility.delays.isEmpty)
        eligibility.sessions[0].canBecomeApplicationPrimary = true
        eligibility.sessions[0].eligibilityChanged?()
        await until("eligibility recovery") { eligibility.sessions[0].promotions == 1 }

        // Background playback can publish, but cannot request system takeover.
        let background = Harness()
        background.foreground = false
        background.play()
        await until("background publication") { background.saw("publication ready") }
        precondition(background.sessions[0].promotions == 0)
        background.foreground = true
        background.lifecycle.request(reason: "foreground")
        await until("foreground takeover") { background.sessions[0].promotions == 1 }

        let backgroundDuringPublication = Harness()
        backgroundDuringPublication.sessions[0].holdPublication = true
        backgroundDuringPublication.play()
        await until("foreground publication barrier") { backgroundDuringPublication.sessions[0].publication != nil }
        backgroundDuringPublication.foreground = false
        backgroundDuringPublication.sessions[0].publication!.resume()
        await until("publication finished in background") { backgroundDuringPublication.saw("publication ready") }
        precondition(backgroundDuringPublication.sessions[0].promotions == 0)

        // Loss of readiness while awaiting publication prevents takeover.
        let lostAudio = Harness()
        lostAudio.sessions[0].holdPublication = true
        lostAudio.play()
        await until("audio loss barrier") { lostAudio.sessions[0].publication != nil }
        lostAudio.ready = false
        lostAudio.lifecycle.suspend()
        lostAudio.sessions[0].publication!.resume()
        await until("audio loss completed") { lostAudio.sessions[0].isApplicationPrimary }
        precondition(lostAudio.sessions[0].promotions == 0)
        lostAudio.ready = true
        lostAudio.lifecycle.request(reason: "route activation")
        await until("route recovery") { lostAudio.sessions[0].promotions == 1 }

        for harness in [pendingActivation, activation, prepared, pause, overlap, stop, supersededSuccess, promotion, retries, prominence,
                        sleeping, invalidation, eligibility, background, backgroundDuringPublication, lostAudio] {
            harness.lifecycle.stop()
        }
        print("PASS: readiness, stale completions, retained sessions, bounded retries, invalidation, identity and foreground-only takeover")
    }
}
