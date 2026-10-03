#!/bin/bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
bin="$(mktemp -d)/queue-verify"
xcrun swiftc -module-cache-path /tmp/bitchord-swift-module-cache -o "$bin" \
  "$repo/AppleApp/Sources/PlaybackSession/QueueEntry.swift" \
  "$repo/AppleApp/Sources/PlaybackSession/PlaybackQueuePolicy.swift" \
  "$repo/AppleApp/Sources/PlaybackSession/LastPlayed.swift" \
  "$repo/scripts/queue-verify/main.swift"
"$bin"
