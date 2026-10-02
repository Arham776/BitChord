#!/usr/bin/env bash
# native-core -> NativeCoreFFI.xcframework + UniFFI-generated Swift bindings
# (spec §0/§2/§7). Kotlin bindings are emitted too, but are the plain-JVM
# flavour — placeholder only until the KMP-aware route is wired at milestone 5.
#
# The framework bundle is named NativeCoreFFI (not NativeCore) because a
# `framework module` in a modulemap must match its bundle name, and the
# generated Swift imports the FFI module `NativeCoreFFI`.
# Building native-core also builds bundled libopus; install CMake and put it on
# PATH before running this script.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT/native-core"
# Cursor (and some CI sandboxes) redirect CARGO_TARGET_DIR; UniFFI bindgen and
# the xcframework copy below read native-core/target/… so force the local dir.
unset CARGO_TARGET_DIR
# Match AppleApp/project.yml deployment targets (iOS 18, macOS 15) — avoids
# "was built for newer macOS version (26.5) than being linked (15.0)" warnings
# and keeps the Rust standard library's darwin thread-parking QoS aligned.
export MACOSX_DEPLOYMENT_TARGET=15.0
export IPHONEOS_DEPLOYMENT_TARGET=18.0
export IPHONESIMULATOR_DEPLOYMENT_TARGET=18.0

TARGETS=(
  aarch64-apple-darwin
  aarch64-apple-ios
  aarch64-apple-ios-sim
)

for t in "${TARGETS[@]}"; do
  cargo build --release --target "$t"
done

# UniFFI publishes no standalone bindgen CLI crate — the official route is the
# in-crate `uniffi-bindgen` bin (native-core/uniffi-bindgen.rs), which also
# guarantees the bindgen version matches the uniffi crate exactly.
BINDGEN=(cargo run --release --quiet --features uniffi/cli --bin uniffi-bindgen --)

BINDINGS="$ROOT/native-core/bindings"
rm -rf "$BINDINGS/swift" "$BINDINGS/kotlin"
mkdir -p "$BINDINGS/swift" "$BINDINGS/kotlin"

# Bindings are target-independent; generate from the host build.
HOST_LIB="target/aarch64-apple-darwin/release/libnative_core.a"
"${BINDGEN[@]}" generate --library "$HOST_LIB" --language swift --out-dir "$BINDINGS/swift"
"${BINDGEN[@]}" generate --library "$HOST_LIB" --language kotlin --out-dir "$BINDINGS/kotlin" || \
  echo "warning: Kotlin binding generation failed (non-fatal at milestone 1)" >&2

# Normalize crate-name casing to NativeCore / NativeCoreFFI. Replace every
# occurrence of the FFI module name — the generated file also contains a
# case-sensitive canImport() guard, not just the import line.
SWIFT_SRC="$(ls "$BINDINGS/swift/"*.swift | head -1)"
HEADER_SRC="$(ls "$BINDINGS/swift/"*.h | head -1)"
FFI_MODULE="$(basename "$HEADER_SRC" .h)"
mv "$SWIFT_SRC" "$BINDINGS/swift/NativeCore.swift"
mv "$HEADER_SRC" "$BINDINGS/swift/NativeCoreFFI.h"
sed -i '' "s/$FFI_MODULE/NativeCoreFFI/g" "$BINDINGS/swift/NativeCore.swift"

MODULE_MAP='framework module NativeCoreFFI {
    umbrella header "NativeCoreFFI.h"
    export *
    module * { export * }
}'

STAGE="$ROOT/native-core/build-xcframework"
rm -rf "$STAGE"
CREATE_ARGS=()

platform_dir_for() { case "$1" in aarch64-apple-darwin) echo macos ;; aarch64-apple-ios) echo ios ;; *) echo ios-simulator ;; esac; }
min_os_for()       { case "$1" in aarch64-apple-darwin) echo 15.0 ;; *) echo 18.0 ;; esac; }
platform_name_for(){ case "$1" in aarch64-apple-darwin) echo MacOSX ;; aarch64-apple-ios) echo iPhoneOS ;; *) echo iPhoneSimulator ;; esac; }

for t in "${TARGETS[@]}"; do
  FW="$STAGE/$(platform_dir_for "$t")/NativeCoreFFI.framework"

  if [ "$t" = "aarch64-apple-darwin" ]; then
    # macOS frameworks need the versioned layout for module resolution.
    CONTENT="$FW/Versions/A"
    mkdir -p "$CONTENT/Headers" "$CONTENT/Modules" "$CONTENT/Resources"
    cp "target/$t/release/libnative_core.a" "$CONTENT/NativeCoreFFI"
    cp "$BINDINGS/swift/NativeCoreFFI.h" "$CONTENT/Headers/NativeCoreFFI.h"
    printf '%s\n' "$MODULE_MAP" > "$CONTENT/Modules/module.modulemap"
    ln -s A "$FW/Versions/Current"
    ln -s Versions/Current/Headers "$FW/Headers"
    ln -s Versions/Current/Modules "$FW/Modules"
    ln -s Versions/Current/Resources "$FW/Resources"
    ln -s Versions/Current/NativeCoreFFI "$FW/NativeCoreFFI"
    PLIST="$CONTENT/Resources/Info.plist"
  else
    # iOS frameworks are flat.
    mkdir -p "$FW/Headers" "$FW/Modules"
    cp "target/$t/release/libnative_core.a" "$FW/NativeCoreFFI"
    cp "$BINDINGS/swift/NativeCoreFFI.h" "$FW/Headers/NativeCoreFFI.h"
    printf '%s\n' "$MODULE_MAP" > "$FW/Modules/module.modulemap"
    PLIST="$FW/Info.plist"
  fi

  /usr/libexec/PlistBuddy \
    -c "Add :CFBundleDevelopmentRegion string en" \
    -c "Add :CFBundleExecutable string NativeCoreFFI" \
    -c "Add :CFBundleIdentifier string app.bitchord.BitChord.native-core-ffi" \
    -c "Add :CFBundleInfoDictionaryVersion string 6.0" \
    -c "Add :CFBundleName string NativeCoreFFI" \
    -c "Add :CFBundlePackageType string FMWK" \
    -c "Add :CFBundleShortVersionString string 0.1.0" \
    -c "Add :CFBundleVersion string 1" \
    -c "Add :CFBundleSupportedPlatforms array" \
    -c "Add :CFBundleSupportedPlatforms:0 string $(platform_name_for "$t")" \
    -c "Add :MinimumOSVersion string $(min_os_for "$t")" \
    "$PLIST"
  CREATE_ARGS+=(-framework "$FW")
done

mkdir -p "$ROOT/AppleApp/Frameworks"
rm -rf "$ROOT/AppleApp/Frameworks/NativeCoreFFI.xcframework"
xcodebuild -create-xcframework "${CREATE_ARGS[@]}" \
  -output "$ROOT/AppleApp/Frameworks/NativeCoreFFI.xcframework"

# Generated Swift bindings join the app target's sources (see project.yml).
mkdir -p "$ROOT/AppleApp/Generated"
cp "$BINDINGS/swift/NativeCore.swift" "$ROOT/AppleApp/Generated/NativeCore.swift"

echo "OK: AppleApp/Frameworks/NativeCoreFFI.xcframework + AppleApp/Generated/NativeCore.swift"
