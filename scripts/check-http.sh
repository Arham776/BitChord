#!/bin/bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
server=""
cleanup() { if [[ -n "$server" ]]; then kill "$server" 2>/dev/null || true; fi; rm -rf "$work"; }
trap cleanup EXIT
python3 "$repo/scripts/http-verify/fixture.py" "$work/config.json" > "$work/server.log" 2>&1 &
server=$!
for _ in {1..40}; do if [[ -f "$work/config.json" ]]; then break; fi; sleep 0.1; done
fw="$repo/AppleApp/Frameworks/BitChordShared.xcframework/macos-arm64"
cat > "$work/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>app.bitchord.http-verification</string><key>BitChordAppGroupIdentifier</key><string>group.app.bitchord.http-verification</string></dict></plist>
PLIST
xcrun swiftc -parse-as-library -O -module-cache-path "$work/modules" -o "$work/verify" \
 -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$work/Info.plist" \
 -F "$fw" -framework BitChordShared -Xlinker -rpath -Xlinker "$fw/BitChordShared.framework/Versions/A" \
 "$repo/AppleApp/Sources/App/GuardedHTTP.swift" "$repo/scripts/http-verify/main.swift"
"$work/verify" "$work/config.json"
