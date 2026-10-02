#!/bin/bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
fw="$repo/AppleApp/Frameworks/BitChordShared.xcframework/macos-arm64"
xcrun swiftc -O -module-cache-path /tmp/bitchord-swift-module-cache -o "$scratch/verify" \
  -F "$fw" -framework BitChordShared \
  -Xlinker -rpath -Xlinker "$fw/BitChordShared.framework/Versions/A" \
  "$repo/AppleApp/Sources/PlaybackSession/SourceSubstitution.swift" "$repo/scripts/source-bridge-verify/main.swift"
"$scratch/verify"
