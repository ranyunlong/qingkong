#!/bin/sh
set -eu
TASK_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$TASK_ROOT"
TASK_MEDIA="${1:-$TASK_ROOT/build/TestPlaylistMedia}"
if [ ! -d "$TASK_MEDIA" ]; then
    printf '%s\n' '需要本地测试音频目录；本检查不会自动下载媒体。' >&2
    exit 1
fi
export CLANG_MODULE_CACHE_PATH="$TASK_ROOT/build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$TASK_ROOT/build/swift-cache"
swift build --disable-sandbox --package-path Packages/QingkongCore --scratch-path build/portable-download-core --cache-path build/package-cache
TASK_CORE_BIN="$(swift build --disable-sandbox --package-path Packages/QingkongCore --scratch-path build/portable-download-core --cache-path build/package-cache --show-bin-path)"
xcrun swiftc -parse-as-library -swift-version 5 -target "$(uname -m)-apple-macos14.0" \
    -module-cache-path "$TASK_ROOT/build/clang-cache" -I "$TASK_CORE_BIN/Modules" \
    Sources/Shared/AudioDownloads.swift Tests/PortableContent/TestPlaylistChecks.swift \
    "$TASK_CORE_BIN"/QingkongCore.build/*.o -o build/test-playlist-checks
build/test-playlist-checks "$TASK_ROOT/Tests/Fixtures/PublicContent/snapshot.json" "$TASK_MEDIA"
