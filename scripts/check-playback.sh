#!/bin/bash
# Playback resolution, against YouTube.
#
# The one thing in this app a fixture cannot check: whether a stream URL can be
# minted *and served*. Resolves a few real tracks and then reads a real 64 KiB
# window off each minted URL, because a resolution that hands back something the
# engine cannot read is not a resolution — and accepting one is exactly how the
# muxed-format bug shipped.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/.." && pwd)"

fw="$repo/AppleApp/Frameworks/BitChordShared.xcframework/macos-arm64"
bin="$(mktemp -d)/playback-verify"
xcrun swiftc -O -o "$bin" \
  -F "$fw" -framework BitChordShared \
  -Xlinker -rpath -Xlinker "$fw/BitChordShared.framework/Versions/A" \
  "$here/playback-verify/main.swift"

exec "$bin"
