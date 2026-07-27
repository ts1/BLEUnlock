import Foundation
import XCTest
@testable import BLEUnlock

final class ProximityMonitorTests: XCTestCase {
    func testCandidateStartsTimeoutAndNormalModeBurst() {
        let fixture = Fixture()

        fixture.monitor.receive(rssi: -60,
                                unlockThreshold: -55,
                                allowsBurst: true)

        XCTAssertEqual(fixture.scheduler.entries.map(\.interval), [1.5, 0.4])
        XCTAssertEqual(fixture.scheduler.entries.map(\.repeats), [false, true])
    }

    func testPassiveModeStartsTimeoutWithoutBurstRequests() {
        let fixture = Fixture()

        fixture.monitor.receive(rssi: -60,
                                unlockThreshold: -55,
                                allowsBurst: false)

        XCTAssertEqual(fixture.scheduler.entries.map(\.interval), [1.5])
        XCTAssertEqual(fixture.sampleRequests, 0)
    }

    func testBurstTickRequestsFreshRSSI() throws {
        let fixture = Fixture()
        fixture.monitor.receive(rssi: -60,
                                unlockThreshold: -55,
                                allowsBurst: true)

        try XCTUnwrap(fixture.scheduler.entries.first { $0.repeats }).action()

        XCTAssertEqual(fixture.sampleRequests, 1)
    }

    func testResetInvalidatesStaleBurstCallback() throws {
        let fixture = Fixture()
        fixture.monitor.receive(rssi: -60,
                                unlockThreshold: -55,
                                allowsBurst: true)
        let burst = try XCTUnwrap(fixture.scheduler.entries.first { $0.repeats })

        fixture.monitor.reset(reason: "device changed")
        burst.action()

        XCTAssertEqual(fixture.sampleRequests, 0)
    }

    func testSecondQualifyingSampleConfirmsOnceAndCancelsTimers() {
        let fixture = Fixture()
        fixture.monitor.receive(rssi: -54,
                                unlockThreshold: -55,
                                allowsBurst: true)
        fixture.now = 0.4

        fixture.monitor.receive(rssi: -55,
                                unlockThreshold: -55,
                                allowsBurst: true)

        XCTAssertEqual(fixture.confirmations, 1)
        XCTAssertTrue(fixture.scheduler.entries.allSatisfy(\.cancellation.isCancelled))
    }

    func testConfirmationInvalidatesStaleBurstCallback() throws {
        let fixture = Fixture()
        fixture.monitor.receive(rssi: -54,
                                unlockThreshold: -55,
                                allowsBurst: true)
        let burst = try XCTUnwrap(fixture.scheduler.entries.first { $0.repeats })
        fixture.now = 0.4
        fixture.monitor.receive(rssi: -55,
                                unlockThreshold: -55,
                                allowsBurst: true)

        burst.action()

        XCTAssertEqual(fixture.confirmations, 1)
        XCTAssertEqual(fixture.sampleRequests, 0)
    }

    func testTimeoutRejectsAndStopsBurst() throws {
        let fixture = Fixture()
        fixture.monitor.receive(rssi: -54,
                                unlockThreshold: -55,
                                allowsBurst: true)
        fixture.now = 1.5

        try XCTUnwrap(fixture.scheduler.entries.first { !$0.repeats }).action()

        XCTAssertEqual(fixture.confirmations, 0)
        XCTAssertTrue(fixture.scheduler.entries.allSatisfy(\.cancellation.isCancelled))
        XCTAssertTrue(fixture.messages.contains { $0.contains("timeout") })
    }

    func testTimeoutInvalidatesStaleBurstCallback() throws {
        let fixture = Fixture()
        fixture.monitor.receive(rssi: -54,
                                unlockThreshold: -55,
                                allowsBurst: true)
        let timeout = try XCTUnwrap(fixture.scheduler.entries.first { !$0.repeats })
        let burst = try XCTUnwrap(fixture.scheduler.entries.first { $0.repeats })
        fixture.now = 1.5
        timeout.action()

        burst.action()

        XCTAssertEqual(fixture.confirmations, 0)
        XCTAssertEqual(fixture.sampleRequests, 0)
    }

    func testResetCancelsAttemptAndPreventsStaleTimeoutConfirmation() throws {
        let fixture = Fixture()
        fixture.monitor.receive(rssi: -54,
                                unlockThreshold: -55,
                                allowsBurst: true)
        let timeout = try XCTUnwrap(fixture.scheduler.entries.first { !$0.repeats })

        fixture.monitor.reset(reason: "device changed")
        fixture.now = 1.5
        timeout.action()

        XCTAssertEqual(fixture.confirmations, 0)
        XCTAssertTrue(timeout.cancellation.isCancelled)
    }

    func testOldTimeoutDoesNotAffectNewAttempt() throws {
        let fixture = Fixture()
        fixture.monitor.receive(rssi: -54,
                                unlockThreshold: -55,
                                allowsBurst: true)
        let oldTimeout = try XCTUnwrap(fixture.scheduler.entries.first { !$0.repeats })

        fixture.monitor.reset(reason: "device changed")
        fixture.now = 0.4
        fixture.monitor.receive(rssi: -54,
                                unlockThreshold: -55,
                                allowsBurst: true)
        let newTimeout = try XCTUnwrap(fixture.scheduler.entries.last { !$0.repeats })
        fixture.messages.removeAll()
        fixture.now = 1.9

        oldTimeout.action()

        XCTAssertFalse(newTimeout.cancellation.isCancelled)
        XCTAssertFalse(fixture.messages.contains { $0.contains("timeout") })
    }

    func testStaleCallbacksAfterConfirmationDoNotConfirmAgain() throws {
        let fixture = Fixture()
        fixture.monitor.receive(rssi: -54,
                                unlockThreshold: -55,
                                allowsBurst: true)
        let timeout = try XCTUnwrap(fixture.scheduler.entries.first { !$0.repeats })
        let burst = try XCTUnwrap(fixture.scheduler.entries.first { $0.repeats })
        fixture.now = 0.4
        fixture.monitor.receive(rssi: -55,
                                unlockThreshold: -55,
                                allowsBurst: true)
        fixture.requestedSample = {
            fixture.monitor.receive(rssi: -55,
                                    unlockThreshold: -55,
                                    allowsBurst: true)
        }

        fixture.now = 1.5
        timeout.action()
        burst.action()
        burst.action()

        XCTAssertEqual(fixture.confirmations, 1)
    }

    func testStaleCallbacksAfterTimeoutDoNotConfirm() throws {
        let fixture = Fixture()
        fixture.monitor.receive(rssi: -54,
                                unlockThreshold: -55,
                                allowsBurst: true)
        let timeout = try XCTUnwrap(fixture.scheduler.entries.first { !$0.repeats })
        let burst = try XCTUnwrap(fixture.scheduler.entries.first { $0.repeats })
        fixture.now = 1.5
        timeout.action()
        fixture.requestedSample = {
            fixture.monitor.receive(rssi: -55,
                                    unlockThreshold: -55,
                                    allowsBurst: true)
        }

        timeout.action()
        burst.action()
        burst.action()

        XCTAssertEqual(fixture.confirmations, 0)
    }
}

private final class Fixture {
    var now: TimeInterval = 0
    var sampleRequests = 0
    var confirmations = 0
    var messages: [String] = []
    var requestedSample: (() -> Void)?
    let scheduler = ManualProximityScheduler()
    lazy var monitor = ProximityMonitor(
        scheduler: scheduler,
        now: { self.now },
        requestSample: {
            self.sampleRequests += 1
            self.requestedSample?()
        },
        onConfirmed: { self.confirmations += 1 },
        logger: { self.messages.append($0) }
    )
}

private final class ManualProximityCancellation: ProximityScheduledCancellation {
    private(set) var isCancelled = false
    func cancel() { isCancelled = true }
}

private final class ManualProximityScheduler: ProximityScheduling {
    struct Entry {
        let interval: TimeInterval
        let repeats: Bool
        let cancellation: ManualProximityCancellation
        let action: () -> Void
    }

    private(set) var entries: [Entry] = []

    func schedule(after interval: TimeInterval,
                  repeats: Bool,
                  _ action: @escaping () -> Void) -> ProximityScheduledCancellation {
        let cancellation = ManualProximityCancellation()
        entries.append(Entry(interval: interval,
                             repeats: repeats,
                             cancellation: cancellation,
                             action: action))
        return cancellation
    }
}
