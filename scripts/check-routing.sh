#!/bin/bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
xcrun swiftc -parse-as-library -O -module-cache-path "$work/modules" -o "$work/verify" \
 "$repo/AppleApp/Sources/PlaybackSession/MacAudioRoutes.swift" \
 "$repo/AppleApp/Sources/PlaybackSession/HeadphoneRouting.swift" \
 "$repo/AppleApp/Sources/PlaybackSession/PlaybackDebugLog.swift" "$repo/scripts/http-verify/routing.swift"
"$work/verify"
