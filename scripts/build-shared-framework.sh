#!/usr/bin/env bash
# Kotlin/Native -> BitChordShared.xcframework (spec §0/§1.1), copied into
# AppleApp/Frameworks/ for xcodegen to consume.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Fall back to Android Studio's bundled JetBrains Runtime when no usable JDK
# exists. Note: macOS ships a /usr/bin/java stub that passes `command -v` but
# fails at runtime, so probe `java -version` rather than mere presence.
if [ -z "${JAVA_HOME:-}" ]; then
  if ! java -version >/dev/null 2>&1; then
    JBR="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
    if [ -x "$JBR/bin/java" ]; then
      export JAVA_HOME="$JBR"
    else
      echo "error: no usable JDK found — install one or set JAVA_HOME" >&2
      exit 1
    fi
  fi
fi

# Kotlin/Native's embedded C dependencies otherwise inherit the active SDK's
# version (for example iOS 26.5), making their object files too new for the
# application's iOS 18 / macOS 15 deployment targets.
export IPHONEOS_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-18.0}"
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-15.0}"

# Full task name required — `assembleBitChordShared` alone is ambiguous
# (KGP also creates Debug/Release variants).
./gradlew :shared:assembleBitChordSharedXCFramework

# KGP emits separate debug/ and release/ xcframeworks, and
# `xcodebuild -create-xcframework` refuses two libraries with the same
# platform identifier, so the two configurations cannot live in one
# xcframework. Package one configuration (debug by default — right for
# development; use CONFIG=release for distribution builds).
CFG="${CONFIG:-debug}"
SRC="shared/build/XCFrameworks/$CFG/BitChordShared.xcframework"
DEST="AppleApp/Frameworks/BitChordShared.xcframework"
mkdir -p AppleApp/Frameworks
rm -rf "$DEST"
cp -R "$SRC" "$DEST"
echo "OK: $DEST (configuration: $CFG)"
