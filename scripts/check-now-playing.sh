#!/bin/bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
xcrun swiftc -parse-as-library -module-cache-path /tmp/bitchord-swift-module-cache \
  -o "$scratch/now-playing-verify" \
  "$repo/AppleApp/Sources/PlaybackSession/AudioSessionReadiness.swift" \
  "$repo/AppleApp/Sources/PlaybackSession/NowPlayingLifecycle.swift" \
  "$repo/scripts/now-playing-verify/main.swift"
"$scratch/now-playing-verify"
