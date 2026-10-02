#!/usr/bin/env bash
# Actual WebKit capture/verification flow, using only synthetic HTML and cookies.
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fw="$repo/AppleApp/Frameworks/BitChordShared.xcframework/macos-arm64"
xcrun swiftc -parse-as-library -module-cache-path "$work/modules" \
  -target arm64-apple-macos15.0 -swift-version 5 \
  -F "$fw" -framework BitChordShared \
  -Xlinker -rpath -Xlinker "$fw/BitChordShared.framework/Versions/A" \
  "$repo/AppleApp/Sources/UI/SignInNavigation.swift" \
  "$repo/AppleApp/Sources/UI/SignInUserAgent.swift" \
  "$repo/AppleApp/Sources/UI/SignInCapture.swift" \
  "$repo/AppleApp/Sources/UI/YtMusicLoginView.swift" \
  "$repo/AppleApp/Sources/App/GuardedHTTP.swift" \
  "$repo/scripts/signin-webview-verify/main.swift" -o "$work/check"
"$work/check"
