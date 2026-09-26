#!/bin/bash
# The Explore category grid, against YouTube Music.
#
# A fixture can only prove the parser reads the body it was handed. It cannot
# prove that FEmusic_moods_and_genres still answers, that its sections are
# gridRenderers, that the buttons are musicNavigationButtonRenderers, or that a
# browseEndpoint carries params at all. Every one of those is a claim about the
# server, and they go stale quietly — the response changes shape, the parser
# returns an empty list, and the feature reads as "there are no moods today".
#
# The check that matters most is the last one: a category's shelves have to come
# back with content *and* its params have to be honoured, because a category
# browsed without its params answers with a different, generic page rather than
# an error. That failure looks like a working feature returning the wrong thing.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/.." && pwd)"

fw="$repo/AppleApp/Frameworks/BitChordShared.xcframework/macos-arm64"
bin="$(mktemp -d)/moods-verify"
xcrun swiftc -O -o "$bin" \
  -F "$fw" -framework BitChordShared \
  -Xlinker -rpath -Xlinker "$fw/BitChordShared.framework/Versions/A" \
  "$here/moods-verify/main.swift" || exit 2

exec "$bin"
