#!/bin/sh
set -eu
TASK_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$TASK_ROOT"
mkdir -p build/clang-cache
xcrun swiftc -parse-as-library -swift-version 5 -target "$(uname -m)-apple-macos14.0" \
    -module-cache-path "$TASK_ROOT/build/clang-cache" \
    Sources/iOS/HomeScreenQuickActions.swift Tests/PortableContent/HomeScreenQuickActionChecks.swift \
    -o build/home-screen-quick-action-checks
build/home-screen-quick-action-checks
