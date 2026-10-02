#!/bin/bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
fw="$repo/AppleApp/Frameworks/NativeCoreFFI.xcframework/macos-arm64"
xcrun swiftc -O -module-cache-path /tmp/bitchord-swift-module-cache -o "$scratch/verify" \
  -F "$fw" -framework NativeCoreFFI -framework AVFoundation \
  -framework CoreAudio -framework AudioToolbox -framework CoreFoundation \
  -Xlinker -rpath -Xlinker "$fw/NativeCoreFFI.framework/Versions/A" \
  "$repo/AppleApp/Generated/NativeCore.swift" \
  "$repo/AppleApp/Sources/PlaybackSession/AppleDolbyRenderer.swift" \
  "$repo/scripts/dolby-verify/main.swift"
"$scratch/verify" "${DOLBY_TEST_URL:-https://devstreaming-cdn.apple.com/videos/streaming/examples/adv_dv_atmos/Job932393e2-1e4f-4fdb-ab59-0d201f752656-107660254-Transcode_audio_full_en_atmos_0_1-en_audio/prog_index.m3u8}"
