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
# The rule is "a sign-in has no exits": every web page loads in place, and only a
# scheme that is not http(s) is refused. The harness also reads the sign-in view's
# source and asserts it contains no call that can open anything outside the app,
# because the bug was not "the wrong host was allowed" — it was "there was a
# branch here that opened things elsewhere", and a host-level check passes happily
# while that branch is still in the file.
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
  "$ROOT/AppleApp/Sources/UI/SignInUserAgent.swift" \
  "$HERE/signin-verify/main.swift" || exit 2

# The repository root goes in so the harness can read the sign-in view's own
# source and assert it holds no call that could hand a URL to another app.
"$CHECK_DIR/check" "$ROOT"
