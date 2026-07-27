import Foundation
import XCTest
@testable import BLEUnlock

final class ProximityConfirmationTests: XCTestCase {
    func testIgnoresSamplesBelowCandidateThreshold() {
        var confirmation = ProximityConfirmation()

        let decision = confirmation.record(rssi: -61,
                                           at: 0,
                                           unlockThreshold: -55)

        XCTAssertEqual(decision, .ignored)
        XCTAssertFalse(confirmation.isConfirming)
    }

    func testCandidateBoundaryStartsConfirmationWithoutQualifying() {
        var confirmation = ProximityConfirmation()

        let decision = confirmation.record(rssi: -60,
                                           at: 0,
                                           unlockThreshold: -55)

        XCTAssertEqual(decision, .started(sampleCount: 1,
                                          qualifyingCount: 0))
        XCTAssertTrue(confirmation.isConfirming)
    }

    func testTwoQualifyingSamplesOutOfThreeConfirm() {
        var confirmation = ProximityConfirmation()
        XCTAssertEqual(confirmation.record(rssi: -58, at: 0,
                                           unlockThreshold: -55),
                       .started(sampleCount: 1, qualifyingCount: 0))
        XCTAssertEqual(confirmation.record(rssi: -54, at: 0.4,
                                           unlockThreshold: -55),
                       .collecting(sampleCount: 2, qualifyingCount: 1))

        let decision = confirmation.record(rssi: -55, at: 0.8,
                                           unlockThreshold: -55)

        XCTAssertEqual(decision, .confirmed(sampleCount: 3,
                                            elapsed: 0.8))
        XCTAssertFalse(confirmation.isConfirming)
    }

    func testOneQualifyingSampleOutOfThreeRejects() {
        var confirmation = ProximityConfirmation()
        _ = confirmation.record(rssi: -60, at: 0,
                                unlockThreshold: -55)
        _ = confirmation.record(rssi: -54, at: 0.4,
                                unlockThreshold: -55)

        let decision = confirmation.record(rssi: -57, at: 0.8,
                                           unlockThreshold: -55)

        XCTAssertEqual(decision,
                       .rejected(reason: .sampleLimit,
                                 sampleCount: 3,
                                 elapsed: 0.8))
        XCTAssertFalse(confirmation.isConfirming)
    }

    func testStrongSpikeFollowedByTwoWeakSamplesRejects() {
        var confirmation = ProximityConfirmation()
        _ = confirmation.record(rssi: -35, at: 0,
                                unlockThreshold: -55)
        _ = confirmation.record(rssi: -58, at: 0.4,
                                unlockThreshold: -55)

        let decision = confirmation.record(rssi: -59, at: 0.8,
                                           unlockThreshold: -55)

        XCTAssertEqual(decision,
                       .rejected(reason: .sampleLimit,
                                 sampleCount: 3,
                                 elapsed: 0.8))
    }

    func testSingleStrongSpikeTimesOutWithoutConfirming() {
        var confirmation = ProximityConfirmation()
        _ = confirmation.record(rssi: -40, at: 0,
                                unlockThreshold: -55)

        let decision = confirmation.expire(at: 1.5)

        XCTAssertEqual(decision,
                       .rejected(reason: .timeout,
                                 sampleCount: 1,
                                 elapsed: 1.5))
        XCTAssertFalse(confirmation.isConfirming)
    }

    func testSampleAtTimeoutBoundaryIsRejectedAsTimeout() {
        var confirmation = ProximityConfirmation()
        _ = confirmation.record(rssi: -54, at: 0,
                                unlockThreshold: -55)

        let decision = confirmation.record(rssi: -54, at: 1.5,
                                           unlockThreshold: -55)

        XCTAssertEqual(decision,
                       .rejected(reason: .timeout,
                                 sampleCount: 1,
                                 elapsed: 1.5))
    }

    func testResetClearsSamplesBeforeNextAttempt() {
        var confirmation = ProximityConfirmation()
        _ = confirmation.record(rssi: -54, at: 0,
                                unlockThreshold: -55)
        confirmation.reset()

        let decision = confirmation.record(rssi: -54, at: 0.4,
                                           unlockThreshold: -55)

        XCTAssertEqual(decision, .started(sampleCount: 1,
                                          qualifyingCount: 1))
    }

    func testChangingThresholdStartsFreshAttempt() {
        var confirmation = ProximityConfirmation()
        _ = confirmation.record(rssi: -54, at: 0,
                                unlockThreshold: -55)

        let decision = confirmation.record(rssi: -59, at: 0.4,
                                           unlockThreshold: -60)

        XCTAssertEqual(decision, .started(sampleCount: 1,
                                          qualifyingCount: 1))
    }
}
