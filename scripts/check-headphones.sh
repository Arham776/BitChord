#!/bin/bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fw="$repo/AppleApp/Frameworks/NativeCoreFFI.xcframework/macos-arm64"
xcrun swiftc -parse-as-library -O -module-cache-path "$work/modules" -o "$work/verify" \
 -F "$fw" -framework NativeCoreFFI -framework CoreAudio -framework AudioToolbox \
 "$repo/AppleApp/Generated/NativeCore.swift" "$repo/AppleApp/Sources/PlaybackSession/HeadphoneRouting.swift" \
 "$repo/AppleApp/Sources/PlaybackSession/PlaybackDebugLog.swift" "$repo/scripts/headphones-verify/main.swift"
"$work/verify"
