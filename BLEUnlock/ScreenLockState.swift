import Foundation
import CoreGraphics
import IOKit

enum ScreenLockState {
    // IOConsoleLocked describes the foreground console, not every logged-in user.
    static func evaluate(session: [String: Any]?, consoleLocked: Bool?, userID: uid_t) -> Bool? {
        guard let session = session,
              let sessionUser = session["kCGSSessionUserIDKey"] as? NSNumber,
              sessionUser.uint32Value == userID,
              (session["kCGSSessionOnConsoleKey"] as? NSNumber)?.boolValue == true,
              (session["kCGSessionLoginDoneKey"] as? NSNumber)?.boolValue == true else {
            return nil
        }

        let legacy = (session["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue
        if let legacy = legacy, let consoleLocked = consoleLocked, legacy != consoleLocked {
            return nil // A transition or conflicting observations must not authorize input.
        }
        return consoleLocked ?? legacy
    }

    static func current() -> Bool? {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        let root = IORegistryGetRootEntry(kIOMasterPortDefault)
        var consoleLocked: Bool?
        if root != 0 {
            defer { IOObjectRelease(root) }
            let property = IORegistryEntryCreateCFProperty(
                root, "IOConsoleLocked" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            if let property = property, CFGetTypeID(property) == CFBooleanGetTypeID() {
                consoleLocked = (property as? NSNumber)?.boolValue
            }
        }
        return evaluate(session: session, consoleLocked: consoleLocked, userID: getuid())
    }
}
