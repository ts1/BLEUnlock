import Foundation

var failures = 0
func check(_ cond: Bool, _ msg: String) {
    if cond { print("ok   - \(msg)") } else { print("FAIL - \(msg)"); failures += 1 }
}

let routeOut = """
   route to: default
destination: default
       mask: default
    gateway: 10.0.0.1
  interface: en0
      flags: <UP,GATEWAY,DONE,STATIC,PRCLONING>
"""
check(parseDefaultGatewayIP(routeOutput: routeOut) == "10.0.0.1", "parse gateway IP from route output")
check(parseDefaultGatewayIP(routeOutput: "no default route\n") == nil, "no gateway line -> nil")

// macOS `arp` prints octets WITHOUT leading zeros; normalise so allowlist matches.
check(normalizeMAC("a4:2b:8c:1:2:3") == "a4:2b:8c:01:02:03", "pad single-digit octets")
check(normalizeMAC("A4:2B:8C:01:02:03") == "a4:2b:8c:01:02:03", "lower-case octets")
check(normalizeMAC("a4:2b:8c:1:2") == nil, "five octets -> nil")
check(normalizeMAC("zz:2b:8c:1:2:3") == nil, "non-hex octet -> nil")
// Hardening: Swift's Int(_:radix:) accepts a leading sign, so without a hex-alphabet
// guard "-1"/"+a" would slip through and yield a malformed (non-nil) MAC.
check(normalizeMAC("-1:2b:8c:1:2:3") == nil, "sign-prefixed octet -> nil")
check(normalizeMAC("+a:2b:8c:1:2:3") == nil, "plus-prefixed octet -> nil")

let arpOut = "? (10.0.0.1) at a4:2b:8c:1:2:3 on en0 ifscope [ethernet]"
check(parseGatewayMAC(arpOutput: arpOut) == "a4:2b:8c:01:02:03", "parse + normalise MAC from arp output")
check(parseGatewayMAC(arpOutput: "? (10.0.0.1) at (incomplete) on en0 ifscope [ethernet]") == nil, "incomplete arp entry -> nil")

let allow: Set<String> = ["a4:2b:8c:01:02:03"]
check(computePauseState(resolvedMAC: "a4:2b:8c:01:02:03", allowlist: allow, previous: false) == true, "MAC in allowlist -> paused")
check(computePauseState(resolvedMAC: "ff:ff:ff:ff:ff:ff", allowlist: allow, previous: true) == false, "MAC not in allowlist -> active")
check(computePauseState(resolvedMAC: nil, allowlist: allow, previous: true) == true, "nil keeps previous state (sticky true)")
check(computePauseState(resolvedMAC: nil, allowlist: allow, previous: false) == false, "nil keeps previous state (sticky false)")

if failures == 0 { print("\nALL PASS") } else { print("\n\(failures) FAILURE(S)"); exit(1) }
