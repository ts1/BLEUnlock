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
        XCTAssertEqual(policy.signal(at: 9.999), .waiting)
        XCTAssertFalse(policy.signal(at: 9.999).isAway(lockRSSI: -80, unlockRSSI: -60, lockDisabled: -100))
        XCTAssertEqual(policy.signal(at: 10), .lost)
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
        XCTAssertEqual(policy.signal(at: 2), .waiting)
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
