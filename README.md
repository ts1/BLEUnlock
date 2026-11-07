# BLEUnlock

## Please note that I don't distribute this app on the Mac App Store. You can find it here for free! 

![CI](https://github.com/Skyearn/BLEUnlock/workflows/CI/badge.svg)
![Github All Releases](https://img.shields.io/github/downloads/Skyearn/BLEUnlock/total.svg)

BLEUnlock is a small menu bar utility that locks and unlocks your Mac by proximity of your iPhone, Apple Watch, or any other Bluetooth Low Energy device.

This document is also available in [Japanese (日本語版はこちら)](README.ja.md) and [Simplified Chinese (简体中文)](README.cn.md).

> This repository is a fork of the original [ts1/BLEUnlock](https://github.com/ts1/BLEUnlock), created by Takeshi Sone. Many thanks to Takeshi Sone for open-sourcing BLEUnlock under the MIT license, and to all contributors who made the original project possible.

## Features

- No iPhone app is required
- Works with any BLE devices that periodically transmits signal from [static MAC address](#notes-on-mac-address)
- Unlocks your Mac for you when the BLE device is near your Mac, without entering password
- Locks your Mac when the BLE device is away from your Mac
- Optionally runs your own script upon lock/unlock
- Optionally wakes from display sleep
- Optionally pauses and unpauses music/video playback when you're away and back
- Password is securely stored in Keychain
- Devices with resolved MAC addresses appear in black; unresolved devices appear in gray, for at-a-glance distinction.
- Hold ⌥ (Option) in the device list to reveal full MAC address and UUID. Release and reopen for compact display.

## Security Notice

BLEUnlock identifies your device by its BLE MAC address and determines proximity based on RSSI signal strength. BLE broadcasts are unencrypted and public, which means a nearby attacker could:

1. Sniff the MAC address of your paired BLE device
2. Spoof the same MAC address using a readily available BLE development board
3. Approach your Mac with the forged signal to trigger an automatic unlock

This is inherent to all RSSI-based proximity solutions. There is no cryptographic authentication in the BLE broadcast layer.

Additionally, because BLEUnlock does not require installing companion software on the monitored device, it cannot determine whether the device itself is locked or unlocked. If your device is lost and picked up by someone else, that person can carry it near your Mac to trigger an automatic unlock — the Mac only sees the BLE signal, not the device's lock state.

**Recommendation**: If you have high security requirements, **disable RSSI unlocking** (set *Unlock Settings* → *Disable*). RSSI-based **locking** (auto-lock when you walk away) is safe to use, as it only locks your Mac and cannot grant access.

For users who need both security and convenience, consider using Apple's built-in Unlock with Apple Watch feature instead for unlocking, and BLEUnlock only for automatic locking.

## Requirements

- A Mac with Bluetooth Low Energy support
- macOS 10.13 (High Sierra) or later
- iPhone 5s or newer, Apple Watch (all), or another BLE device that has [static MAC address](#notes-on-mac-address) and transmits signal periodically

## Installation

### Using Homebrew Cask

```sh
brew install --cask Skyearn/tap/bleunlock
```

> This uses this fork's own Homebrew tap. The official `bleunlock` cask in Homebrew may still point to the upstream project.

### Manual installation

Download the dmg file from [Releases](https://github.com/Skyearn/BLEUnlock/releases), open it, and move BLEUnlock to the Applications folder.

> NOTE: This fork is not enrolled in the Apple Developer Program, so release builds cannot be distributed with Apple Developer ID signing and notarization. macOS may therefore block the app on first launch.
>
> When double-clicking for the first time, macOS shows "cannot be opened because Apple cannot check it for malicious software" with only "Done" and "Move to Trash":
> 1. Move `BLEUnlock.app` to `/Applications`.
> 2. Open Terminal and run: `sudo xattr -rd com.apple.quarantine /Applications/BLEUnlock.app` to clear the quarantine flag.
> 3. If it is still blocked, open **System Settings** -> **Privacy & Security**, scroll down, and click **Open Anyway** for BLEUnlock.
> 4. Launch the app again and confirm **Open**.
> 5. After the app starts, grant the requested Bluetooth, Accessibility, Keychain, and Notification permissions.
>
> To reduce repeated permission prompts when updating, replace the existing `/Applications/BLEUnlock.app` instead of running copies from different folders.

## Setting up

On the first launch, it asks for the following permissions, which you must grant:

Permission | Description
-----------|---
Bluetooth | Obviously, Bluetooth access is required. Choose *OK*.
Accessibility | This is required to unlock the locked screen. Click *Open System Preferences*, click the lock icon on the bottom left to unlock, and turn on BLEUnlock.
Keychain | (Not always asked) If asked, you have to choose **Always Allow** because it is required while the screen is locked.
Notification | (Optional) BLEUnlock shows a message on the lock screen when it locks the screen. It is helpful to know if it's working properly. Additionally, to see the message on the lock screen, you need to set *Show previews* to *always* in the *Notification* preference pane. 

> NOTE: The number of permissions required increases with each version of macOS, so if you are using an older OS, you may not be asked for one or more permissions.

Then it asks your login password to unlock the lock screen.
It will be stored safely in Keychain. 

Finally, from the menu bar icon, select *Device*.
It starts scanning nearby BLE devices.
Select your device, and you're done!

## Options

Option | Description
-------|---
Lock Screen Now | It locks the screen regardless of whether the BLE device is nearby or not; it will unlock once the BLE device moves away and then moves closer again. This is useful to ensure that the screen is locked before you leave your seat.
Unlock Settings | Groups the unlock logic and unlock RSSI settings in one submenu. The logic chooses whether *any* selected device or *all* selected devices must be near. The RSSI value controls how close the BLE device needs to be before unlocking. Choose *Disable* there to disable unlocking.
Lock Settings | Groups the lock logic and lock RSSI settings in one submenu. The logic chooses whether locking happens when *any* selected device goes away or only when *all* selected devices are away. The RSSI value controls how far the BLE device needs to be before locking. Choose *Disable* there to disable locking.
Delay to Lock | Duration of time before it locks the Mac when it detects that the BLE device is away. If the BLE device comes closer within that time, no lock will occur.
No-Signal Timeout | Time between last signal reception and locking. If you experience frequent "Signal is lost" locking, increase this value.
Lock When Signal Is Lost | Enabled by default. Disable for devices that stop advertising while asleep; signal loss then updates detection status without locking. If a device disappears without sustained weak signals, it will no longer cause an automatic lock.
Prevent Locking While Mac Is in Use | Disabled by default. When enabled, measured-distance locking also requires keyboard/mouse idle time of at least Delay to Lock; signal-loss locking requires idle time of at least No-Signal Timeout. Pending locks are rechecked against current signal and activity.
Wake on Proximity | Wakes up the display from sleep when the BLE device approaches while locking.
Wake without Unlocking | BLEUnlock will not unlock the Mac when the display wakes up from sleep, whether automatically via "Wake on Proximity" or manually. This allows for compatibility with the macOS built-in unlock with Apple Watch feature (which can operate immediately after BLEUnlock wakes the screen), or if you just prefer the lock screen to appear more quickly but don't want it to auto-unlock.
Pause "Now Playing" while Locked | On lock/unlock, BLEUnlock pauses/unpauses playback of music or video (including Apple Music, QuickTime Player and Spotify) that is controlled by *Now Playing* widget or the ⏯ key on the keyboard.
Use Screensaver to Lock | If this option is set, BLEUnlock launches screensaver instead of locking. For this option to work properly, you need to set *Require password **immediately** after sleep or screen saver begins* option in *Security & Privacy* preference pane.
Turn Off Screen on Lock | Turn off the display immediately when locking.
Set Password... | If you changed your login password, use this.
Passive Mode | By default it actively tries to connect to the BLE device and read the RSSI. Most of the time, the default is recommended and works stably. However, if you are using other Bluetooth things like keyboard, mouse, track pad or most notably Bluetooth Personal Hotspot, the default mode may interfere with each other. 2.4GHz WiFi may interfere as well. If you are experiencing instability of Bluetooth, turn on Passive Mode.
Launch at Login | Launches BLEUnlock when you login.
Set Minimum RSSI | Devices with RSSI below this value will not be displayed in the device scan list.

## Troubleshooting

### Can't find my device in the list

If your BLE device is not from Apple, BLEUnlock may not able to find the device name.
If that is the case, your device is displayed as a UUID (long hexadecimal numbers and hyphens).
To identify the device, try moving the device closer to or farther away from the Mac and see if the RSSI (dB value) changes accordingly.

If you don't see *any* device in the list, try resetting the Bluetooth module as described below.

### Device scanning after switching macOS users

BLEUnlock relies on macOS CoreBluetooth scanning. When multiple macOS users are logged in at the same time, especially when using Fast User Switching, macOS may keep Bluetooth scanning resources tied to the previous user's BLEUnlock process. In that state, another user's BLEUnlock instance may show no devices even though Bluetooth permission is granted and Bluetooth is powered on.

If you need to use BLEUnlock across multiple macOS user accounts, quit BLEUnlock in the current user before switching to another user, then start BLEUnlock in the target user account. This fully releases the previous user's Bluetooth scanning session and is more reliable than leaving BLEUnlock running in the background.

BLEUnlock does not try to automate this workaround. A reliable automatic solution would require a helper or launch agent that keeps tracking user-session state, quits BLEUnlock when a user becomes inactive, and relaunches it when that user becomes active again. That would be a large and intrusive lifecycle-management change, and the behavior would be too close to a program that keeps reviving itself in the background. For that reason, this fork documents the limitation instead of adding such a helper.

### It fails to unlock

Make sure BLEUnlock is turned on in *System Preferences* > *Security & Privacy* > *Privacy* > *Accessibility*.
If it is already on, try turning it off and on again.

If it asks for permission to access its own password in Keychain, you must choose *Always Allow*, because it is needed while the screen is locked.

### "Signal is lost" occurs frequently

Some Android phones stop BLE advertising when the phone sleeps. If increasing the timeout is insufficient, disable *Lock When Signal Is Lost*. This makes missing advertisements an unknown state instead of evidence of departure. Sustained weak signals can still lock the Mac. Enable *Prevent Locking While Mac Is in Use* to defer automatic locking while you are using the keyboard or mouse. These options preserve the existing signal-loss and activity behavior until changed.

Increase *No-Signal Timeout*.
Or try *Passive Mode*.

### My Bluetooth keyboard, mouse, Personal Hotspot, or whatever Bluetooth, went nuts!

Firstly, Shift + Option + Click the Bluetooth icon in the menubar or Control Center, then click *Reset the Bluetooth module*.

In macOS 12 Monterey, this option is no longer available.
Instead, type the command below in Terminal to reset the Bluetooth module:

```
sudo pkill bluetoothd
```

This command will ask your login password.

If the problem persists, turn on *Passive Mode*.

## Notes on MAC address

Unlike classic Bluetooth, Bluetooth Low Energy devices can use *private* MAC address.
That private address can be random, and can be changed from time to time.

Recent smart devices, both iOS and Android, tend to use private addresses that change every 15 minutes or so. This is probably to prevent tracking.

On the other hand, in order for BLEUnlock to track your device, its MAC address must be static.

Fortunately, on Apple devices, if you are signed in with the same Apple ID as your Mac, the MAC address is resolved to the true (public) address.

### Using a paired device

If a device uses rotating private addresses, pair it with your Mac once in *System Settings* > *Bluetooth*. After pairing, BLEUnlock can read the device's MAC address from the system and display it in the device list. This enables:

- **Reliable identification**: the MAC address is shown next to the device name, so you always know which device is which.
- **Automatic re-tracking**: if the device's BLE UUID changes after a disconnect or system reboot, BLEUnlock will automatically remap tracking to the new UUID via MAC address matching — no manual reconfiguration needed.

Pairing itself usually has little effect on battery life. The bigger battery impact comes from frequent active Bluetooth connections or polling, not from the one-time pairing step.

## Run script on lock/unlock

On locking and unlocking, BLEUnlock runs a script located here:

```
~/Library/Application Scripts/com.github.Skyearn.BLEUnlock/event
```

An argument is passed depending on the type of event:

|Event|Argument|
|-----|--------|
|Locked by BLEUnlock because of low RSSI|`away`|
|Locked by BLEUnlock because of no signal|`lost`|
|Unlocked by BLEUnlock|`unlocked`|
|Unlocked manually|`intruded`|

Script arguments are:

- `$1`: event type.
- `$2`: latest aggregate RSSI (the strongest among visible monitored devices), omitted if none has been received.
- `$3`: display name of the monitored device whose state change triggered the event. Passed for `away` and `lost`, and for `unlocked` when a device came close. Omitted when no device-triggered event occurred, such as an unlock attempt after the Mac wakes.
- `$4`: stable identifier for that device: its MAC address when available, otherwise its CoreBluetooth UUID.
- `$5`: RSSI of the triggering device, or an empty string if unavailable.

When `$3` is present without `$2`, `$2` is an empty string so that `$3` keeps its position. Device names can be duplicated or unresolved; use `$4` when a stable identifier is needed. `$3`–`$5` are omitted when no device triggered the event.

> NOTE: for `intruded` event works properly, you have to set *Require password **immediately** after sleep* in *Security & Privacy* preference pane.

### Example

Here is an example script which sends a LINE Notify message, with a photo of the person in front of the Mac when it is unlocked manually.

```sh
#!/bin/bash

set -eo pipefail

LINE_TOKEN=xxxxx

notify() {
    local message=$1
    local image=$2
    if [ "$image" ]; then
        img_arg="-F imageFile=@$image"
    else
        img_arg=""
    fi
    curl -X POST -H "Authorization: Bearer $LINE_TOKEN" -F "message=$message" \
        $img_arg https://notify-api.line.me/api/notify
}

capture() {
    open -Wa SnapshotUnlocker
    ls -t /tmp/unlock-*.jpg | head -1
}

case $1 in
    away)
        notify "$(hostname -s) is locked by BLEUnlock because iPhone is away."
        ;;
    lost)
        notify "$(hostname -s) is locked by BLEUnlock because signal is lost."
        ;;
    unlocked)
        #notify "$(hostname -s) is unlocked by BLEUnlock."
        ;;
    intruded)
        notify "$(hostname -s) is manually unlocked." $(capture)
        ;;
esac
```

`SnapshotUnlocker` is an .app created with Script Editor with this script:

```
do shell script "/usr/local/bin/ffmpeg -f avfoundation -r 30 -i 0 -frames:v 1 -y /tmp/unlock-$(date +%Y%m%d_%H%M%S).jpg"
```

This app is required because BLEUnlock does not have Camera permission.
Giving permission to this app resolves the problem.

## Fork Origin

This fork is based on the original [ts1/BLEUnlock](https://github.com/ts1/BLEUnlock) by Takeshi Sone and continues development in this repository for its own releases and changes.

Thank you to Takeshi Sone for the original project, and to everyone who contributed fixes, translations, and ideas over time.

## Credits

- [Takeshi Sone](https://github.com/ts1): Original BLEUnlock author and project foundation
- [peiit](https://github.com/peiit): Chinese translation
- [wenmin-wu](https://github.com/wenmin-wu): Minimum RSSI and moving average
- [stephengroat](https://github.com/stephengroat): CI
- [joeyhoer](https://github.com/joeyhoer): Homebrew Cask
- [cyberclaus](https://github.com/cyberclaus): German, Swedish, Norwegian (Bokmål) and Danish localizations
- [alonewolfx2](https://github.com/alonewolfx2): Turkish localization
- [wernjie](https://github.com/wernjie): Wake without Unlocking
- [tokfrans03](https://github.com/tokfrans03): Language fixes


Icons are based on SVGs downloaded from materialdesignicons.com.
They are originally designed by Google LLC and licensed under Apache License version 2.0.

## License

MIT

Copyright © 2019-2022 Takeshi Sone. MIT Licensed.<br>Copyright © 2026 Skyearn. MIT Licensed.
