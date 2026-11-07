# Release Notes


## Unreleased

- **Feat:** Event scripts now receive the triggering device name, stable identifier, and device RSSI as `$3`–`$5`. Device attribution is preserved when proximity wake wakes the display.


## 1.14.4

- **Fix:** GATT device-info connections during scanning are now limited to monitored devices (or devices whose name/MAC matches a monitored device), connected one at a time with per-device backoff. This prevents Bluetooth resource contention — such as audio dropouts — in environments with many nearby BLE devices.
- **Fix:** Device list no longer shows duplicate entries while a monitored device's UUID rotation is waiting for MAC correlation.
- **Fix:** Invalid RSSI values (0 or positive) are no longer displayed as signal strength.
- **Fix:** Unresolved devices' gray text no longer becomes nearly invisible in dark mode on macOS versions below 26.
- **Fix:** Device list menu items are split into separate button and text elements for compatibility with older macOS versions.
- **Fix:** Launch-at-login checkbox state now reverts when enabling fails, so it no longer shows a check that wasn't applied.


## 1.14.3

- **Fix:** macOS 13+ now uses SMAppService.mainApp to register the main app as a login item — replaces the legacy Launcher helper. The app shows as running in background in System Settings.
- **Fix:** All legacy login item registrations are cleaned up on startup, and state is read from the system instead of cached.
- **Fix:** RSSI median filter increased from 3 to 5 samples — signal display is even smoother with single outliers fully suppressed.
- **Fix:** Launch-at-login operations moved to async queue — avoids blocking the main thread from SMAppService XPC calls.
- **Fix:** Device list expansion no longer freezes in edge cases (e.g. rapid open).
- **Fix:** Duplicate device entries properly cleaned when UUIDs rotate, preventing stale entries from accumulation.
- **Fix:** Device submenu no longer reopens unexpectedly after closing the parent menu.
- **Fix:** Submenu width properly resets after Option-key detail mode.
- **Style:** MAC-resolved devices shown in standard text, unresolved UUID-only devices in gray — clearer at-a-glance distinction, especially in dark mode.


## 1.14.2

- **Fix:** RSSI signal display is more stable — switched from 5-sample moving average to median-of-3 filter. Single outliers are completely eliminated, while real signal changes track with lower latency.
- **Fix:** When a monitored device's Bluetooth UUID rotates (privacy feature), the app now correctly detects and inherits the new UUID in real time. Previously it could get stuck showing 'Not Detected' until restart.
- **Fix:** Screen lock no longer stops background scanning — UUID rotations and proximity detection continue working as long as any device is monitored.
- **Fix:** RSSI 0 dBm no longer appears — treated as disconnected.
- **Fix:** Separator and 'Scanning…' now work correctly in all cases: when unmonitored devices arrive, when the first device is checked during menu tracking, and when no devices are checked.
- **Fix:** MAC resolution no longer fails when a device broadcasts both classic Bluetooth and BLE with the same name (e.g. RedMagic) — prefers the classic entry.
- **Fix:** Device detection count (e.g. '1/2') is accurate immediately on menu open.
- **Fix:** Monitored device list order no longer flickers during scans.

- **Feat:** Hold ⌥ (Option) to show full MAC address and UUID — default menu displays device name and RSSI only.
- **Feat:** UUID-only devices show collapsed `XXXX…YYYY` format for readability.
- **Feat:** Clickable "Pair to stabilize random address tracking →" hint opens Bluetooth settings.
- **Feat:** ⌥ indicator on "Device List" main menu item.

## 1.14.1

- Resolve MAC addresses from system paired Bluetooth devices via IOBluetooth and display them in the device list.
- Automatically remap device tracking when BLE UUID changes after disconnect or reboot, using MAC-based cross-correlation. No reconfiguration needed.
- Monitored devices are now sorted to the top of the device list, with unmonitored devices following in discovery order.
- Add Bluetooth entitlement for broader macOS compatibility.
- Fix MAC persistence: changed from `{UUID → MAC}` to `{MAC → UUID}` format with merge-on-write, preventing MAC entries from being overwritten when BLE correlation runs concurrently.
- Ensure monitored devices always appear in the runtime device dictionary, so MAC-based correlation can match rotated BLE UUIDs after app restart.
- Fix device menu not refreshing unmonitored devices after quick reopen caused by aggressive stale-device cleanup.
- Fix group separator line not appearing on first launch.
- Improve menu stability during tracking: defer full menu rebuilds while the menu is open, updating only separator visibility in real time.
- Fall back to macOS Bluetooth LE database for MAC address resolution when IOBluetooth name lookup fails.


## 1.14.0

- Resolve MAC addresses from system paired Bluetooth devices via IOBluetooth and display them in the device list.
- Automatically remap device tracking when BLE UUID changes after disconnect or reboot, using MAC-based cross-correlation. No reconfiguration needed.
- Monitored devices are now sorted to the top of the device list, with unmonitored devices following in discovery order.
- Add Bluetooth entitlement for broader macOS compatibility.


## 1.13.6

- Add an Updates submenu with automatic update checks and manual update actions.
- Let manual update checks open the latest DMG download directly, with a fallback to the release page.
- Show pending update status in the menu even when notifications are disabled.
- Make automatic update notifications silent to reduce interruptions.
- Move BLE name-resolution logs into the current user's Library/Logs directory.
- Harden password handling, timer lifecycle, manual-lock recovery, and media pause state synchronization.
- Fix iBeacon prefix parsing and improve launcher path validation.
- Migrate the app bundle identifier to `com.github.Skyearn.BLEUnlock` with compatibility for legacy settings, Keychain data, and login items.


## 1.13.5

- Improve media pause handling when locking the Mac.
- Enhance lock-triggered automation timing when playback is controlled by a remote device.
- Improve stale-update state handing so incorrectly cached states are automatically cleared after an app upgrade or reinstall.
- Update the secure password retrieval to cover BLE-unlock-specific access failures without blocking other keychain operations.


## 1.13.4

- Reorganized the unlock and lock controls by grouping logic and RSSI settings into `Unlock Settings` and `Lock Settings` submenus.
- Disable the logic choices when only one device is being monitored, and refresh that state immediately after device selections change.
- Keep monitored devices in the name-resolution path even when their RSSI temporarily drops below the scan list threshold, reducing UUID fallback for devices such as Apple Watch.
- Updated the README files to match the revised menu structure and installation notes for this fork.


## 1.13.3

- Reorganized the unlock and lock controls by grouping logic and RSSI settings into `Unlock Settings` and `Lock Settings` submenus.
- Disable the logic choices when only one device is being monitored, and refresh that state immediately after device selections change.
- Keep monitored devices in the name-resolution path even when their RSSI temporarily drops below the scan list threshold, reducing UUID fallback for devices such as Apple Watch.
- Updated the README files to match the revised menu structure and installation notes for this fork.


## 1.13.2

- Reduced BLE scan, connection, and RSSI polling activity during the system sleep transition to lower the chance of the Mac waking immediately after being put to sleep.
- Resume BLE monitoring automatically after the system wakes, while keeping normal proximity detection and unlock behavior intact.
- Preserved wake-on-proximity behavior for display sleep without letting the app keep aggressively probing devices at the system sleep boundary.


## 1.13.1

- Reduced aggressive display wake retries around sleep/wake transitions to avoid getting stuck in a half-wake display state.
- Added automatic recovery after required permissions are granted, so BLEUnlock can resume work without forcing an app restart.
- Fixed temporary mismatches between the menu bar summary and the monitored device list when scan cache entries expire.
- Refined the monitored-device summary text to show the detected count and strongest RSSI more clearly.


## 1.13.0

- Added support for monitoring multiple BLE devices at the same time, with configurable unlock and lock logic.
- Improved wake-from-sleep unlock reliability by waiting for the lock screen to become ready before sending the password, and retrying when the first attempt lands too early.
- Simplified the menu bar summary into a single status line that shows the number of selected devices, how many are currently detected, and the strongest monitored signal.
- Unified RSSI display between the summary line and the monitored devices in the device list so the values are easier to understand.
- Restored live updates in the device scan list while keeping monitored-but-currently-undetected devices visible.
- Added a Simplified Chinese README and linked it from the English documentation.
