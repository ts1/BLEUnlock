import Foundation
import XCTest

final class DeviceSetPolicyTests: XCTestCase {
    private let a = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let b = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

    func testSingleDeviceReadingAndExpiry() {
        var policy = DeviceSetPolicy(uuids: [a], mode: .weakest, timeout: 10, now: 0)
        XCTAssertEqual(policy.signal(at: 0), .waiting)
        policy.record(-60, for: a, now: 1)
        XCTAssertEqual(policy.signal(at: 10.999), .value(raw: -60, estimated: -60))
        XCTAssertEqual(policy.signal(at: 11), .lost)
        XCTAssertNil(policy.nextDeadline(after: 11))
    }

    func testStrongestUsesRemainingDeviceWhenOtherExpires() {
        var policy = DeviceSetPolicy(uuids: [a, b], mode: .strongest, timeout: 10, now: 0)
        policy.record(-45, for: a, now: 1)
        policy.record(-75, for: b, now: 5)
        XCTAssertEqual(policy.signal(at: 6), .value(raw: -45, estimated: -45))
        XCTAssertEqual(policy.signal(at: 11), .value(raw: -75, estimated: -75))
        XCTAssertEqual(policy.signal(at: 15), .lost)
    }

    func testWeakestTreatsOneExpiredDeviceAsLost() {
        var policy = DeviceSetPolicy(uuids: [a, b], mode: .weakest, timeout: 10, now: 0)
        policy.record(-45, for: a, now: 1)
        policy.record(-75, for: b, now: 5)
        XCTAssertEqual(policy.signal(at: 6), .value(raw: -75, estimated: -75))
        XCTAssertEqual(policy.signal(at: 11), .lost)
        policy.record(-50, for: a, now: 12)
        XCTAssertEqual(policy.signal(at: 12), .value(raw: -75, estimated: -75))
    }

    func testPendingDeviceDoesNotCauseEarlyLockOrUnlock() {
        var policy = DeviceSetPolicy(uuids: [a, b], mode: .weakest, timeout: 10, now: 0)
        policy.record(-40, for: a, now: 1)
        XCTAssertEqual(policy.signal(at: 9.999), .partial(raw: -40, estimated: -40, mode: .weakest))
        XCTAssertFalse(policy.signal(at: 9.999).isClose(unlockRSSI: -60, lockRSSI: -80, unlockDisabled: 1))
        XCTAssertFalse(policy.signal(at: 9.999).isAway(lockRSSI: -80, unlockRSSI: -60, lockDisabled: -100))
        XCTAssertEqual(policy.signal(at: 10), .lost)
    }

    func testWeakestKnownAwayRemainsAwayWhenAnotherDeviceIsPending() {
        var policy = DeviceSetPolicy(uuids: [a, b], mode: .weakest, timeout: 10, now: 0)
        policy.record(-81, for: a, now: 1)
        XCTAssertTrue(policy.signal(at: 2).isAway(lockRSSI: -80, unlockRSSI: -60, lockDisabled: -100))
        policy.record(-50, for: a, now: 3)
        XCTAssertFalse(policy.signal(at: 3).isAway(lockRSSI: -80, unlockRSSI: -60, lockDisabled: -100))
        XCTAssertFalse(policy.signal(at: 3).isClose(unlockRSSI: -60, lockRSSI: -80, unlockDisabled: 1))
    }

    func testStrongestPendingCannotCauseEarlyLockButKnownStrongSignalCanUnlock() {
        var policy = DeviceSetPolicy(uuids: [a, b], mode: .strongest, timeout: 10, now: 0)
        policy.record(-81, for: a, now: 1)
        XCTAssertFalse(policy.signal(at: 2).isAway(lockRSSI: -80, unlockRSSI: -60, lockDisabled: -100))
        policy.record(-60, for: a, now: 3)
        XCTAssertTrue(policy.signal(at: 3).isClose(unlockRSSI: -60, lockRSSI: -80, unlockDisabled: 1))
        policy.record(-81, for: b, now: 4)
        XCTAssertFalse(policy.signal(at: 4).isAway(lockRSSI: -80, unlockRSSI: -60, lockDisabled: -100))
    }

    func testSequentialLossAndRecoveryUsesCurrentWeakestSignal() {
        var policy = DeviceSetPolicy(uuids: [a, b], mode: .weakest, timeout: 10, now: 0)
        policy.record(-40, for: a, now: 0)
        policy.record(-40, for: b, now: 0)
        for _ in 0..<5 { policy.record(-90, for: b, now: 5) }
        XCTAssertTrue(policy.signal(at: 5).isAway(lockRSSI: -80, unlockRSSI: -60, lockDisabled: -100))
        for _ in 0..<5 { policy.record(-50, for: b, now: 9) }
        XCTAssertFalse(policy.signal(at: 9).isAway(lockRSSI: -80, unlockRSSI: -60, lockDisabled: -100))
        XCTAssertEqual(policy.signal(at: 10), .lost)
        XCTAssertTrue(policy.signal(at: 10).isAway(lockRSSI: -80, unlockRSSI: -60, lockDisabled: -100))
    }

    func testSequentialLossAndRecoveryUsesCurrentStrongestSignal() {
        var policy = DeviceSetPolicy(uuids: [a, b], mode: .strongest, timeout: 10, now: 0)
        policy.record(-40, for: a, now: 0)
        policy.record(-90, for: b, now: 5)
        policy.record(-50, for: b, now: 9)
        XCTAssertEqual(policy.signal(at: 10), .value(raw: -50, estimated: -70))
        XCTAssertFalse(policy.signal(at: 10).isAway(lockRSSI: -80, unlockRSSI: -60, lockDisabled: -100))
    }

    func testModeSwitchChangesAggregationWithoutLosingReadings() {
        var policy = DeviceSetPolicy(uuids: [a, b], mode: .weakest, timeout: 10, now: 0)
        policy.record(-45, for: a, now: 1)
        policy.record(-80, for: b, now: 2)
        XCTAssertEqual(policy.signal(at: 3), .value(raw: -80, estimated: -80))
        policy.mode = .strongest
        XCTAssertEqual(policy.signal(at: 3), .value(raw: -45, estimated: -45))
    }

    func testSelectionChangeRetainsExistingReadingsAndIgnoresRemovedDevice() {
        var policy = DeviceSetPolicy(uuids: [a], mode: .weakest, timeout: 10, now: 0)
        policy.record(-55, for: a, now: 1)
        policy.setSelected([a, b], now: 2)
        XCTAssertEqual(policy.signal(at: 2), .partial(raw: -55, estimated: -55, mode: .weakest))
        policy.record(-70, for: b, now: 3)
        XCTAssertEqual(policy.signal(at: 3), .value(raw: -70, estimated: -70))
        policy.setSelected([a], now: 4)
        policy.record(-99, for: b, now: 5)
        XCTAssertEqual(policy.signal(at: 5), .value(raw: -55, estimated: -55))
        policy.setSelected([], now: 6)
        XCTAssertEqual(policy.signal(at: 6), .waiting)
        XCTAssertTrue(policy.uuids.isEmpty)
    }

    func testThresholdsIncludeBoundaryAndLostIsAway() {
        let boundary = GroupSignal.value(raw: -60, estimated: -80)
        XCTAssertTrue(boundary.isClose(unlockRSSI: -60, lockRSSI: -80, unlockDisabled: 1))
        XCTAssertFalse(boundary.isAway(lockRSSI: -80, unlockRSSI: -60, lockDisabled: -100))
        XCTAssertFalse(GroupSignal.value(raw: -61, estimated: -81)
            .isClose(unlockRSSI: -60, lockRSSI: -80, unlockDisabled: 1))
        XCTAssertTrue(GroupSignal.value(raw: -61, estimated: -81)
            .isAway(lockRSSI: -80, unlockRSSI: -60, lockDisabled: -100))
        XCTAssertTrue(GroupSignal.lost.isAway(lockRSSI: -80, unlockRSSI: -60, lockDisabled: -100))
        XCTAssertFalse(GroupSignal.lost.isClose(unlockRSSI: -60, lockRSSI: -80, unlockDisabled: 1))
    }

    func testDisabledThresholdsUseTheOtherThreshold() {
        let signal = GroupSignal.value(raw: -70, estimated: -70)
        XCTAssertTrue(signal.isClose(unlockRSSI: 1, lockRSSI: -80, unlockDisabled: 1))
        XCTAssertTrue(signal.isAway(lockRSSI: -100, unlockRSSI: -60, lockDisabled: -100))
    }

    func testIncreasingTimeoutDoesNotReviveExpiredReadings() {
        var policy = DeviceSetPolicy(uuids: [a, b], mode: .weakest, timeout: 10, now: 0)
        policy.record(-40, for: a, now: 0)
        policy.record(-50, for: b, now: 5)
        XCTAssertEqual(policy.signal(at: 10), .lost)
        policy.setTimeout(30, now: 11)
        XCTAssertEqual(policy.signal(at: 11), .lost)
        policy.mode = .strongest
        XCTAssertEqual(policy.signal(at: 11), .value(raw: -50, estimated: -50))
        policy.record(-55, for: a, now: 12)
        policy.mode = .weakest
        XCTAssertEqual(policy.signal(at: 12), .value(raw: -55, estimated: -55))
    }

    func testIncreasingTimeoutBeforeExpiryExtendsExistingReading() {
        var policy = DeviceSetPolicy(uuids: [a], mode: .weakest, timeout: 10, now: 0)
        policy.record(-50, for: a, now: 0)
        policy.setTimeout(20, now: 9)
        XCTAssertEqual(policy.signal(at: 19.999), .value(raw: -50, estimated: -50))
        XCTAssertEqual(policy.signal(at: 20), .lost)
        policy.setTimeout(30, now: 20)
        XCTAssertEqual(policy.signal(at: 20), .lost)
        XCTAssertNil(policy.nextDeadline(after: 20))
    }

    func testIncreasingTimeoutDoesNotReviveUnseenDevice() {
        var policy = DeviceSetPolicy(uuids: [a, b], mode: .weakest, timeout: 10, now: 0)
        policy.record(-50, for: a, now: 5)
        policy.setTimeout(30, now: 10)
        XCTAssertEqual(policy.signal(at: 10), .lost)
        policy.record(-60, for: b, now: 11)
        XCTAssertEqual(policy.signal(at: 11), .value(raw: -60, estimated: -60))
    }

    func testSmoothingIsPerDeviceAndResetsAfterExpiry() {
        var policy = DeviceSetPolicy(uuids: [a, b], mode: .weakest, timeout: 10, now: 0)
        policy.record(-40, for: a, now: 0)
        policy.record(-70, for: a, now: 1)
        policy.record(-80, for: b, now: 1)
        XCTAssertEqual(policy.signal(at: 2), .value(raw: -80, estimated: -80))
        policy.record(-30, for: b, now: 12)
        policy.record(-50, for: a, now: 12)
        XCTAssertEqual(policy.signal(at: 12), .value(raw: -50, estimated: -50))
        policy.record(-90, for: a, now: 13)
        XCTAssertEqual(policy.signal(at: 13), .value(raw: -90, estimated: -70))
        policy.clearSmoothing()
        XCTAssertEqual(policy.signal(at: 13), .value(raw: -90, estimated: -90))
    }

    func testLegacyPreferenceMigrationAndPersistence() {
        let suite = "BLEUnlockTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(a.uuidString, forKey: "device")
        var settings = DeviceSetSettings.load(from: defaults)
        XCTAssertEqual(settings.uuids, [a])
        XCTAssertEqual(settings.mode, .weakest)
        settings.uuids.insert(b)
        settings.mode = .strongest
        settings.save(to: defaults)
        XCTAssertNil(defaults.string(forKey: "device"))
        XCTAssertEqual(DeviceSetSettings.load(from: defaults).uuids, [a, b])
        XCTAssertEqual(DeviceSetSettings.load(from: defaults).mode, .strongest)
        settings.uuids.removeAll()
        settings.save(to: defaults)
        XCTAssertTrue(DeviceSetSettings.load(from: defaults).uuids.isEmpty)
    }

    func testNewSelectionOverridesStaleLegacyPreference() {
        let suite = "BLEUnlockTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(a.uuidString, forKey: "device")
        defaults.set([b.uuidString, "invalid", b.uuidString], forKey: "devices")
        XCTAssertEqual(DeviceSetSettings.load(from: defaults).uuids, [b])
        defaults.set([String](), forKey: "devices")
        XCTAssertTrue(DeviceSetSettings.load(from: defaults).uuids.isEmpty)
    }
}
