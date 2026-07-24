#!/bin/zsh

set -euo pipefail

repo_root="${0:A:h}/.."
test_binary="/tmp/BLEUnlock-DiagnosticsLoggerTests"

swiftc "$repo_root/BLEUnlock/DiagnosticsLogger.swift" \
    "$repo_root/Tests/DiagnosticsLoggerTests/main.swift" \
    -o "$test_binary"
"$test_binary"
