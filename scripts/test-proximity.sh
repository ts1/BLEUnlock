#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
xcrun swiftc -swift-version 5 BLEUnlock/ProximityEvidence.swift Tests/main.swift -o build/proximity-tests
build/proximity-tests
