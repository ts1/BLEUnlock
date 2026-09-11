import Darwin
import Foundation

private struct TestFailure: Error, CustomStringConvertible {
    let message: String

    var description: String { message }
}

private struct PresenceEvent: Equatable {
    let presence: Bool
    let reason: String
}

private final class DelegateRecorder: BLEDelegate {
    var presenceEvents: [PresenceEvent] = []
    var rssiUpdates: [Int?] = []

    func newDevice(device: Device) {}
    func updateDevice(device: Device) {}
    func removeDevice(device: Device) {}
    func bluetoothPowerWarn() {}

    func updateRSSI(rssi: Int?, active: Bool) {
        rssiUpdates.append(rssi)
    }

    func updatePresence(presence: Bool, reason: String) {
        presenceEvents.append(PresenceEvent(presence: presence, reason: reason))
    }
}

private var failureCount = 0

private func expect(
    _ condition: @autoclosure () -> Bool,
    _ message: String
) throws {
    guard condition() else { throw TestFailure(message: message) }
}

private func require<T>(_ value: T?, _ message: String) throws -> T {
    guard let value = value else { throw TestFailure(message: message) }
    return value
}

private func run(_ name: String, _ body: () throws -> Void) {
    do {
        try body()
        print("[PASS] \(name)")
    } catch {
        failureCount += 1
        print("[FAIL] \(name): \(error)")
    }
}

private func makeBLE(
    selected: Bool = true,
    presence: Bool = false,
    latestN: Int = 1
) -> (BLE, DelegateRecorder) {
    let ble = BLE(centralManager: nil)
    ble.monitoredUUID = selected ? UUID() : nil
    ble.presence = presence
    ble.latestN = latestN
    ble.proximityTimeout = 3_600
    ble.signalTimeout = 3_600
    let recorder = DelegateRecorder()
    ble.delegate = recorder
    return (ble, recorder)
}

private func stopTimers(_ ble: BLE) {
    ble.proximityTimer?.invalidate()
    ble.signalTimer?.invalidate()
    ble.activeModeTimer?.invalidate()
    ble.connectionTimer?.invalidate()
}

run("battery-only policy is disabled by default for every power state") {
    let sources: [(String, PowerSource)] = [
        ("battery", .battery),
        ("external", .external),
        ("unknown", .unknown),
    ]

    for (name, source) in sources {
        try expect(
            !PowerSourceMonitor.shouldPauseAutomaticLock(batteryOnly: false, source: source),
            "default policy unexpectedly paused automatic locking on \(name) power"
        )
    }
}

run("enabled battery-only policy pauses only on external power") {
    try expect(
        !PowerSourceMonitor.shouldPauseAutomaticLock(batteryOnly: true, source: .battery),
        "battery power should allow automatic locking"
    )
    try expect(
        PowerSourceMonitor.shouldPauseAutomaticLock(batteryOnly: true, source: .external),
        "external power should pause automatic locking"
    )
    try expect(
        !PowerSourceMonitor.shouldPauseAutomaticLock(batteryOnly: true, source: .unknown),
        "unknown power should fail open to ordinary automatic locking"
    )
}

run("automatic lock gate follows power policy and disabled Lock RSSI") {
    let (ble, _) = makeBLE(selected: false)
    defer { stopTimers(ble) }

    ble.setAutomaticLockPaused(
        PowerSourceMonitor.shouldPauseAutomaticLock(batteryOnly: true, source: .battery)
    )
    try expect(ble.automaticLockEnabled, "battery power should enable the automatic lock gate")

    ble.setAutomaticLockPaused(
        PowerSourceMonitor.shouldPauseAutomaticLock(batteryOnly: true, source: .external)
    )
    try expect(!ble.automaticLockEnabled, "external power should disable the automatic lock gate")

    ble.setAutomaticLockPaused(
        PowerSourceMonitor.shouldPauseAutomaticLock(batteryOnly: true, source: .unknown)
    )
    try expect(ble.automaticLockEnabled, "unknown power should enable the automatic lock gate")

    ble.lockRSSI = ble.LOCK_DISABLED
    try expect(!ble.automaticLockEnabled, "disabled Lock RSSI should disable the automatic lock gate")
}

run("resume while absent permits a fresh low-RSSI away timer") {
    let (ble, recorder) = makeBLE(presence: false)
    defer { stopTimers(ble) }

    ble.setAutomaticLockPaused(true)
    ble.setAutomaticLockPaused(false)
    ble.updateMonitoredPeripheral(-90)

    let timer = try require(ble.proximityTimer, "weak RSSI did not arm Delay to Lock after resume")
    timer.fire()
    try expect(
        recorder.presenceEvents == [PresenceEvent(presence: false, reason: "away")],
        "fresh Delay to Lock did not emit the expected away transition"
    )
}

run("resume while absent permits a fresh no-signal timeout") {
    let (ble, recorder) = makeBLE(presence: false)
    defer { stopTimers(ble) }

    ble.setAutomaticLockPaused(true)
    ble.setAutomaticLockPaused(false)

    let timer = try require(ble.signalTimer, "resume did not arm No-Signal Timeout")
    timer.fire()
    try expect(
        recorder.presenceEvents == [PresenceEvent(presence: false, reason: "lost")],
        "fresh No-Signal Timeout did not emit the expected lost transition"
    )
}

run("resume does not synthesize presence or arrival") {
    let (ble, recorder) = makeBLE(presence: false)
    defer { stopTimers(ble) }

    ble.setAutomaticLockPaused(true)
    ble.setAutomaticLockPaused(false)

    try expect(recorder.presenceEvents.isEmpty, "resume emitted a synthetic presence transition")
    try expect(!ble.presence, "resume changed the stored presence state")
}

run("unchanged power notifications do not reset active timers") {
    let (ble, _) = makeBLE(presence: true)
    defer { stopTimers(ble) }

    ble.updateMonitoredPeripheral(-90)
    let runningAway = try require(ble.proximityTimer, "test setup did not arm Delay to Lock")
    let runningSignal = try require(ble.signalTimer, "test setup did not arm No-Signal Timeout")

    ble.setAutomaticLockPaused(false)
    try expect(
        ble.proximityTimer.map { $0 === runningAway } == true,
        "unchanged unpaused policy replaced Delay to Lock"
    )
    try expect(
        ble.signalTimer.map { $0 === runningSignal } == true,
        "unchanged unpaused policy replaced No-Signal Timeout"
    )

    ble.setAutomaticLockPaused(true)
    let pausedAway = try require(ble.proximityTimer, "pausing unexpectedly removed Delay to Lock")
    let pausedSignal = try require(ble.signalTimer, "pausing unexpectedly removed No-Signal Timeout")
    ble.setAutomaticLockPaused(true)
    try expect(
        ble.proximityTimer.map { $0 === pausedAway } == true,
        "unchanged paused policy replaced Delay to Lock"
    )
    try expect(
        ble.signalTimer.map { $0 === pausedSignal } == true,
        "unchanged paused policy replaced No-Signal Timeout"
    )
}

run("resume clears smoothing and starts fresh timers") {
    let (ble, recorder) = makeBLE(presence: true)
    defer { stopTimers(ble) }

    ble.updateMonitoredPeripheral(-90)
    let staleAway = try require(ble.proximityTimer, "test setup did not arm the old Delay to Lock")
    let staleSignal = try require(ble.signalTimer, "test setup did not arm the old No-Signal Timeout")
    ble.latestN = 5
    ble.latestRSSIs = Array(repeating: -30, count: 5)

    ble.setAutomaticLockPaused(true)
    ble.setAutomaticLockPaused(false)

    try expect(ble.latestRSSIs.isEmpty, "resume retained stale RSSI smoothing samples")
    try expect(ble.proximityTimer == nil, "resume retained the old Delay to Lock")
    try expect(!staleAway.isValid, "resume did not invalidate the old Delay to Lock")
    let freshSignal = try require(ble.signalTimer, "resume did not start a fresh No-Signal Timeout")
    try expect(freshSignal !== staleSignal, "resume reused the old No-Signal Timeout")
    try expect(!staleSignal.isValid, "resume did not invalidate the old No-Signal Timeout")
    try expect(recorder.presenceEvents.isEmpty, "timer reset emitted a presence transition")

    ble.updateMonitoredPeripheral(-90)
    try expect(ble.latestRSSIs == [-90], "first post-resume RSSI was mixed with stale samples")
    let freshAway = try require(ble.proximityTimer, "fresh weak RSSI did not arm Delay to Lock")
    try expect(freshAway !== staleAway, "resume reused the old Delay to Lock")
    freshAway.fire()
    try expect(
        recorder.presenceEvents == [PresenceEvent(presence: false, reason: "away")],
        "fresh Delay to Lock did not complete normally"
    )
}

run("close RSSI cancels a pending away transition") {
    let (ble, recorder) = makeBLE(presence: true)
    defer { stopTimers(ble) }

    ble.updateMonitoredPeripheral(-90)
    let pending = try require(ble.proximityTimer, "weak RSSI did not arm Delay to Lock")
    ble.updateMonitoredPeripheral(-50)

    try expect(ble.proximityTimer == nil, "close RSSI did not clear Delay to Lock")
    try expect(!pending.isValid, "close RSSI did not invalidate Delay to Lock")
    pending.fire()
    try expect(recorder.presenceEvents.isEmpty, "canceled Delay to Lock still emitted away")
}

run("post-resume mid-band RSSI cancels away timer and later weak RSSI re-arms it") {
    let (ble, recorder) = makeBLE(presence: false)
    defer { stopTimers(ble) }

    ble.lockRSSI = -80
    ble.unlockRSSI = -60
    ble.setAutomaticLockPaused(true)
    ble.setAutomaticLockPaused(false)
    ble.updateMonitoredPeripheral(-90)
    let first = try require(ble.proximityTimer, "weak RSSI did not arm Delay to Lock")

    ble.updateMonitoredPeripheral(-70)
    try expect(ble.proximityTimer == nil, "mid-band RSSI did not cancel Delay to Lock")
    try expect(!first.isValid, "mid-band RSSI did not invalidate Delay to Lock")
    first.fire()
    try expect(recorder.presenceEvents.isEmpty, "canceled mid-band timer emitted away")

    ble.updateMonitoredPeripheral(-90)
    let second = try require(ble.proximityTimer, "later weak RSSI did not re-arm Delay to Lock")
    try expect(second !== first, "later weak RSSI reused the canceled timer")
    second.fire()
    try expect(
        recorder.presenceEvents == [PresenceEvent(presence: false, reason: "away")],
        "re-armed Delay to Lock did not emit away"
    )
}

run("automatic unlock presence transitions remain active on external power") {
    let (ble, recorder) = makeBLE(presence: false)
    defer { stopTimers(ble) }

    ble.setAutomaticLockPaused(true)
    try expect(!ble.automaticLockEnabled, "test setup did not model the external-power gate")
    ble.updateMonitoredPeripheral(-50)

    try expect(ble.presence, "close RSSI did not restore presence while locking was paused")
    try expect(
        recorder.presenceEvents == [PresenceEvent(presence: true, reason: "close")],
        "close RSSI did not emit the normal unlock presence transition"
    )
}

run("explicitly disabled Lock RSSI survives pause and resume") {
    let (ble, _) = makeBLE()
    defer { stopTimers(ble) }

    ble.lockRSSI = ble.LOCK_DISABLED
    ble.setAutomaticLockPaused(true)
    ble.setAutomaticLockPaused(false)

    try expect(ble.lockRSSI == ble.LOCK_DISABLED, "pause/resume changed disabled Lock RSSI")
    try expect(!ble.automaticLockEnabled, "disabled Lock RSSI unexpectedly enabled automatic locking")
}

run("resume without a selected device starts no timers") {
    let (ble, recorder) = makeBLE(selected: false, presence: false)
    defer { stopTimers(ble) }

    ble.setAutomaticLockPaused(true)
    ble.setAutomaticLockPaused(false)

    try expect(ble.proximityTimer == nil, "resume armed Delay to Lock without a selected device")
    try expect(ble.signalTimer == nil, "resume armed No-Signal Timeout without a selected device")
    try expect(recorder.presenceEvents.isEmpty, "resume emitted presence without a selected device")
}

if failureCount == 0 {
    print("All power source regression tests passed.")
} else {
    print("\(failureCount) power source regression test(s) failed.")
    Darwin.exit(1)
}
