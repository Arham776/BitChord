#!/bin/bash
# LyricsPlus's mirror rotation, against the real mirrors.
#
# The health table exists because one mirror serves a certificate iOS will not
# accept, so every request to it fails ATS with -9802 and the system log fills
# with the same trust failure once per track. Racing the mirrors meant the
# source still worked, so the only symptom was noise — and the existing source
# sweep cannot see that, because it only records whether lyrics came back.
#
# This measures the cost instead: the same track three times, timed. The point
# is not that the source is fast, it is that the mirrors which cannot be reached
# stop being asked.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/.." && pwd)"

fw="$repo/AppleApp/Frameworks/BitChordShared.xcframework/macos-arm64"
bin="$(mktemp -d)/mirrors-verify"
xcrun swiftc -O -o "$bin" \
  -F "$fw" -framework BitChordShared \
  -Xlinker -rpath -Xlinker "$fw/BitChordShared.framework/Versions/A" \
  "$here/mirrors-verify/main.swift" || exit 2

exec "$bin"
