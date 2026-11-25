#!/bin/sh
set -eu
TASK_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$TASK_ROOT"
export CLANG_MODULE_CACHE_PATH="$TASK_ROOT/build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$TASK_ROOT/build/swift-cache"
swift build --disable-sandbox --package-path Packages/QingkongCore --scratch-path build/portable-download-core --cache-path build/package-cache
TASK_CORE_BIN="$(swift build --disable-sandbox --package-path Packages/QingkongCore --scratch-path build/portable-download-core --cache-path build/package-cache --show-bin-path)"
TASK_BUNDLE="$TASK_ROOT/build/MacMusicPlayerChecks.bundle"
mkdir -p "$TASK_BUNDLE/Contents/MacOS" "$TASK_BUNDLE/Contents/Resources"
cp Resources/Audio/*.wav "$TASK_BUNDLE/Contents/Resources/"
xcrun swiftc -parse-as-library -swift-version 5 -target "$(uname -m)-apple-macos14.0" \
    -module-cache-path "$TASK_ROOT/build/clang-cache" -I "$TASK_CORE_BIN/Modules" \
    Sources/DesktopShared/LocalPeerConnection.swift Sources/DesktopShared/DesktopAccountTrust.swift Sources/DesktopShared/PhoneMacPeer.swift \
    Sources/Mac/Stores/MacReportCache.swift Sources/Mac/Services/MacDeviceConnection.swift \
    Sources/Shared/ArticleImageCache.swift Sources/Shared/ContentLibrary.swift Sources/Shared/AudioDownloads.swift \
    Sources/Mac/Services/MacLibrary.swift Sources/Mac/Services/MacAlbumArtworkCache.swift \
    Sources/Mac/Services/MacSystemPlayback.swift Sources/Mac/Services/MacAudioPlayer.swift Tests/PortableContent/MacMusicPlayerChecks.swift \
    "$TASK_CORE_BIN"/QingkongCore.build/*.o -o "$TASK_BUNDLE/Contents/MacOS/MacMusicPlayerChecks"
"$TASK_BUNDLE/Contents/MacOS/MacMusicPlayerChecks"
xcrun swiftc -parse-as-library -swift-version 5 -target "$(uname -m)-apple-macos14.0" \
    -module-cache-path "$TASK_ROOT/build/clang-cache" -I "$TASK_CORE_BIN/Modules" \
    Sources/DesktopShared/LocalPeerConnection.swift Sources/DesktopShared/DesktopAccountTrust.swift Sources/DesktopShared/PhoneMacPeer.swift \
    Sources/Mac/Stores/MacReportCache.swift Sources/Mac/Services/MacDeviceConnection.swift \
    Sources/Shared/ArticleImageCache.swift Sources/Shared/ContentLibrary.swift Sources/Shared/AudioDownloads.swift \
    Sources/Mac/Services/MacLibrary.swift Sources/Mac/Services/MacAlbumArtworkCache.swift \
    Sources/Mac/Services/MacSystemPlayback.swift Sources/Mac/Services/MacAudioPlayer.swift Tests/PortableContent/MacLibraryChecks.swift \
    "$TASK_CORE_BIN"/QingkongCore.build/*.o -o "$TASK_BUNDLE/Contents/MacOS/MacLibraryChecks"
"$TASK_BUNDLE/Contents/MacOS/MacLibraryChecks"
