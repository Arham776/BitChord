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
verification_dir="$(mktemp -d)"
bin="$verification_dir/playback-verify"
# Supply the app-owned cookie storage identity to Foundation in this CLI host.
cat > "$verification_dir/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>app.bitchord.playback-verification</string><key>BitChordAppGroupIdentifier</key><string>group.app.bitchord.playback-verification</string></dict></plist>
PLIST
xcrun swiftc -O -module-cache-path /tmp/bitchord-swift-module-cache -o "$bin" \
  -F "$fw" -framework BitChordShared -framework WebKit \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$verification_dir/Info.plist" \
  -Xlinker -rpath -Xlinker "$fw/BitChordShared.framework/Versions/A" \
  "$repo/AppleApp/Sources/App/YouTubeChallengeSolver.swift" \
  "$repo/AppleApp/Sources/App/YouTubePlayerJs.swift" \
  "$repo/AppleApp/Sources/App/ApplePoTokenProvider.swift" \
  "$here/playback-verify/main.swift"

exec "$bin" "$repo/AppleApp/Resources/YouTubeSolver"
