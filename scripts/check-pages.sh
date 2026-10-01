#!/bin/bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
xcrun swiftc -parse-as-library -O -module-cache-path "$work/modules" -o "$work/verify" \
 "$repo/AppleApp/Sources/App/PageRepository.swift" "$repo/scripts/pages-verify/main.swift"
"$work/verify"
