import Foundation

var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    guard condition() else { fatalError(message) }
}
func observe(_ evidence: inout ProximityEvidence, _ rssi: Int, _ time: Double) {
    evidence.observe(rssi: rssi, now: time, unlockRSSI: -67, lockRSSI: -85)
}
func lock(_ evidence: [ProximityEvidence], at time: Double, idle: Double,
          all: Bool = true) -> ProximityLockReason? {
    AutomaticLockSafety.reason(evidence: evidence, requireAllAway: all,
                              now: time, idleSeconds: idle, awayDelay: 10, signalTimeout: 120,
                              lockOnSignalLoss: false, protectWhileActive: true)
}

// A phone sleeping on the desk stops advertising; an active worker must stay unlocked.
var desk = ProximityEvidence()
for t in 0...5 { observe(&desk, -64, Double(t)) }
check(desk.isStablyClose(now: 5), "Sustained nearby phone must qualify for unlock")
check(lock([desk], at: 15, idle: 15) == nil, "Ten seconds of silence must not lock")
check(lock([desk], at: 124, idle: 124) == nil, "Brief phone sleep is not departure")
check(lock([desk], at: 126, idle: 1) == nil, "Typing must suppress even a prolonged dropout")
check(lock([desk], at: 126, idle: 120) == nil, "Phone screen-off silence must not lock even while the Mac is idle")
desk.expireSignal()
check(lock([desk], at: 126, idle: 120) == nil, "Signal-expiry cleanup must not turn phone sleep into departure")
check(!desk.isStablyClose(now: 126), "Expired data must never unlock")

// Even extended phone sleep, invalid readings, and sparse wakeups cannot lock the Mac.
for time in [300.0, 1800.0, 86400.0] {
    check(lock([desk], at: time, idle: time) == nil, "Phone silence must never impose a Mac lock deadline")
}
var sleeping = ProximityEvidence()
for t in 0...5 { observe(&sleeping, -64, Double(t)) }
for t in 6...140 { _ = sleeping.observe(rssi: 0, now: Double(t), unlockRSSI: -67, lockRSSI: -85) }
check(lock([sleeping], at: 140, idle: 140) == nil, "Invalid readings during phone sleep must not lock")
observe(&sleeping, -64, 150)
check(lock([sleeping], at: 150, idle: 150) == nil, "A nearby wakeup must remain unlocked")
check(!sleeping.isStablyClose(now: 150), "A wakeup still needs fresh unlock confirmation")

// Real departure needs ten seconds of continuous weak observations and keyboard/mouse idle.
var away = ProximityEvidence()
for t in 0...9 { observe(&away, -92, Double(t)) }
check(lock([away], at: 9, idle: 30) == nil, "Weak signal must persist for the full delay")
observe(&away, -92, 10)
check(lock([away], at: 10, idle: 10) == .away, "Confirmed distance should lock after ten seconds")
check(lock([away], at: 10, idle: 0) == nil, "Working at the Mac must suppress distance-based locking")

// A weak observation followed by silence cannot run the distance timer to completion.
var weakThenSilent = ProximityEvidence()
for t in 0...3 { observe(&weakThenSilent, -92, Double(t)) }
check(!weakThenSilent.isWeak(now: 10, delay: 10), "Stale weak evidence must cancel the distance timer")
check(lock([weakThenSilent], at: 10, idle: 30) == nil, "Silence must not be interpreted as continued distance")

// A single high spike cannot instantly unlock; a single low spike cannot lock.
observe(&away, -60, 11)
check(!away.isStablyClose(now: 11), "A strong outlier must not unlock")
var nearby = ProximityEvidence()
for t in 0...5 { observe(&nearby, -64, Double(t)) }
observe(&nearby, -105, 6)
check(nearby.filteredRSSI == -64, "Median filtering must reject an isolated weak spike")
check(lock([nearby], at: 6, idle: 60) == nil, "Isolated attenuation must not lock")
check(nearby.isStablyClose(now: 6), "One weak outlier must not cancel confirmed proximity or pending password entry")
for t in 7...10 { observe(&nearby, -64, Double(t)) }
check(nearby.isStablyClose(now: 10), "Stable recovery must restore unlock eligibility")

// No cached or invalid data may authorize a new unlock or manufacture a distant phone.
check(!nearby.isStablyClose(now: 16), "Cached proximity must expire")
observe(&nearby, -64, 17)
check(!nearby.isStablyClose(now: 17), "A gap must restart close confirmation")
for t in 18...20 { observe(&nearby, -64, Double(t)) }
check(nearby.isStablyClose(now: 20), "Fresh close samples must confirm proximity again")
let timestamp = nearby.lastSampleAt
for rssi in [0, 1, 127, -127] {
    check(!nearby.observe(rssi: rssi, now: 21, unlockRSSI: -67, lockRSSI: -85), "Invalid RSSI must be rejected")
}
check(nearby.lastSampleAt == timestamp, "Invalid samples must not refresh the last valid time")
check(!nearby.isStablyClose(now: 26), "Delayed unlock must fail after evidence goes stale")
check(lock([ProximityEvidence()], at: 500, idle: 500) == nil, "Never-seen devices must not manufacture absence")
check(lock([], at: 500, idle: 500) == nil, "No selected device must not lock")

// Recovery into the hysteresis band cancels locking without authorizing unlocking.
for t in 12...17 { observe(&away, -76, Double(t)) }
check(lock([away], at: 17, idle: 30) == nil, "Recovered signal must cancel pending lock")
check(!away.isStablyClose(now: 17), "Intermediate RSSI must not authorize unlocking")

// Multiple monitored devices retain any/all departure semantics.
var distant = ProximityEvidence()
var close = ProximityEvidence()
for t in 115...126 {
    observe(&distant, -92, Double(t))
    observe(&close, -64, Double(t))
}
check(lock([distant, close], at: 126, idle: 20) == nil, "All-away mode must retain a nearby device")
check(lock([distant, close], at: 126, idle: 20, all: false) == .away, "Any-away mode must retain its semantics")
check(lock([distant, desk], at: 126, idle: 20) == nil, "All-away mode needs measured distance for every monitored device")
check(lock([distant, desk], at: 126, idle: 120) == nil, "A silent device must not count as confirmed departure in all-away mode")
check(lock([distant, desk], at: 126, idle: 20, all: false) == .away, "Measured departure is sufficient in any-away mode")

// Returning to the desk should qualify quickly, without accepting a single spike.
var arrival = ProximityEvidence()
observe(&arrival, -64, 0)
check(!arrival.isStablyClose(now: 0), "One nearby sample must not unlock")
observe(&arrival, -64, 0.3)
check(!arrival.isStablyClose(now: 0.3), "A short advertising burst must not unlock")
observe(&arrival, -64, 0.6)
check(arrival.isStablyClose(now: 0.6), "A nearby phone must qualify after 0.6 seconds")
var spike = ProximityEvidence()
observe(&spike, -60, 0)
observe(&spike, -90, 0.7)
check(!spike.isStablyClose(now: 0.7), "One high sample followed by a weak sample must not unlock")
var sparseArrival = ProximityEvidence()
observe(&sparseArrival, -64, 0)
observe(&sparseArrival, -64, 1)
check(sparseArrival.isStablyClose(now: 1), "Two spaced close samples must suffice")
for (index, rssi) in [-68, -69, -68, -72, -69, -68, -72, -69].enumerated() {
    arrival.observe(rssi: rssi, now: Double(index) + 1, unlockRSSI: -70, lockRSSI: -85)
    check(arrival.isStablyClose(now: Double(index) + 1), "Small fluctuations around the tuned threshold must not starve unlock")
}
for t in 10...14 { observe(&arrival, -78, Double(t)) }
check(!arrival.isStablyClose(now: 14), "Sustained movement beyond the unlock threshold must cancel eligibility")

// Upstream defaults retain signal-loss locking without enabling activity protection.
let legacy = AutomaticLockSafety.reason(evidence: [desk], requireAllAway: true,
                                       now: 126, idleSeconds: 0, awayDelay: 10, signalTimeout: 120)
check(legacy == .lost, "Default policy must preserve existing signal-loss locking")
check(AutomaticLockSafety.reason(evidence: [desk], requireAllAway: true,
                                now: 126, idleSeconds: 0, awayDelay: 10, signalTimeout: 120,
                                protectWhileActive: true) == nil, "Activity protection must be opt-in")
check(AutomaticLockSafety.reason(evidence: [desk], requireAllAway: true,
                                now: 126, idleSeconds: 120, awayDelay: 10, signalTimeout: 120,
                                protectWhileActive: true) == .lost, "Activity protection must eventually allow default loss locking")
check(AutomaticLockSafety.reason(evidence: [distant], requireAllAway: true,
                                now: 126, idleSeconds: 0, awayDelay: 10, signalTimeout: 120) == .away,
      "Default measured-distance locking must not require keyboard idle")
check(AutomaticLockSafety.reason(evidence: [distant, desk], requireAllAway: true,
                                now: 126, idleSeconds: 0, awayDelay: 10, signalTimeout: 120) == .lost,
      "Default all-away policy must retain lost devices as departure evidence")
let neverSeen = ProximityEvidence(startedAt: 0)
check(!neverSeen.isStablyClose(now: 120), "Startup state must never authorize an unlock")
check(AutomaticLockSafety.reason(evidence: [neverSeen], requireAllAway: true,
                                now: 120, idleSeconds: 0, awayDelay: 10, signalTimeout: 120) == .lost,
      "Default timeout must still apply to a monitored device never seen after startup")
check(AutomaticLockSafety.reason(evidence: [neverSeen], requireAllAway: true,
                                now: 120, idleSeconds: 120, awayDelay: 10, signalTimeout: 120,
                                lockOnSignalLoss: false) == nil,
      "Opting out of signal-loss locking must also cover startup timeouts")

print("Passed \(checks) proximity and activity-safety checks")
