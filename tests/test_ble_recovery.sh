#!/bin/zsh

set -euo pipefail

source_file="${0:A:h}/../BLEUnlock/BLE.swift"

rg -q 'didDisconnectPeripheral' "$source_file"
rg -q 'didFailToConnect peripheral' "$source_file"
rg -q 'func recoverMonitoredPeripheral' "$source_file"

echo "BLE recovery hooks are present"
