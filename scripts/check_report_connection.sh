#!/bin/sh
set -eu
TASK_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$TASK_ROOT"
export CLANG_MODULE_CACHE_PATH="$TASK_ROOT/build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$TASK_ROOT/build/swift-cache"
swift build --disable-sandbox --package-path Packages/QingkongCore --scratch-path build/portable-download-core --cache-path build/package-cache
TASK_CORE_BIN="$(swift build --disable-sandbox --package-path Packages/QingkongCore --scratch-path build/portable-download-core --cache-path build/package-cache --show-bin-path)"
xcrun swiftc -parse-as-library -swift-version 5 -target "$(uname -m)-apple-macos14.0" \
    -module-cache-path "$TASK_ROOT/build/clang-cache" -I "$TASK_CORE_BIN/Modules" \
    Sources/DesktopShared/LocalPeerConnection.swift Sources/DesktopShared/PhoneMacPeer.swift \
    Tests/PortableContent/ReportConnectionChecks.swift \
    "$TASK_CORE_BIN"/QingkongCore.build/*.o -o build/report-connection-checks
build/report-connection-checks
