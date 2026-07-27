import Foundation

enum ProximityConfirmationRejection: Equatable {
    case sampleLimit
    case timeout
}

enum ProximityConfirmationDecision: Equatable {
    case ignored
    case started(sampleCount: Int, qualifyingCount: Int)
    case collecting(sampleCount: Int, qualifyingCount: Int)
    case confirmed(sampleCount: Int, elapsed: TimeInterval)
    case rejected(reason: ProximityConfirmationRejection,
                  sampleCount: Int,
                  elapsed: TimeInterval)
}

struct ProximityConfirmation {
    let candidateMargin = 5
    let timeout: TimeInterval = 1.5
    let maximumSamples = 3
    let requiredQualifyingSamples = 2

    private var startedAt: TimeInterval?
    private var activeThreshold: Int?
    private var samples: [Int] = []

    var isConfirming: Bool { startedAt != nil }

    mutating func record(rssi: Int,
                         at timestamp: TimeInterval,
                         unlockThreshold: Int) -> ProximityConfirmationDecision {
        if let activeThreshold = activeThreshold,
           activeThreshold != unlockThreshold {
            reset()
        }

        if let startedAt = startedAt,
           timestamp - startedAt >= timeout {
            let sampleCount = samples.count
            let elapsed = timestamp - startedAt
            reset()
            return .rejected(reason: .timeout,
                             sampleCount: sampleCount,
                             elapsed: elapsed)
        }

        if startedAt == nil {
            guard rssi >= unlockThreshold - candidateMargin else {
                return .ignored
            }
            startedAt = timestamp
            activeThreshold = unlockThreshold
        }

        samples.append(rssi)
        let qualifyingCount = samples.filter { $0 >= unlockThreshold }.count
        let sampleCount = samples.count
        let elapsed = timestamp - (startedAt ?? timestamp)

        if qualifyingCount >= requiredQualifyingSamples {
            reset()
            return .confirmed(sampleCount: sampleCount, elapsed: elapsed)
        }
        if sampleCount >= maximumSamples {
            reset()
            return .rejected(reason: .sampleLimit,
                             sampleCount: sampleCount,
                             elapsed: elapsed)
        }
        return sampleCount == 1
            ? .started(sampleCount: sampleCount,
                       qualifyingCount: qualifyingCount)
            : .collecting(sampleCount: sampleCount,
                          qualifyingCount: qualifyingCount)
    }

    mutating func expire(at timestamp: TimeInterval) -> ProximityConfirmationDecision {
        guard let startedAt = startedAt,
              timestamp - startedAt >= timeout else {
            return .ignored
        }
        let sampleCount = samples.count
        let elapsed = timestamp - startedAt
        reset()
        return .rejected(reason: .timeout,
                         sampleCount: sampleCount,
                         elapsed: elapsed)
    }

    mutating func reset() {
        startedAt = nil
        activeThreshold = nil
        samples.removeAll()
    }
}
