#!/bin/bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
# Compile the production clip cache without the unrelated audio-file cache.
python3 - "$repo" "$work" <<'PY'
import sys
from pathlib import Path
repo, work = map(Path, sys.argv[1:])
source = (repo / 'AppleApp/Sources/PlaybackSession/StreamFileCache.swift').read_text()
(work / 'CanvasFileCache.swift').write_text('import Foundation\nimport CryptoKit\n' + source[source.index('actor CanvasFileCache {'):])
PY
framework="$repo/AppleApp/Frameworks/BitChordShared.xcframework/macos-arm64"
xcrun swiftc -parse-as-library -O -module-cache-path /tmp/bitchord-swift-module-cache \
  -F "$framework" -framework BitChordShared \
  -Xlinker -rpath -Xlinker "$framework/BitChordShared.framework/Versions/A" \
  "$repo/AppleApp/Sources/PlaybackSession/CanvasMediaRequest.swift" \
  "$work/CanvasFileCache.swift" "$repo/scripts/canvas-verify/main.swift" \
  -o "$work/verify"
"$work/verify"
