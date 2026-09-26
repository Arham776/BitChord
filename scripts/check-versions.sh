#!/bin/bash
# Revert-to-original pins, through the real Swift→Kotlin seam.
#
# The codec is tested in shared/commonTest. What that cannot reach is the call
# site: a mistyped argument label, a nil the seam hands over as something other
# than nil, a write that lands somewhere the reader does not look. This crosses
# the boundary, and checks the write-through — "pinned in memory" and "still
# pinned after a restart" are different claims, and the second is the whole
# reason this is a store rather than a set in a controller.
#
# Writes to the same NSUserDefaults the app reads, and restores what it found.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/.." && pwd)"

fw="$repo/AppleApp/Frameworks/BitChordShared.xcframework/macos-arm64"
bin="$(mktemp -d)/versions-verify"
xcrun swiftc -O -o "$bin" \
  -F "$fw" -framework BitChordShared \
  -Xlinker -rpath -Xlinker "$fw/BitChordShared.framework/Versions/A" \
  "$here/versions-verify/main.swift" || exit 2

exec "$bin"
