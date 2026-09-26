#!/usr/bin/env bash
#
# The sign-in web view against Google's own answer.
#
# The reported failure was "This browser or app may not be secure" on iOS, before
# any password was typed — Google's refusal of an embedded web view. A test that
# only inspected the user-agent *string* would prove it is shaped like a desktop
# browser, which is necessary and nowhere near sufficient: only Google can say
# whether it will accept it.
#
# So this loads the real login URL in a real web view carrying the agent the app
# will use, and reads what Google says. It needs a network and takes a few
# seconds, and it is separate from `check-signin.sh` for that reason.
set -uo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
HERE="$(cd "$(dirname "$0")" && pwd)"
FW="$ROOT/AppleApp/Frameworks/BitChordShared.xcframework/macos-arm64"
CHECK_DIR="${TMPDIR:-/tmp}/bitchord-signin-live-check"

rm -rf "$CHECK_DIR"
mkdir -p "$CHECK_DIR"

xcrun swiftc -O -o "$CHECK_DIR/check" \
  -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
  -target arm64-apple-macos15.0 \
  -swift-version 5 \
  -framework WebKit -framework AppKit \
  -o "$CHECK_DIR/check" \
  "$ROOT/AppleApp/Sources/UI/SignInUserAgent.swift" \
  "$HERE/signin-live-verify/main.swift" || exit 2

"$CHECK_DIR/check"
