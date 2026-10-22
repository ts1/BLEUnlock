import AppKit
import ApplicationServices
import Foundation
import Security

// Identifies an existing native system credential UI. This helper never reads
// credential/UI content, requests permission, changes focus, or delivers input.
struct SystemUnlockTarget {
    enum Kind: String {
        case classic = "classic-loginwindow"
        case platformSSO = "platform-sso"

        var bundleIdentifier: String {
            switch self {
            case .classic: return "com.apple.loginwindow"
            case .platformSSO: return "com.apple.PlatformSSO.PlatformSSOUIAgent"
            }
        }

        var executablePath: String {
            switch self {
            case .classic:
                return "/System/Library/CoreServices/loginwindow.app/Contents/MacOS/loginwindow"
            case .platformSSO:
                return "/System/Library/PrivateFrameworks/PlatformSSO.framework/Support/PlatformSSOUIAgent.app/Contents/MacOS/PlatformSSOUIAgent"
            }
        }
    }

    let application: NSRunningApplication
    private let kind: Kind
    private let secureFocus: AXUIElement?

    var processIdentifier: pid_t { application.processIdentifier }
    var isPlatformSSO: Bool { kind == .platformSSO }

    // Pure policy entry points also allow tests without querying running apps.
    static func kind(bundleIdentifier: String?, resolvedExecutablePath: String?) -> Kind? {
        for candidate in [Kind.classic, .platformSSO] {
            if bundleIdentifier == candidate.bundleIdentifier && resolvedExecutablePath == candidate.executablePath {
                return candidate
            }
        }
        return nil
    }

    static func isSecureTextRole(role: String?, subrole: String?) -> Bool {
        role == "AXTextField" && subrole == "AXSecureTextField"
    }

    static func frontmost(allowPlatformSSO: Bool = false) -> SystemUnlockTarget? {
        assessment(allowPlatformSSO: allowPlatformSSO).target
    }

    func isCurrent() -> Bool {
        guard !application.isTerminated,
              let current = NSWorkspace.shared.frontmostApplication,
              current.processIdentifier == processIdentifier,
              current.isActive, !current.isTerminated,
              Self.kind(for: current) == kind,
              Self.hasAppleIdentity(current, kind: kind) else { return false }

        if kind == .platformSSO {
            guard let secureFocus = secureFocus else { return false }
            var details = Diagnostic(kind: kind.rawValue, active: current.isActive)
            guard let focus = Self.nativeSecureFocus(in: current, details: &details),
                  CFEqual(secureFocus, focus) else { return false }
        }
        return Self.frontmostStillMatches(current)
    }

    static func diagnostic() -> String {
        // A diagnostic assessment never returns an input target to its caller.
        assessment(allowPlatformSSO: true, diagnosticOnly: true).details.summary
    }

    private struct Diagnostic {
        var kind = "none"
        var active: Bool?
        var reason = "no-frontmost-application"
        var role: String?
        var subrole: String?
        var axError: Int32?
        var ownerMatches: Bool?
        var ancestorNative: Bool?

        var summary: String {
            func flag(_ value: Bool?) -> String { value.map(String.init) ?? "unknown" }
            return "kind=\(kind) active=\(flag(active)) reason=\(reason) " +
                "role=\(role ?? "unavailable") subrole=\(subrole ?? "unavailable") " +
                "axError=\(axError.map(String.init) ?? "none") " +
                "ownerMatches=\(flag(ownerMatches)) ancestorNative=\(flag(ancestorNative))"
        }
    }

    private static func kind(for application: NSRunningApplication) -> Kind? {
        kind(bundleIdentifier: application.bundleIdentifier,
             resolvedExecutablePath: application.executableURL?.resolvingSymlinksInPath().path)
    }

    private static func hasAppleIdentity(_ application: NSRunningApplication, kind: Kind) -> Bool {
        let attributes = [kSecGuestAttributePid as String: NSNumber(value: application.processIdentifier)] as CFDictionary
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, SecCSFlags(), &code) == errSecSuccess,
              let code = code else { return false }
        var requirement: SecRequirement?
        let expression = "anchor apple and identifier \"\(kind.bundleIdentifier)\""
        guard SecRequirementCreateWithString(expression as CFString, SecCSFlags(), &requirement) == errSecSuccess,
              let requirement = requirement else { return false }
        return SecCodeCheckValidity(code, SecCSFlags(), requirement) == errSecSuccess
    }

    private static func frontmostStillMatches(_ application: NSRunningApplication) -> Bool {
        guard !application.isTerminated,
              let current = NSWorkspace.shared.frontmostApplication else { return false }
        return current.processIdentifier == application.processIdentifier && current.isActive &&
            !current.isTerminated && kind(for: current) == kind(for: application)
    }

    private static func assessment(allowPlatformSSO: Bool, diagnosticOnly: Bool = false)
        -> (target: SystemUnlockTarget?, details: Diagnostic) {
        guard let application = NSWorkspace.shared.frontmostApplication else {
            return (nil, Diagnostic())
        }
        var details = Diagnostic(kind: "unsupported", active: application.isActive)
        guard let kind = kind(for: application) else {
            details.reason = "identity-not-allowlisted"
            return (nil, details)
        }
        details.kind = kind.rawValue
        guard hasAppleIdentity(application, kind: kind) else {
            details.reason = "apple-signature-check-failed"
            return (nil, details)
        }
        guard application.isActive, !application.isTerminated else {
            if diagnosticOnly, kind == .platformSSO, !application.isTerminated {
                _ = nativeSecureFocus(in: application, details: &details)
            }
            details.reason = "application-inactive"
            return (nil, details)
        }
        guard kind != .platformSSO || allowPlatformSSO else {
            details.reason = "platform-sso-policy-disabled"
            return (nil, details)
        }
        var focus: AXUIElement?
        if kind == .platformSSO {
            focus = nativeSecureFocus(in: application, details: &details)
            guard focus != nil else { return (nil, details) }
        }
        guard frontmostStillMatches(application) else {
            details.reason = "frontmost-changed"
            return (nil, details)
        }
        details.reason = "accepted"
        return (SystemUnlockTarget(application: application, kind: kind, secureFocus: focus), details)
    }

    private static func attribute(_ element: AXUIElement, _ name: CFString) -> (CFTypeRef?, AXError) {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, name, &value)
        return (value, error)
    }

    private static func element(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value = value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private static func roleIdentifier(_ value: CFTypeRef?) -> String? {
        guard let text = value as? String, text.hasPrefix("AX"), text.count <= 80,
              text.unicodeScalars.allSatisfy({
                  (65...90).contains($0.value) || (97...122).contains($0.value) ||
                  (48...57).contains($0.value)
              }) else { return nil }
        return text
    }

    private static func matchesOwner(_ element: AXUIElement, _ pid: pid_t, details: inout Diagnostic) -> Bool {
        var owner: pid_t = 0
        let error = AXUIElementGetPid(element, &owner)
        if error != .success {
            details.axError = error.rawValue
            details.reason = "ax-owner-unavailable"
            return false
        }
        details.ownerMatches = owner == pid
        if owner != pid { details.reason = "ax-owner-mismatch" }
        return owner == pid
    }

    private static func nativeSecureFocus(in application: NSRunningApplication,
                                          details: inout Diagnostic) -> AXUIElement? {
        guard AXIsProcessTrusted() else {
            details.reason = "ax-not-trusted"
            return nil
        }
        let applicationElement = AXUIElementCreateApplication(application.processIdentifier)
        AXUIElementSetMessagingTimeout(applicationElement, 0.1)
        let (focusedValue, focusedError) = attribute(applicationElement, kAXFocusedUIElementAttribute as CFString)
        guard focusedError == .success else {
            details.axError = focusedError.rawValue
            details.reason = "ax-focused-element-unavailable"
            return nil
        }
        guard let focus = element(focusedValue) else {
            details.reason = "ax-focused-element-invalid-type"
            return nil
        }
        AXUIElementSetMessagingTimeout(focus, 0.1)
        guard matchesOwner(focus, application.processIdentifier, details: &details) else { return nil }
        let (role, roleError) = attribute(focus, kAXRoleAttribute as CFString)
        let (subrole, subroleError) = attribute(focus, kAXSubroleAttribute as CFString)
        details.role = roleIdentifier(role)
        details.subrole = roleIdentifier(subrole)
        guard roleError == .success, subroleError == .success else {
            details.axError = (roleError != .success ? roleError : subroleError).rawValue
            details.reason = "ax-role-unavailable"
            return nil
        }
        guard isSecureTextRole(role: details.role, subrole: details.subrole) else {
            details.reason = "focus-not-secure-text"
            return nil
        }

        var current = focus
        var visited: [AXUIElement] = [focus]
        for _ in 0..<8 {
            let (parentValue, parentError) = attribute(current, kAXParentAttribute as CFString)
            guard parentError == .success, let parent = element(parentValue) else {
                details.axError = parentError.rawValue
                details.reason = "ax-native-ancestor-unavailable"
                return nil
            }
            guard !visited.contains(where: { CFEqual($0, parent) }) else {
                details.reason = "ax-ancestor-cycle"
                return nil
            }
            visited.append(parent)
            AXUIElementSetMessagingTimeout(parent, 0.1)
            guard matchesOwner(parent, application.processIdentifier, details: &details) else { return nil }
            let (parentRole, parentRoleError) = attribute(parent, kAXRoleAttribute as CFString)
            guard parentRoleError == .success, let identifier = roleIdentifier(parentRole) else {
                details.axError = parentRoleError.rawValue
                details.reason = "ax-ancestor-role-unavailable"
                return nil
            }
            if identifier == "AXWebArea" {
                details.ancestorNative = false
                details.reason = "web-ancestor-rejected"
                return nil
            }
            if identifier == "AXWindow" {
                details.ancestorNative = true
                return focus
            }
            current = parent
        }
        details.ancestorNative = false
        details.reason = "native-window-not-reached"
        return nil
    }
}
