# BLEUnlock

BLEUnlock is a small menu bar utility that locks and unlocks your Mac with your iPhone, Apple Watch, or any other Bluetooth Low Energy devices.

This document is also available in [Japanese](README.ja.md).

## Features

- No iPhone app is required
- Works with any BLE devices that periodically send signal
- Unlocks your Mac for you when the device is near Mac, no need to enter password again
- Locks your Mac when the device is away from Mac
- Optionally wakes from display sleep state
- Optionally pauses and unpauses iTunes playback when you're away and back
- Password is securely stored in Keychain

## Requirements

- Mac with Bluetooth Low Energy support
- macOS 10.13 (High Sierra) or later
- iPhone 5s or later, Apple Watch (all), or other BLE device that transmits
signal periodically

## Installation

Download zip file from [Releases](https://github.com/ts1/BLEUnlock/releases),
unzip and copy to Applications folder.

On the first launch, it asks your login password,
which is required to unlock the lock screen.
It's safe because it's stored in Keychain. 

Then it asks for permission for Accessibility.
In System Preferences, click the lock icon to unlock and turn BLEUnlock on.
This permission is also required to unlock the lock screen.

Finally, from the menu bar icon, select "Device".
It starts scanning nearby BLE devices.
Select your device, and you're done!

## Troubleshooting

If it fails to unlock, check BLEUnlock is turned on in "System Preferences" →
"Security & Privacy" → "Privacy" → "Accessibility".
If it is already on, try turning it off and on again.

If it asks for permission to access its own password, click "Always Allow",
because it is needed while the screen is locked.

If "Signal is lost" occurs frequently, turn Bluetooth of Mac off then on.
Or use a device that sends signal more frequently.

### Why does it sometimes take long time to unlock?

Short answer: wake your iPhone.

From version 1.4.1, BLEUnlock assumes the device is away
when Mac enters system sleep and Bluetooth hardware is powered off
(typically 15-30 seconds after the lid is closed).
This is required for security.
Consequently, it sometimes takes up to several seconds to unlock when Mac wakes
from system sleep.

This is because BLEUnlock has lost connection to the device and has to wait
for the device to send signal.
Usually, devices send signal less frequently when it is in sleep mode.
Thus, if you wake the device, in most cases it sends signal promptly,
and BLEUnlock unlocks.

### Passive mode and Bluetooth Internet Sharing

By default BLEUnlock actively connects to the device to read RSSI
(signal strength).
It is the best way to steadily read RSSI for devices such as iPhone that
support it.
However, it does not play nice with Bluetooth Internet Sharing.

With Passive Mode, BLEUnlock only passively receives signals that the deveice
broadcasts.
That does not interfere with Bluetooth Internet Sharing.

If you use Bluetooth Internet Sharing on the same device, turn Passive Mode on.
If you don't, turn it off.

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

> NOTE: for `intruded` event works properly, you have to set *Require password immediately after sleep* in Security & Privacy.

### Example

Here is an example script which sends LINE Notify message, with a photo of the person in front of Mac when unlocked manually.

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

This is required because BLEUnlock does not have Camera permission.
Giving permission to this app resolve the problem.

## Credits

- peiit: Chinese translation
- wenmin-wu: Minimum RSSI and moving average
- stephengroat: CI

Icons are based on SVGs downloaded from materialdesignicons.com.
They are originally designed by Google LLC and licensed under Apache License
version 2.0.

## License

MIT

Copyright © 2019-2020 Takeshi Sone.
