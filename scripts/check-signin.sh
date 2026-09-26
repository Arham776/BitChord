#!/usr/bin/env bash
#
# What the sign-in web view is allowed to navigate to.
#
# The reported bug was the sign-in handing the listener to the YouTube Music app
# mid-flow and losing the session with it. A bug in a navigation delegate is
# invisible until someone tries to sign in, and by then it looks like a broken
# account rather than a broken rule — so the rule is compiled from the app's own
# source and asked directly.
#
# No web view, no window server session, no network, no human: it is a decision
# about a URL, and is answered as one.
set -uo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
HERE="$(cd "$(dirname "$0")" && pwd)"
CHECK_DIR="${TMPDIR:-/tmp}/bitchord-signin-check"

rm -rf "$CHECK_DIR"
mkdir -p "$CHECK_DIR"

xcrun swiftc \
  -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
  -target arm64-apple-macos15.0 \
  -swift-version 5 \
  -o "$CHECK_DIR/check" \
  "$ROOT/AppleApp/Sources/UI/SignInNavigation.swift" \
  "$HERE/signin-verify/main.swift" || exit 2

"$CHECK_DIR/check"
