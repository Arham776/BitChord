#!/bin/bash
# The remote library, against a real WebDAV server.
#
# Same reasoning as check-party-ui.sh's sibling: the parsers are unit-tested
# against fixtures, and a fixture cannot tell you that a client and a server
# disagree about a header. This starts a server that speaks the awkward parts of
# WebDAV — three href shapes, escaped names, real byte ranges, a real 401 — and
# drives the shipped bridge against it.
#
# Nothing here touches the app's settings permanently: the harness reads what is
# stored, sets its own share, and puts it back.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/.." && pwd)"
port="${WEBDAV_PORT:-8081}"
server_pid=""

cleanup() {
  if [[ -n "$server_pid" ]]; then kill "$server_pid" 2>/dev/null || true; fi
}
trap cleanup EXIT

if [[ -d /tmp/bitchord-webdav ]]; then rm -rf /tmp/bitchord-webdav; fi
python3 "$here/webdav-fixture.py" "$port" >/tmp/bitchord-webdav.log 2>&1 &
server_pid=$!

# Wait for it to answer rather than sleeping a fixed amount: a slow start should
# not read as a failure.
for _ in $(seq 1 40); do
  if curl -s -o /dev/null -m 1 "http://127.0.0.1:$port/"; then break; fi
  sleep 0.25
done

fw="$repo/AppleApp/Frameworks/BitChordShared.xcframework/macos-arm64"
bin="$(mktemp -d)/webdav-verify"
xcrun swiftc -O -o "$bin" \
  -F "$fw" -framework BitChordShared \
  -Xlinker -rpath -Xlinker "$fw/BitChordShared.framework/Versions/A" \
  "$here/webdav-verify/main.swift"

: >/tmp/bitchord-webdav-requests.log
WEBDAV_URL="http://localhost:$port/Music" "$bin"

echo ""
echo "requests, with how each was answered:"
awk '{print $1, $2, $3}' /tmp/bitchord-webdav-requests.log | sort | uniq -c | sed 's/^/  /'
