// Deterministic regression tests using public, synthetic test data only.
// These tests construct CGEvents in memory and NEVER deliver any event.
// No Keychain access, permission requests, screen actions, or live-state reads.
//
// mkdir -p .build/tests/module-cache
// xcrun swiftc -swift-version 5 -module-cache-path .build/tests/module-cache \
//   BLEUnlock/ScreenLockState.swift BLEUnlock/UnlockKeyboard.swift tests/main.swift \
//   -o .build/tests/regression
// .build/tests/regression

import CoreGraphics
import Darwin
import Foundation

setbuf(stdout, nil)

var assertions = 0
var failures: [String] = []

func check(_ condition: @autoclosure () -> Bool, _ name: String) {
    assertions += 1
    if !condition() {
        failures.append(name)
        print("FAIL: \(name)")
    }
}

let testUserID: uid_t = 501

func session(legacy: Bool? = nil, userID: uid_t = testUserID,
             onConsole: Bool = true, loginDone: Bool = true) -> [String: Any] {
    var value: [String: Any] = [
        "kCGSSessionUserIDKey": NSNumber(value: userID),
        "kCGSSessionOnConsoleKey": NSNumber(value: onConsole),
        "kCGSessionLoginDoneKey": NSNumber(value: loginDone),
    ]
    if let legacy = legacy {
        value["CGSSessionScreenIsLocked"] = NSNumber(value: legacy)
    }
    return value
}

func evaluated(_ value: [String: Any]?, _ consoleLocked: Bool?) -> Bool? {
    ScreenLockState.evaluate(session: value, consoleLocked: consoleLocked, userID: testUserID)
}

// The missing private key must still permit the independently observed I/O
// console state, while uncertain identity/ownership must never permit input.
check(evaluated(session(legacy: true), nil) == true, "legacy locked")
check(evaluated(session(legacy: false), nil) == false, "legacy unlocked")
check(evaluated(session(), true) == true, "I/O fallback locked with missing legacy key")
check(evaluated(session(), false) == false, "I/O fallback unlocked with missing legacy key")
check(evaluated(session(), nil) == nil, "both lock sources unavailable remain unknown")
check(evaluated(session(legacy: true), true) == true, "matching locked observations")
check(evaluated(session(legacy: false), false) == false, "matching unlocked observations")
check(evaluated(session(legacy: true), false) == nil, "legacy locked conflicts with I/O unlocked")
check(evaluated(session(legacy: false), true) == nil, "legacy unlocked conflicts with I/O locked")
check(evaluated(nil, true) == nil, "missing session rejects global locked state")
check(evaluated(session(legacy: true, userID: 502), true) == nil, "different user rejects locked state")
check(evaluated(session(legacy: true, onConsole: false), true) == nil, "off-console session rejects locked state")
check(evaluated(session(legacy: true, loginDone: false), true) == nil, "incomplete login rejects locked state")

for key in ["kCGSSessionUserIDKey", "kCGSSessionOnConsoleKey", "kCGSessionLoginDoneKey"] {
    var missing = session(legacy: true)
    missing.removeValue(forKey: key)
    check(evaluated(missing, true) == nil, "missing ownership prerequisite: \(key)")
    var invalid = session(legacy: true)
    invalid[key] = "untrusted nonnumeric test value"
    check(evaluated(invalid, true) == nil, "invalid ownership prerequisite: \(key)")
}
print("Completed lock-state decision cases.")

func isHighSurrogate(_ unit: UniChar) -> Bool {
    (0xD800...0xDBFF).contains(unit)
}

func isLowSurrogate(_ unit: UniChar) -> Bool {
    (0xDC00...0xDFFF).contains(unit)
}

func isWellFormedUTF16(_ units: [UniChar]) -> Bool {
    var index = 0
    while index < units.count {
        if isHighSurrogate(units[index]) {
            guard index + 1 < units.count, isLowSurrogate(units[index + 1]) else { return false }
            index += 2
        } else {
            guard !isLowSurrogate(units[index]) else { return false }
            index += 1
        }
    }
    return true
}

let boundaryText = String(repeating: "a", count: 19) + "😀z"
let longText = String(repeating: "Pass-🚀-e\u{301}-测试-", count: 50)
let unicodeCases: [(String, String)] = [
    ("empty", ""),
    ("ASCII", "synthetic-test-data"),
    ("nineteen ASCII units then surrogate pair", boundaryText),
    ("twenty ASCII units then surrogate pair", String(repeating: "a", count: 20) + "😀"),
    ("supplementary scalars", String(repeating: "🚀", count: 25)),
    ("long mixed Unicode", longText),
]

for (name, text) in unicodeCases {
    let chunks = UnlockKeyboard.unicodeChunks(text)
    check(chunks.flatMap { $0 } == Array(text.utf16), "UTF-16 content preserved: \(name)")
    check(chunks.allSatisfy { !$0.isEmpty && $0.count <= 20 }, "nonempty bounded chunks: \(name)")
    check(chunks.allSatisfy(isWellFormedUTF16), "surrogate pairs remain intact: \(name)")
    check(chunks.allSatisfy {
        $0.first.map { !isLowSurrogate($0) } == true &&
        $0.last.map { !isHighSurrogate($0) } == true
    }, "safe UTF-16 chunk boundaries: \(name)")
}
check(UnlockKeyboard.unicodeChunks("").isEmpty, "empty input produces no Unicode chunks")
check(UnlockKeyboard.unicodeChunks(boundaryText).map { $0.count } == [19, 3],
      "nineteen-unit boundary keeps the emoji in the following chunk")
print("Completed Unicode chunk cases, including long mixed text.")

func unicodeInEvent(_ event: CGEvent) -> [UniChar] {
    var count = 0
    event.keyboardGetUnicodeString(maxStringLength: 0, actualStringLength: &count, unicodeString: nil)
    guard count > 0 else { return [] }
    var units = [UniChar](repeating: 0, count: count)
    var actualCount = 0
    units.withUnsafeMutableBufferPointer { buffer in
        event.keyboardGetUnicodeString(maxStringLength: buffer.count,
                                       actualStringLength: &actualCount,
                                       unicodeString: buffer.baseAddress!)
    }
    check(actualCount == count, "event Unicode length is consistent")
    return units
}

check(UnlockKeyboard.returnKeyCode == CGKeyCode(0x24), "Return uses hardware keycode 0x24")
var deliveryFixture: [CGEvent]?
for (name, text) in [("ASCII", "synthetic-test-data"), ("surrogate boundary", boundaryText)] {
    do {
        print("Constructing in-memory events for \(name); no delivery.")
        let chunks = UnlockKeyboard.unicodeChunks(text)
        let events = try UnlockKeyboard.events(for: text)
        if name == "surrogate boundary" { deliveryFixture = events }
        check(events.count == chunks.count * 2 + 2, "one pair per Unicode chunk plus Return pair: \(name)")
        guard events.count == chunks.count * 2 + 2 else { continue }
        check(events.allSatisfy { $0.flags.rawValue == 0 }, "modifier flags cleared: \(name)")
        for (index, chunk) in chunks.enumerated() {
            let down = events[index * 2]
            let up = events[index * 2 + 1]
            check(down.type == .keyDown && up.type == .keyUp, "text pair types: \(name) chunk \(index)")
            check(unicodeInEvent(down) == chunk, "key-down Unicode round trip: \(name) chunk \(index)")
            check(unicodeInEvent(up) == chunk, "key-up Unicode round trip: \(name) chunk \(index)")
        }
        let returnDown = events[events.count - 2]
        let returnUp = events[events.count - 1]
        check(returnDown.type == .keyDown && returnUp.type == .keyUp, "Return pair types: \(name)")
        check(returnDown.getIntegerValueField(.keyboardEventKeycode) == 0x24 &&
              returnUp.getIntegerValueField(.keyboardEventKeycode) == 0x24,
              "both Return events use 0x24: \(name)")
    } catch {
        check(false, "event construction failed for synthetic case: \(name): \(error)")
    }
}

if let events = deliveryFixture {
    var locked = true
    var timeline: [String] = []
    var posted: [CGEvent] = []
    let delivered = UnlockKeyboard.deliver(events, canContinue: { locked }, willSubmit: {
        timeline.append("will-submit")
    }, post: { event in
        // Mock sink: store references only. Never invoke CGEvent.post.
        posted.append(event)
        if event.getIntegerValueField(.keyboardEventKeycode) == 0x24 && event.type == .keyDown {
            timeline.append("return-down")
            locked = false // Simulate an immediate unlock on Return key-down.
        } else if event.getIntegerValueField(.keyboardEventKeycode) == 0x24 && event.type == .keyUp {
            timeline.append("return-up")
        }
    })
    check(delivered, "Return key-up completes after immediate unlock on key-down")
    check(posted.count == events.count, "mock receives every event including final Return release")
    check(timeline == ["will-submit", "return-down", "return-up"],
          "submission marker precedes Return key-down and key-up still follows")
    check(posted.last?.type == .keyUp &&
          posted.last?.getIntegerValueField(.keyboardEventKeycode) == 0x24,
          "last delivered mock event releases Return")

    var permitNextPair = true
    var canceledPosts: [CGEvent] = []
    var submissionMarked = false
    let canceled = UnlockKeyboard.deliver(events, canContinue: { permitNextPair }, willSubmit: {
        submissionMarked = true
    }, post: { event in
        canceledPosts.append(event)
        permitNextPair = false // Cancellation during a pair must still release its key.
    })
    check(!canceled, "cancellation stops before the next key pair")
    check(canceledPosts.count == 2, "cancellation preserves one complete key pair")
    check(canceledPosts.first?.type == .keyDown && canceledPosts.last?.type == .keyUp,
          "cancellation leaves no pressed key without a release")
    check(canceledPosts.allSatisfy { $0.getIntegerValueField(.keyboardEventKeycode) != 0x24 },
          "cancellation before submission delivers no Return event")
    check(!submissionMarked, "cancellation does not mark submission")

    var rejectedPosts = 0
    var rejectedSubmission = false
    let rejected = UnlockKeyboard.deliver(events, canContinue: { false }, willSubmit: {
        rejectedSubmission = true
    }, post: { _ in rejectedPosts += 1 })
    check(!rejected && rejectedPosts == 0 && !rejectedSubmission,
          "canceled initial guard rejects all input and submission")
} else {
    check(false, "event fixture is required for mock delivery regression cases")
}

do {
    _ = try UnlockKeyboard.events(for: "")
    check(false, "empty password must fail before event construction")
} catch UnlockKeyboard.InputError.emptyPassword {
    check(true, "empty password produces the specific emptyPassword error")
} catch {
    check(false, "empty password produced the wrong error")
}

if failures.isEmpty {
    print("PASS: \(assertions) assertions; no events delivered or live lock state accessed.")
} else {
    print("FAILED: \(failures.count) of \(assertions) assertions.")
    exit(1)
}
