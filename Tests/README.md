# Power Source Regression Tests

Run the standalone tests from any directory:

```sh
Tests/run-power-source-tests.sh
```

The script compiles the production `BLE.swift`, `LEDeviceInfo.swift`, `appleDeviceNames.swift`, and `PowerSourceMonitor.swift` files into a temporary executable. The test BLE instance has no central manager, so it does not scan Bluetooth devices or invoke screen-lock behavior.

## Manual Checklist

- With **Automatically Lock Only on Battery** disabled, verify automatic low-RSSI and no-signal locking on both battery and external power.
- Enable the option, connect external power, and verify low RSSI and signal loss do not automatically lock the Mac. Repeat while AC is attached but the battery is not charging.
- While the option is enabled, unplug external power with the BLE device already absent. Verify a full **Delay to Lock** or **No-Signal Timeout** runs and returning the device cancels the pending lock.
- Sleep and wake the Mac on external power. Verify wake does not cause an immediate stale automatic lock, and automatic detection resumes normally after unplugging.
- On external power, use **Lock Screen Now**, then verify proximity-based unlock and wake behavior still work normally.
- Set **Lock RSSI** to **Disable**, toggle the option, and plug and unplug external power. Verify **Lock RSSI** stays disabled and BLEUnlock does not automatically lock.
