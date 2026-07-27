import Foundation

protocol ProximityScheduledCancellation: AnyObject {
    func cancel()
}

protocol ProximityScheduling {
    @discardableResult
    func schedule(after interval: TimeInterval,
                  repeats: Bool,
                  _ action: @escaping () -> Void) -> ProximityScheduledCancellation
}

private final class TimerProximityCancellation: ProximityScheduledCancellation {
    private let timer: Timer

    init(timer: Timer) {
        self.timer = timer
    }

    func cancel() {
        timer.invalidate()
    }
}

final class RunLoopProximityScheduler: ProximityScheduling {
    func schedule(after interval: TimeInterval,
                  repeats: Bool,
                  _ action: @escaping () -> Void) -> ProximityScheduledCancellation {
        let timer = Timer(timeInterval: interval, repeats: repeats) { _ in action() }
        RunLoop.main.add(timer, forMode: .common)
        return TimerProximityCancellation(timer: timer)
    }
}

final class ProximityMonitor {
    private let scheduler: ProximityScheduling
    private let now: () -> TimeInterval
    private let requestSample: () -> Void
    private let onConfirmed: () -> Void
    private let logger: (String) -> Void
    private var confirmation = ProximityConfirmation()
    private var timeoutCancellation: ProximityScheduledCancellation?
    private var burstCancellation: ProximityScheduledCancellation?
    private var activeAttemptID: UUID?

    init(scheduler: ProximityScheduling = RunLoopProximityScheduler(),
         now: @escaping () -> TimeInterval = { Date().timeIntervalSince1970 },
         requestSample: @escaping () -> Void,
         onConfirmed: @escaping () -> Void,
         logger: @escaping (String) -> Void = { print($0) }) {
        self.scheduler = scheduler
        self.now = now
        self.requestSample = requestSample
        self.onConfirmed = onConfirmed
        self.logger = logger
    }

    func receive(rssi: Int, unlockThreshold: Int, allowsBurst: Bool) {
        handle(confirmation.record(rssi: rssi,
                                   at: now(),
                                   unlockThreshold: unlockThreshold),
               allowsBurst: allowsBurst,
               rssi: rssi)
    }

    func reset(reason: String) {
        let wasConfirming = confirmation.isConfirming
        confirmation.reset()
        stopTimers()
        if wasConfirming {
            logger("Proximity confirmation reset: \(reason)")
        }
    }

    private func handle(_ decision: ProximityConfirmationDecision,
                        allowsBurst: Bool,
                        rssi: Int?) {
        switch decision {
        case .ignored:
            return
        case .started(let sampleCount, let qualifyingCount):
            logger("Proximity confirmation started: sample \(sampleCount), RSSI \(rssi ?? 0), qualifying \(qualifyingCount)")
            startTimers(allowsBurst: allowsBurst)
        case .collecting(let sampleCount, let qualifyingCount):
            logger("Proximity confirmation sample \(sampleCount), RSSI \(rssi ?? 0), qualifying \(qualifyingCount)")
        case .confirmed(let sampleCount, let elapsed):
            stopTimers()
            logger("Proximity confirmed with \(sampleCount) samples in \(elapsed)s")
            onConfirmed()
        case .rejected(let reason, let sampleCount, let elapsed):
            stopTimers()
            logger("Proximity confirmation rejected: \(reason), \(sampleCount) samples in \(elapsed)s")
        }
    }

    private func startTimers(allowsBurst: Bool) {
        stopTimers()
        let attemptID = UUID()
        activeAttemptID = attemptID
        timeoutCancellation = scheduler.schedule(after: confirmation.timeout,
                                                 repeats: false) { [weak self] in
            guard let self,
                  self.activeAttemptID == attemptID else { return }
            self.handle(self.confirmation.expire(at: self.now()),
                        allowsBurst: false,
                        rssi: nil)
        }
        if allowsBurst {
            burstCancellation = scheduler.schedule(after: 0.4,
                                                    repeats: true) { [weak self] in
                guard let self,
                      self.activeAttemptID == attemptID else { return }
                self.requestSample()
            }
            logger("Proximity burst sampling started")
        }
    }

    private func stopTimers() {
        activeAttemptID = nil
        timeoutCancellation?.cancel()
        timeoutCancellation = nil
        if burstCancellation != nil {
            logger("Proximity burst sampling stopped")
        }
        burstCancellation?.cancel()
        burstCancellation = nil
    }
}
