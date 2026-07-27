# BLEUnlock

## Please note that I don't distribute this app on the Mac App Store. You can find it here for free! 

![CI](https://github.com/ts1/BLEUnlock/workflows/CI/badge.svg)
![Github All Releases](https://img.shields.io/github/downloads/ts1/BLEUnlock/total.svg)
[![Buy me a coffee](img/buymeacoffee.svg)](https://www.buymeacoffee.com/tsone)

BLEUnlock is a small menu bar utility that locks and unlocks your Mac by proximity of your iPhone, Apple Watch, or any other Bluetooth Low Energy device.

This document is also available in [Japanese (日本語版はこちら)](README.ja.md).

## Features

- No iPhone app is required
- Works with any BLE devices that periodically transmits signal from [static MAC address](#notes-on-mac-address)
- Unlocks your Mac for you when the BLE device is near your Mac, without entering password
- Locks your Mac when the BLE device is away from your Mac
- Optionally runs your own script upon lock/unlock
- Optionally wakes from display sleep
- Optionally pauses and unpauses music/video playback when you're away and back
- Password is securely stored in Keychain

## Requirements

- A Mac with Bluetooth Low Energy support
- macOS 10.13 (High Sierra) or later
- iPhone 5s or newer, Apple Watch (all), or another BLE device that has [static MAC address](#notes-on-mac-address) and transmits signal periodically

## Installation

### Using Homebrew Cask

```
brew install bleunlock
```

### Manual installation

Download the zip file from [Releases](https://github.com/ts1/BLEUnlock/releases), unzip and move to the Applications folder.

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

## Telegram notifications

Telegram notifications are optional and disabled until you configure and enable them:

1. Create a bot with [@BotFather](https://t.me/BotFather) and copy its token.
2. Send the bot a message, then open `https://api.telegram.org/bot<TOKEN>/getUpdates` and copy the numeric Chat ID from the response.
3. Open *BLEUnlock > Telegram Notifications > Configure…* and save both values.
4. Send a test notification, choose the event switches, and enable Telegram.
5. If photo alerts are enabled, approve Camera access when macOS asks.

The approved event defaults are `away`, `lost`, and `intruded` on, with `unlocked` off. Telegram itself starts disabled. Photo capture for `intruded` is on by default; `intruded` is the only event that can include a photo, and all other event notifications are text-only. If Camera access is denied or capture fails, the `intruded` alert is sent as text only. Each temporary intrusion photo is deleted after its send attempt, whether the attempt succeeds or fails.

The legacy `~/Library/Application Scripts/jp.sone.BLEUnlock/event` script remains available and continues to receive all four event arguments independently of Telegram.

## Options

Option | Description
-------|---
Lock Screen Now | It locks the screen regardless of whether the BLE device is nearby or not; it will unlock once the BLE device moves away and then moves closer again. This is useful to ensure that the screen is locked before you leave your seat.
Unlock RSSI | Bluetooth signal strength to unlock. Larger value indicates that the BLE device needs to be closer to the Mac to unlock. Choose *Disable* to disable unlocking.
Lock RSSI | Bluetooth signal strength to lock. Smaller value indicates that the BLE device needs to be farther away from the Mac to lock. Choose *Disable* to disable locking.
Delay to Lock | Duration of time before it locks the Mac when it detects that the BLE device is away. If the BLE device comes closer within that time, no lock will occur.
No-Signal Timeout | Time between last signal reception and locking. If you experience frequent "Signal is lost" locking, increase this value.
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

### It fails to unlock

Make sure BLEUnlock is turned on in *System Preferences* > *Security & Privacy* > *Privacy* > *Accessibility*.
If it is already on, try turning it off and on again.

If it asks for permission to access its own password in Keychain, you must choose *Always Allow*, because it is needed while the screen is locked.

### "Signal is lost" occurs frequently

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

For other devices, including Android, the way to resolve the address is unknown.
If your non-Apple device changes its MAC address over time, unfortunately BLEUnlock can't support it.

To check if the MAC address is resolved correctly, compare the MAC address displayed in the *Device* scan list of BLEUnlock with the one that is displayed on your device.

## Run script on lock/unlock

On locking and unlocking, BLEUnlock runs a script located here:

```
~/Library/Application Scripts/jp.sone.BLEUnlock/event
```

An argument is passed depending on the type of event:

|Event|Argument|
|-----|--------|
|Locked by BLEUnlock because of low RSSI|`away`|
|Locked by BLEUnlock because of no signal|`lost`|
|Unlocked by BLEUnlock|`unlocked`|
|Unlocked manually|`intruded`|

> NOTE: for `intruded` event works properly, you have to set *Require password **immediately** after sleep* in *Security & Privacy* preference pane.

### Historical LINE Notify example (unsupported)

Older versions of this README showed a LINE Notify and SnapshotUnlocker script here. LINE Notify has been discontinued, so that historical endpoint and example are unsupported and no longer functional. Use BLEUnlock's built-in Telegram notifications or connect another current service through the legacy `event` script.

## Funding

The annual Apple Developer Program fee is funded by donations.

If you like this app, I'd appreciate it if you could make a donation via [Buy Me a Coffee](https://www.buymeacoffee.com/tsone) or [PayPal Me](https://www.paypal.com/paypalme/my/profile) so I can keep up.

## Credits

- [peiit](https://github.com/peiit): Chinese translation
- [wenmin-wu](https://github.com/wenmin-wu): Minimum RSSI and moving average
- [stephengroat](https://github.com/stephengroat): CI
- [joeyhoer](https://github.com/joeyhoer): Homebrew Cask
- [Skyearn](https://github.com/Skyearn): Big Sur style icon
- [cyberclaus](https://github.com/cyberclaus): German, Swedish, Norwegian (Bokmål) and Danish localizations
- [alonewolfx2](https://github.com/alonewolfx2): Turkish localization
- [wernjie](https://github.com/wernjie): Wake without Unlocking
- [tokfrans03](https://github.com/tokfrans03): Language fixes


Icons are based on SVGs downloaded from materialdesignicons.com.
They are originally designed by Google LLC and licensed under Apache License version 2.0.

## License

MIT

Copyright © 2019-2022 Takeshi Sone.
