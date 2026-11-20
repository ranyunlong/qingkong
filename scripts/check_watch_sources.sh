#!/bin/sh
set -eu
PROJECT_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$PROJECT_ROOT"
WATCH_SDK="$(xcrun --sdk watchos --show-sdk-path)"
for TASK_ARCH in arm64_32 arm64; do
    TASK_OUTPUT="build/WatchCodeCheck/$TASK_ARCH"
    mkdir -p "$TASK_OUTPUT"
    xcrun swiftc -emit-module -parse-as-library -module-name QingkongCore \
        -swift-version 6 -sdk "$WATCH_SDK" -target "$TASK_ARCH-apple-watchos11.0" \
        -module-cache-path "$PROJECT_ROOT/build/WatchTypecheckCache" \
        -emit-module-path "$TASK_OUTPUT/QingkongCore.swiftmodule" \
        Packages/QingkongCore/Sources/QingkongCore/*.swift
    xcrun swiftc -typecheck -parse-as-library -module-name QingkongWatch \
        -swift-version 5 -DDEBUG -sdk "$WATCH_SDK" -target "$TASK_ARCH-apple-watchos11.0" \
        -module-cache-path "$PROJECT_ROOT/build/WatchTypecheckCache" -I "$TASK_OUTPUT" \
        Sources/Shared/*.swift Sources/Watch/*.swift
    xcrun swiftc -typecheck -parse-as-library -module-name QingkongWidgets \
        -swift-version 5 -sdk "$WATCH_SDK" -target "$TASK_ARCH-apple-watchos11.0" \
        -module-cache-path "$PROJECT_ROOT/build/WatchTypecheckCache" -I "$TASK_OUTPUT" \
        Sources/Shared/SnapshotStorage.swift Sources/Shared/Appearance.swift Sources/WidgetShared/*.swift Sources/Widgets/*.swift
    printf 'Watch App and Widget source checks passed: %s\n' "$TASK_ARCH"
done
printf 'Source checks do not verify resource packaging, installation, or runtime behavior.\n'
