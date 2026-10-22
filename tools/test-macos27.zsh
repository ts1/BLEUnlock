#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h:h}
run_test() {
    python3 - "$1" <<'PY'
import subprocess
import sys

try:
    result = subprocess.run([sys.argv[1]], timeout=45)
except subprocess.TimeoutExpired:
    print('Test timed out after 45 seconds. Run in a logged-in macOS GUI session.', file=sys.stderr)
    sys.exit(124)
sys.exit(result.returncode)
PY
}
mkdir -p "$project_dir/.build/tests/module-cache"
/usr/bin/xcrun swiftc -swift-version 5 \
    -module-cache-path "$project_dir/.build/tests/module-cache" \
    "$project_dir/BLEUnlock/ScreenLockState.swift" \
    "$project_dir/BLEUnlock/UnlockKeyboard.swift" \
    "$project_dir/tests/main.swift" \
    -o "$project_dir/.build/tests/regression"
run_test "$project_dir/.build/tests/regression"
/usr/bin/xcrun swiftc -swift-version 5 \
    -module-cache-path "$project_dir/.build/tests/module-cache" \
    "$project_dir/BLEUnlock/SystemUnlockTarget.swift" \
    "$project_dir/tests/UnlockTarget/main.swift" \
    -o "$project_dir/.build/tests/target-policy"
run_test "$project_dir/.build/tests/target-policy"
