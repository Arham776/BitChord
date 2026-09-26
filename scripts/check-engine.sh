#!/bin/bash
# The engine, on a real output device.
#
# The one part of this app a fixture cannot check. A WAV in a temp directory
# proves the decoder reads bytes; it cannot prove the mixer thread fills the ring
# or that the device callback drains it, and those are exactly the two places
# the reported "shows as playing, no sound, then one stutter" bug lived. So this
# harness plays actual sound through the actual device and reads the playhead
# back off the engine.
#
# Needs a machine with an output device — it is a Mac-only check, which is
# correct, since the iOS half of this (an AVAudioSession that must be active
# before the unit exists) cannot be exercised off-device at all.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/.." && pwd)"

fw="$repo/AppleApp/Frameworks/NativeCoreFFI.xcframework/macos-arm64"
if [ ! -d "$fw" ]; then
  echo "no NativeCoreFFI for macos-arm64 — run scripts/build-native-core.sh first" >&2
  exit 2
fi

bin="$(mktemp -d)/engine-verify"
# The UniFFI bindings are compiled *into* the app target rather than shipped as
# a module, so the harness does the same: the generated Swift alongside it, with
# the framework linked for the C symbols it calls.
xcrun swiftc -O -o "$bin" \
  -F "$fw" -framework NativeCoreFFI \
  -framework CoreAudio -framework AudioToolbox -framework CoreFoundation \
  -Xlinker -rpath -Xlinker "$fw/NativeCoreFFI.framework/Versions/A" \
  "$repo/AppleApp/Generated/NativeCore.swift" \
  "$here/engine-verify/main.swift" || exit 2

# The engine reads RUST_LOG for its own diagnostics; info keeps the voice open
# and output-rate line so a failure here can be read against the app's.
exec "$bin"
