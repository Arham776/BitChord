#!/bin/bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
python3 - "$scratch/hires.wav" <<'PY'
import math, sys, wave
with wave.open(sys.argv[1], 'wb') as wav:
    wav.setnchannels(2); wav.setsampwidth(3); wav.setframerate(96000)
    frames = bytearray()
    for i in range(96000 * 3):
        value = int(math.sin(2 * math.pi * 440 * i / 96000) * 1000000)
        frames.extend(value.to_bytes(3, 'little', signed=True) * 2)
    wav.writeframes(frames)
PY
/usr/bin/afconvert -f m4af -d alac "$scratch/hires.wav" "$scratch/hires.m4a"
fw="$repo/AppleApp/Frameworks/NativeCoreFFI.xcframework/macos-arm64"
xcrun swiftc -O -module-cache-path /tmp/bitchord-swift-module-cache -o "$scratch/verify" \
  -F "$fw" -framework NativeCoreFFI \
  -framework CoreAudio -framework AudioToolbox -framework CoreFoundation \
  -Xlinker -rpath -Xlinker "$fw/NativeCoreFFI.framework/Versions/A" \
  "$repo/AppleApp/Generated/NativeCore.swift" "$repo/scripts/quality-verify/main.swift"
"$scratch/verify" "$scratch/hires.wav" "$scratch/hires.m4a"
