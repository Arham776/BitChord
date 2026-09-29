#!/bin/bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
bin="$(mktemp -d)/transport-verify"
xcrun swiftc -module-cache-path /tmp/bitchord-swift-module-cache -o "$bin" \
  "$repo/AppleApp/Sources/PlaybackSession/PlaybackLoadSubmissionGate.swift" \
  "$repo/scripts/transport-verify/main.swift"
"$bin"
