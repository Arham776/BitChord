#!/bin/bash
# The account store and the channel override, through the real Swift→Kotlin seam.
#
# The shared tests cover the id chains and the ordering. What none of them can
# reach is the part that actually matters: whether selecting a channel changes the
# identity the *requests* carry. A channel override that is stored correctly and
# never applied produces an account selector that looks perfect and browses as
# the wrong channel, and nothing on screen would say so — so these checks read
# Innertube's own answers back rather than the store's.
#
# Uses an isolated synthetic secret store; never touches real account credentials.
#
# One environment note the harness reports out loud rather than hiding: an
# unentitled command-line binary cannot use macOS's data-protection keychain, so
# it checks the store's logic against a `memory-backed substitute and says
# so in its output. That is a property of the harness binary, not of the app —
# the app is signed with a `keychain-access-groups` entitlement and uses the real
# thing.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/.." && pwd)"

fw="$repo/AppleApp/Frameworks/BitChordShared.xcframework/macos-arm64"
bin="$(mktemp -d)/accounts-verify"
xcrun swiftc -O -o "$bin" \
  -F "$fw" -framework BitChordShared \
  -Xlinker -rpath -Xlinker "$fw/BitChordShared.framework/Versions/A" \
  -framework Security \
  "$repo/AppleApp/Sources/App/Keychain.swift" \
  "$here/accounts-verify/main.swift" || exit 2

exec "$bin"
