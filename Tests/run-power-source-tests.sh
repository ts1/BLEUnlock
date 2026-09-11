#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)
build_dir=$(mktemp -d "${TMPDIR:-/tmp}/bleunlock-power-source-tests.XXXXXX")
trap 'rm -rf "$build_dir"' EXIT HUP INT TERM

xcrun swiftc \
    -swift-version 5 \
    -module-cache-path "$build_dir/module-cache" \
    "$repo_dir/BLEUnlock/BLE.swift" \
    "$repo_dir/BLEUnlock/LEDeviceInfo.swift" \
    "$repo_dir/BLEUnlock/appleDeviceNames.swift" \
    "$repo_dir/BLEUnlock/PowerSourceMonitor.swift" \
    "$script_dir/PowerSourceTests/main.swift" \
    -framework CoreBluetooth \
    -framework Accelerate \
    -framework IOKit \
    -lsqlite3 \
    -o "$build_dir/power-source-tests"

"$build_dir/power-source-tests"
