# Unlocking on recent macOS versions

This page describes lock-screen compatibility, permission setup, and diagnostics
for BLEUnlock's automatic unlock path.

## Lock-state detection and input delivery

Some macOS versions omit `CGSSessionScreenIsLocked` from the dictionary returned
by `CGSessionCopyCurrentDictionary()`. BLEUnlock also reads the IORegistry root
property `IOConsoleLocked`. It applies that console-wide observation only when
the session belongs to the current user, is on the console, and has completed
login. Missing observations and conflicting lock-state observations remain
unknown and do not authorize input.

Password events are directed to a captured system process. The target must have
an exact allowed bundle identifier and resolved executable path, a valid Apple
code signature, and an active foreground application. BLEUnlock rechecks the
target before each key pair. Passwords are not sent through the global
foreground event stream.

The classic target is Apple's `loginwindow`. An optional native Platform SSO
target is described below. Unicode event chunks preserve UTF-16 surrogate pairs,
modifier flags are cleared, and submission uses the Return key. An already-sent
key is released even if Return immediately unlocks the screen.

BLEUnlock waits for the system input target to become ready before submission.
After submitting a password, it waits for an observed unlock before reporting
success. It does not repeatedly submit the password when confirmation is absent.

## Permissions and stored password

Grant the permissions requested by macOS for the installed BLEUnlock build.
On supported versions, startup uses `CGRequestPostEventAccess()` to request event
posting access, alongside the Accessibility permission check. The immediate
return value from a permission request can precede the user's decision. Quit and
relaunch BLEUnlock after completing the system permission prompts.

Replacing or signing the app differently can change its permission identity.
If macOS no longer recognizes the grant, the user must grant access to the new
build through the system UI. Permission grants are not installed or reset by a
script.

Set the Mac login password using **Set Password...**. If macOS requests Keychain
access while the Mac is unlocked, allow the installed app to access its stored
password as required. Update the stored password after changing the Mac login
password.

Automatic unlock reads Keychain with authentication UI disabled. If the item is
missing or inaccessible, the attempt stops and records its status code instead
of opening a modal dialog on the lock screen. Startup retains the normal
interactive Keychain authorization flow.

## Optional Platform SSO lock screen

Some Macs use Apple's Platform SSO agent for their native lock-screen password
field. Platform SSO input support is **off by default**.

To enable it, choose **Use Platform SSO Lock Screen** in the BLEUnlock menu. Enable
this option only after confirming that the native lock screen accepts the same
ordinary local Mac login password stored in BLEUnlock. Browser sign-in, web
authentication, MFA, and one-time-code dialogs are outside this feature's scope.
Uncheck the menu item to disable the adaptation.

In addition to the system identity checks, the Platform SSO target must expose a
focused `AXTextField` with the `AXSecureTextField` subrole owned by that process.
BLEUnlock inspects at most eight ancestors, rejects `AXWebArea`, and requires a
native `AXWindow`. It captures the focused element and requires that same element
to remain focused before input continues. These checks read roles and ownership;
they do not read field values, titles, descriptions, or child contents.

The existing proximity and wake behavior still applies. A lock-state observation
alone does not request an unlock. **Lock Screen Now** remains locked until the
monitored device moves away and then returns. **Wake without Unlocking** continues
to suppress automatic password submission.

## Diagnostics

Periodic state snapshots are off by default. To enable them, quit BLEUnlock,
run the following command, and launch it again:

```sh
defaults write jp.sone.BLEUnlock unlockDiagnostics -bool true
```

Reproduce the normal lock, return, and wake sequence, then inspect the Unlock log:

```sh
log show --last 10m --style compact \
  --predicate 'subsystem == "jp.sone.BLEUnlock" AND category == "Unlock"'
```

The log distinguishes a missing trigger, an eligibility rejection, a target that
is not ready, a Keychain error, cancellation, submission, and unlock confirmation.
Snapshots include state flags, RSSI and thresholds, permission booleans, and
system-target validation results. Platform SSO diagnostics contain role/subrole
identifiers and accessibility error codes. Diagnostic messages contain no
password, password length, account name, device UUID, or field text.

To disable snapshots, quit BLEUnlock, run the following command, and relaunch:

```sh
defaults write jp.sone.BLEUnlock unlockDiagnostics -bool false
```

## Building and testing

The project retains its upstream macOS 10.13 deployment target. A local build
with Xcode 27 needs a supported deployment-target override; this does not change
the checked-in minimum target. For a compilation check without code signing:

```sh
xcodebuild -project BLEUnlock.xcodeproj -scheme BLEUnlock \
  -configuration Debug -derivedDataPath .build/DerivedData \
  MACOSX_DEPLOYMENT_TARGET=12.0 CODE_SIGNING_ALLOWED=NO build
```

Run the regression tests with Python 3 available, from an interactive, logged-in
macOS GUI session:

```sh
zsh tools/test-macos27.zsh
```

The suites contain 80 state, Unicode, event-construction, and mock-delivery
assertions, plus 16 system-target policy assertions. They do not deliver input,
read Keychain, query live accessibility elements, or lock the screen. Constructing
Core Graphics events still requires a working GUI session. An agent sandbox or
headless environment can block that operation. The script limits each suite to
45 seconds and reports a timeout as an environment limitation.

The added Swift helpers also pass an API-availability type check targeting
`x86_64-apple-macosx10.13`. This is not an older-OS runtime test. Xcode 27 rejects
the project's unchanged 10.13 deployment target before compilation because its
supported range starts at macOS 12; CI therefore uses the same 12.0 override.

A real lock → wake → unlock sequence on macOS 27.0.1 has been confirmed by user
observation and diagnostic logs. Automated tests validate the local policies and
event construction, not authentication by macOS. Runtime behavior on earlier
macOS releases has not been verified as part of this change.
