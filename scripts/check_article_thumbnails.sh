#!/bin/sh
set -eu
TASK_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$TASK_ROOT"
TASK_CORE_BIN="$TASK_ROOT/build/portable-download-core/$(uname -m)-apple-macosx/debug"
TASK_IMAGE_SOURCE="Sources/Shared/ArticleImageCache.swift"
if [ "${1:-}" = "--baseline" ]; then
    TASK_IMAGE_SOURCE="artifacts/mac-ui-before/ArticleImageCache.swift"
    set -- -D THUMBNAIL_BASELINE
else
    set --
fi
xcrun swiftc -parse-as-library -swift-version 5 -target "$(uname -m)-apple-macos14.0" "$@" \
    -module-cache-path "$TASK_ROOT/build/clang-cache" -I "$TASK_CORE_BIN/Modules" \
    "$TASK_IMAGE_SOURCE" Tests/PortableContent/ArticleThumbnailChecks.swift \
    "$TASK_CORE_BIN"/QingkongCore.build/*.o -o build/portable-article-thumbnail-checks
build/portable-article-thumbnail-checks
