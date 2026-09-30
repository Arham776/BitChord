import Foundation

enum NowPlayingClaimFailure: Equatable {
    case transient, ineligible, invalidated
}

/// The system adapter is replaceable so delayed completions and eligibility
/// changes can be verified without relying on system UI arbitration.
@MainActor
protocol NowPlayingSessionDriver: AnyObject {
    var canBecomeApplicationPrimary: Bool { get }
    var isApplicationPrimary: Bool { get }
    var isSystemPrimary: Bool { get }
    func publish() async throws
    func promote() async throws
    func classify(_ error: Error) -> NowPlayingClaimFailure
    func observeEligibility(_ changed: @escaping @MainActor () -> Void)
    func stopObserving()
}

/// Metadata describes playback; only explicit playback/lifecycle events ask
/// for publication. Audio options are never changed by this coordinator.
@MainActor
final class NowPlayingLifecycle {
    private let makeSession: () -> (any NowPlayingSessionDriver)?
    private let audioReady: () -> Bool
    private let foreground: () -> Bool
    private let sleep: (UInt64) async throws -> Void
    private let log: (String) -> Void
    private var session: (any NowPlayingSessionDriver)?
    private var claimTask: Task<Void, Never>?
    private enum Operation: Hashable { case publication, prominence }
    private struct OperationKey: Hashable {
        let session: ObjectIdentifier
        let operation: Operation
    }
    private var inFlight: [OperationKey: Task<Void, Error>] = [:]
    private var generation: UInt64 = 0
    private var recreated = false
    private var playing = false
    private(set) var contentID: String?
    var hasSession: Bool { session != nil }

    init(makeSession: @escaping () -> (any NowPlayingSessionDriver)?,
         audioReady: @escaping () -> Bool,
         foreground: @escaping () -> Bool,
         sleep: @escaping (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) },
         log: @escaping (String) -> Void) {
        self.makeSession = makeSession
        self.audioReady = audioReady
        self.foreground = foreground
        self.sleep = sleep
        self.log = log
    }

    func update(contentID: String?, playing: Bool) {
        self.contentID = contentID
        self.playing = playing
        if !playing { cancelClaim() }
    }

    /// Register the representation before releasing a loaded source to the
    /// audio callback. This is explicit playback preparation, never restoration.
    func prepare() {
        guard contentID != nil, audioReady() else { return }
        ensureSession()
        record("session registered before playback", reason: "preparation")
    }

    private func ensureSession() {
        guard session == nil, let driver = makeSession() else { return }
        session = driver
        driver.observeEligibility { [weak self, weak driver] in
            guard let self, let driver, self.session === driver else { return }
            self.request(reason: "eligibility changed")
        }
    }

    func request(reason: String) {
        guard playing, contentID != nil, audioReady() else {
            record("request deferred", reason: reason)
            return
        }
        cancelClaim()
        let intent = generation
        claimTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == intent { self.claimTask = nil } }
            await self.claim(reason: reason, intent: intent)
        }
    }

    func suspend() {
        cancelClaim()
    }

    func stop() {
        playing = false
        suspend()
        // The framework may honor cancellation even though cancellation cannot
        // undo a request already accepted by iOS. This lifecycle will never
        // reuse these operations, unlike a pause followed by resume.
        for task in inFlight.values { task.cancel() }
        contentID = nil
        session?.stopObserving()
        session = nil
        recreated = false
    }

    private func cancelClaim() {
        generation &+= 1
        claimTask?.cancel()
        claimTask = nil
    }

    private func current(_ intent: UInt64, _ driver: any NowPlayingSessionDriver) -> Bool {
        !Task.isCancelled && generation == intent && session === driver
            && playing && contentID != nil && audioReady()
    }

    private func claim(reason: String, intent: UInt64) async {
        // Publication retries are bounded independently of prominence refusal.
        let retryDelays: [UInt64] = [1_000_000_000, 5_000_000_000]
        var retry = 0
        while !Task.isCancelled && generation == intent && playing && audioReady() {
            ensureSession()
            guard let driver = session, current(intent, driver) else { return }
            record("publication check", reason: reason)
            var publicationError: Error?
            if !driver.isApplicationPrimary {
                guard driver.canBecomeApplicationPrimary else {
                    record("publication ineligible; waiting for eligibility", reason: reason)
                    return
                }
                do {
                    try await perform(.publication, on: driver)
                    guard current(intent, driver) else { return }
                    if !driver.isApplicationPrimary {
                        publicationError = NSError(domain: "BitChord.NowPlaying", code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "Publication completed without application-primary status"])
                    }
                } catch {
                    guard current(intent, driver) else { return }
                    publicationError = error
                }
            }
            if let error = publicationError {
                record("publication failed: \(error)", reason: reason)
                switch driver.classify(error) {
                case .invalidated:
                    guard recreate(driver, reason: reason) else { return }
                    continue
                case .ineligible:
                    return
                case .transient:
                    guard retry < retryDelays.count else {
                        record("publication retries exhausted", reason: reason)
                        return
                    }
                    let delay = retryDelays[retry]
                    retry += 1
                    do { try await sleep(delay) } catch { return }
                    guard current(intent, driver) else { return }
                    continue
                }
            }
            guard current(intent, driver), driver.isApplicationPrimary else { return }
            record("publication ready", reason: reason)
            guard foreground(), !driver.isSystemPrimary else { return }
            do {
                try await perform(.prominence, on: driver)
                guard current(intent, driver), foreground() else { return }
                record(driver.isSystemPrimary ? "prominence granted" : "prominence not granted", reason: reason)
            } catch {
                guard current(intent, driver), foreground() else { return }
                record("prominence failed: \(error)", reason: reason)
                if driver.classify(error) == .invalidated, recreate(driver, reason: reason) {
                    continue
                }
            }
            return
        }
    }

    /// Cancellation cannot retract a request already sent to iOS. A resume or
    /// foreground event reuses that operation instead of sending a concurrent
    /// request for the same session. Its old caller still fails the intent check.
    private func perform(_ operation: Operation, on driver: any NowPlayingSessionDriver) async throws {
        let key = OperationKey(session: ObjectIdentifier(driver), operation: operation)
        if let task = inFlight[key] { return try await task.value }
        let task = Task { [weak self] in
            guard let self, self.session === driver, self.playing,
                  self.contentID != nil, self.audioReady() else { throw CancellationError() }
            switch operation {
            case .publication:
                if !driver.isApplicationPrimary { try await driver.publish() }
            case .prominence:
                guard self.foreground(), driver.isApplicationPrimary else { throw CancellationError() }
                if !driver.isSystemPrimary { try await driver.promote() }
            }
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        try await task.value
    }

    private func recreate(_ driver: any NowPlayingSessionDriver, reason: String) -> Bool {
        guard !recreated else {
            record("session invalidated again; waiting for a new playback lifecycle", reason: reason)
            return false
        }
        recreated = true
        driver.stopObserving()
        session = nil
        record("recreating invalidated session", reason: reason)
        return true
    }

    private func record(_ event: String, reason: String) {
        log("Now Playing \(event) reason=\(reason) content=\(contentID ?? "none") "
            + "audioReady=\(audioReady()) foreground=\(foreground()) "
            + "eligible=\(session?.canBecomeApplicationPrimary.description ?? "none") "
            + "applicationPrimary=\(session?.isApplicationPrimary.description ?? "none") "
            + "systemPrimary=\(session?.isSystemPrimary.description ?? "none")")
    }
}

/// Native command success must follow the asynchronous playback start. A
/// delayed activation/load may finish after Pause, Stop, or a newer selection.
@MainActor
enum NowPlayingCommandCompletion {
    static func perform(action: () async throws -> Void,
                        stillCurrent: () -> Bool) async throws {
        try await action()
        guard !Task.isCancelled, stillCurrent() else { throw CancellationError() }
    }
}

/// Publish rate, elapsed time and timestamp as one observable value. Updating
/// them independently lets native UI read a mixture of old and new transport.
struct NowPlayingPlaybackState: Equatable {
    var rate: Double = 0
    var position: Double = 0
    var preparing = false
    var timestamp = Date()

    func updating(rate: Double? = nil, position: Double? = nil,
                  preparing: Bool? = nil, at timestamp: Date = Date()) -> Self {
        let nextRate = rate.map { $0.isFinite ? max(0, $0) : 0 } ?? self.rate
        let nextPosition = position.flatMap { $0.isFinite ? max(0, $0) : nil } ?? self.position
        let nextPreparing = preparing ?? (rate != nil && nextRate == 0 ? false : self.preparing)
        guard nextRate != self.rate || nextPosition != self.position || nextPreparing != self.preparing else { return self }
        return Self(rate: nextRate, position: nextPosition, preparing: nextPreparing, timestamp: timestamp)
    }
}
