# BLEUnlock

Lock/Unlock your Mac with your iPhone, Apple Watch, or any other Bluetooth LE device.

## Features

- No iPhone app is required
- Works with any BLE devices that periodically send signal
- Locks Mac when the specified device is away from Mac
- Unlocks Mac for you when the device is near Mac, no need to enter password again
- Optionally wakes from display sleep state
- Password is securely stored in Keychain

## Installation

Unzip and copy BLEUnlock to Applications folder.

On the first launch, it asks your login password,
which is required to unlock the lock screen.
It's safe because it's stored in Keychain. 

Then it asks for permission for Accessibility.
In System Preferences unlock by clicking lock icon and turn BLEUnlock on.
It is also required to unlock the lock screen.

## Troubleshooting

If it fails to unlock, check BLEUnlock is turned on in "System Preferences" → "Security & Privacy" → "Privacy" → "Accessibility".
If it is already on, try turning it off and on again.

If it asks for permission to access its own password, click "Always Allow", because it is needed while the screen is locked.

## Acknowledgement

Icon is based on `lock-open.svg` downloaded from materialdesignicons.com.

## License

MIT

Copyright © 2019 by Takeshi Sone.
