# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

BLEUnlock is a macOS menu bar app (Swift + Obj-C) that locks/unlocks a Mac based on proximity of a Bluetooth Low Energy device. It requires macOS 10.13+ and must run on a Mac (not cross-platform). Bundle ID: `jp.sone.BLEUnlock`.

## Building

Build and run via Xcode (open `BLEUnlock.xcodeproj`). There are no Swift Package Manager or CocoaPods dependencies — the project uses only system frameworks.

From the command line:
```bash
# Debug build
xcodebuild -scheme BLEUnlock -configuration Debug build

# Archive + export for release (requires Apple Developer credentials and PASSWORD env var)
PASSWORD=<app-specific-password> ./release
```

The `release` script archives, exports, notarizes both the main app and the embedded Launcher login item, then zips for distribution.

## Architecture

### Core Components

**`BLEUnlock/BLE.swift`** — The BLE engine. `BLE` (a `CBCentralManager` delegate) manages two modes:
- **Passive mode**: relies on advertisement packets for RSSI
- **Active mode**: connects to the peripheral and polls `readRSSI()` every 2s; falls back to passive after 10s of no reads

`BLE` tracks a single "monitored" device by UUID. Presence is determined by comparing a moving average of RSSI values (using `vDSP_normalizeD`) against configurable lock/unlock RSSI thresholds. Timers handle `proximityTimeout` (delay-to-lock) and `signalTimeout` (no-signal timeout).

**`BLEUnlock/AppDelegate.swift`** — The UI and system event hub. Handles:
- Menu bar construction and all user actions
- System/display sleep+wake via `NSWorkspace` notifications
- Screen lock/unlock via `DistributedNotificationCenter` (`com.apple.screenIsUnlocked`)
- Screensaver start/stop notifications
- Unlocking: calls `fakeKeyStrokes()` to type the password via `CGEvent` into the lock screen
- Locking: calls `SACLockScreenImmediate()` (private API via `lowlevel.c`) or launches `ScreenSaverEngine`
- Media control via private `MediaRemote.framework` (see `MediaRemote.h`)
- Password storage/retrieval via Keychain (`SecItemAdd`/`SecItemCopyMatching`)
- Runs `~/Library/Application Scripts/jp.sone.BLEUnlock/event` with args: `away`, `lost`, `unlocked`, `intruded`

**`BLEUnlock/lowlevel.c`** — C wrappers for IOKit: `wakeDisplay()`, `sleepDisplay()`, and `SACLockScreenImmediate()` (private SAC framework symbol declared via bridging header).

**`BLEUnlock/LEDeviceInfo.swift`** — Resolves BLE device UUID → MAC address + name. Uses two strategies:
1. (macOS Monterey+) Direct SQLite queries to `/Library/Bluetooth/com.apple.MobileBluetooth.ledevices.paired.db` and `.other.db`
2. (Older macOS) Reads `/Library/Preferences/com.apple.Bluetooth.plist` CoreBluetoothCache

**`BLEUnlock/appleDeviceNames.swift`** — Static lookup table mapping Apple model identifiers (e.g. `"iPhone14,5"`) to human-readable names.

**`Launcher/`** — A minimal Obj-C login item (`SMLoginItemSetEnabled`) that launches the main app at login.

### Key Behavioral Details

- The app cannot use `LSUIElement = true` in Info.plist (which would hide the Dock icon) because `CBCentralManager.scanForPeripherals` won't work in that mode. Instead, it calls `NSApp.setActivationPolicy(.accessory)` after launch and `.regular` during system sleep so BLE scanning resumes after wake.
- `manualLock`: set when the user triggers "Lock Screen Now"; prevents auto-unlock until the device leaves and returns.
- `unlockedAt`: timestamp of the last BLEUnlock-initiated unlock; used by `onUnlock()` to detect manual (intruded) unlocks — if the screen is unlocked more than 10 seconds after BLEUnlock typed the password, it fires the `intruded` event.
- RSSI moving average uses `latestN = 5` samples via `vDSP_normalizeD` (returns mean).

### UserDefaults Keys

`device`, `lockRSSI`, `unlockRSSI`, `timeout`, `lockDelay`, `passiveMode`, `thresholdRSSI`, `wakeOnProximity`, `wakeWithoutUnlocking`, `pauseItunes`, `screensaver`, `sleepDisplay`, `launchAtLogin`
