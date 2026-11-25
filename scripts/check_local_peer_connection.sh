#!/bin/sh
set -eu
TASK_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$TASK_ROOT"
mkdir -p build/clang-cache
xcrun swiftc -parse-as-library -swift-version 6 -target "$(uname -m)-apple-macos14.0" \
    -module-cache-path "$TASK_ROOT/build/clang-cache" \
    Sources/DesktopShared/LocalPeerConnection.swift Tests/PortableContent/LocalPeerConnectionChecks.swift \
    -o build/local-peer-connection-checks
build/local-peer-connection-checks
