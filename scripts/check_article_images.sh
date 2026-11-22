#!/bin/sh
set -eu
TASK_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$TASK_ROOT"
# Reuse the caller's built core; this isolated check never starts a shared build.
TASK_CORE_BIN="${QINGKONG_ARTICLE_CORE_BIN:-$TASK_ROOT/build/portable-download-core/$(uname -m)-apple-macosx/debug}"
test -f "$TASK_CORE_BIN/Modules/QingkongCore.swiftmodule" || { echo "Build QingkongCore before running the article image check." >&2; exit 1; }
xcrun swiftc -parse-as-library -swift-version 5 -target "$(uname -m)-apple-macos14.0" \
    -module-cache-path "$TASK_ROOT/build/clang-cache" -I "$TASK_CORE_BIN/Modules" \
    Sources/Shared/ArticleImageCache.swift Sources/Shared/ContentLibrary.swift Tests/PortableContent/ArticleImageChecks.swift \
    "$TASK_CORE_BIN"/QingkongCore.build/*.o -o build/portable-article-image-checks
build/portable-article-image-checks "$TASK_ROOT/Tests/Fixtures/PublicContent/snapshot.json"
