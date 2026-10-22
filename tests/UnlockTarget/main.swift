import Foundation

var count = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    count += 1
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

let classic = SystemUnlockTarget.Kind.classic
let sso = SystemUnlockTarget.Kind.platformSSO
check(SystemUnlockTarget.kind(bundleIdentifier: classic.bundleIdentifier,
                              resolvedExecutablePath: classic.executablePath) == .classic, "classic identity")
check(SystemUnlockTarget.kind(bundleIdentifier: sso.bundleIdentifier,
                              resolvedExecutablePath: sso.executablePath) == .platformSSO, "SSO identity")
check(SystemUnlockTarget.kind(bundleIdentifier: classic.bundleIdentifier,
                              resolvedExecutablePath: sso.executablePath) == nil, "mismatched pair")
check(SystemUnlockTarget.kind(bundleIdentifier: sso.bundleIdentifier,
                              resolvedExecutablePath: classic.executablePath) == nil, "reverse mismatch")
check(SystemUnlockTarget.kind(bundleIdentifier: nil, resolvedExecutablePath: classic.executablePath) == nil, "missing ID")
check(SystemUnlockTarget.kind(bundleIdentifier: sso.bundleIdentifier, resolvedExecutablePath: nil) == nil, "missing path")
check(SystemUnlockTarget.kind(bundleIdentifier: sso.bundleIdentifier + ".fake",
                              resolvedExecutablePath: sso.executablePath) == nil, "identifier prefix spoof")
check(SystemUnlockTarget.kind(bundleIdentifier: sso.bundleIdentifier,
                              resolvedExecutablePath: sso.executablePath + ".fake") == nil, "path prefix spoof")
check(SystemUnlockTarget.kind(bundleIdentifier: sso.bundleIdentifier,
                              resolvedExecutablePath: "/tmp/PlatformSSOUIAgent") == nil, "user-writable executable")
check(SystemUnlockTarget.kind(bundleIdentifier: "com.example.app",
                              resolvedExecutablePath: classic.executablePath) == nil, "unrelated ID")
check(SystemUnlockTarget.isSecureTextRole(role: "AXTextField", subrole: "AXSecureTextField"), "secure text field")
check(!SystemUnlockTarget.isSecureTextRole(role: "AXTextField", subrole: nil), "unknown subrole")
check(!SystemUnlockTarget.isSecureTextRole(role: nil, subrole: "AXSecureTextField"), "unknown role")
check(!SystemUnlockTarget.isSecureTextRole(role: "AXTextField", subrole: "AXTextField"), "plain text field")
check(!SystemUnlockTarget.isSecureTextRole(role: "AXWebArea", subrole: "AXSecureTextField"), "web role rejected")
check(!SystemUnlockTarget.isSecureTextRole(role: "AXGroup", subrole: "AXSecureTextField"), "group rejected")
print("PASS: \(count) target policy assertions; no running app, AX or input queried.")
