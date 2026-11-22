#!/bin/sh
set -eu
if [ "${1:-}" != "--network" ]; then
    printf '%s\n' '此检查会实际下载测试音源；请用 --network 明确启用（两次完整文件及一次中途取消）。' >&2
    exit 2
fi
TASK_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$TASK_ROOT"
export CLANG_MODULE_CACHE_PATH="$TASK_ROOT/build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$TASK_ROOT/build/swift-cache"
swift build --disable-sandbox --package-path Packages/QingkongCore --scratch-path build/portable-download-core --cache-path build/package-cache
TASK_CORE_BIN="$(swift build --disable-sandbox --package-path Packages/QingkongCore --scratch-path build/portable-download-core --cache-path build/package-cache --show-bin-path)"
xcrun swiftc -parse-as-library -swift-version 5 -target "$(uname -m)-apple-macos14.0" \
    -module-cache-path "$TASK_ROOT/build/clang-cache" -I "$TASK_CORE_BIN/Modules" \
    Sources/Shared/AudioDownloads.swift Tests/PortableContent/LiveAudioDownloadChecks.swift \
    "$TASK_CORE_BIN"/QingkongCore.build/*.o -o build/live-audio-download-checks
build/live-audio-download-checks "$TASK_ROOT/Tests/Fixtures/PublicContent/snapshot.json"
