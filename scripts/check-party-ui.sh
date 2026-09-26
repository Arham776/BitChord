#!/usr/bin/env bash
#
# Render the Listen Together UI in every state it distinguishes.
#
# # Why this exists
#
# The Xcode build proves the screen compiles. It does not prove the screen is right:
# a view can build and collapse, a state can go unhandled, and a string can say
# nothing at all. Those are the failures a screen nobody has looked at has, and they
# are the ones a compiler will never report.
#
# So this compiles the shipped view files together with a checker that hosts each one
# in a real view hierarchy at a real size, reads the strings back out, and asserts on
# them. It needs no server, no window server session and no human.
#
# The views are compiled from the app's own sources, so this cannot drift from what
# ships: if a file moves or a string changes, this fails until the checker is updated
# to match — which is the point.

set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
APP="$ROOT/AppleApp"
FW="$APP/Frameworks/BitChordShared.xcframework/macos-arm64"
HERE="$(cd "$(dirname "$0")" && pwd)"
CHECK_DIR="${TMPDIR:-/tmp}/bitchord-party-ui-check"

if [ ! -d "$FW" ]; then
  echo "BitChordShared.xcframework is missing — run ./scripts/build-shared-framework.sh first." >&2
  exit 1
fi

# The files the screen is made of, plus their direct dependencies. Deliberately not
# the whole app: the player and the library views need generated asset symbols, which
# only exist after the asset compiler has run, and they are covered by the real build.
SOURCES=(
  "$APP/Sources/UI/PartyStore.swift"
  "$APP/Sources/UI/ListenTogetherView.swift"
  "$APP/Sources/UI/ListenTogetherSheets.swift"
  "$APP/Sources/PlaybackSession/PartySync.swift"
  "$APP/Sources/PlaybackSession/PartySocket.swift"
  "$APP/Sources/UI/Toast.swift"
  "$APP/Sources/App/AuthController.swift"
  "$APP/Sources/App/AuthStore.swift"
  "$APP/Sources/App/Keychain.swift"
  "$APP/Sources/PlaybackSession/LyricsTranslator.swift"
  "$ROOT/scripts/CheckPartyUI.swift"
)

rm -rf "$CHECK_DIR"
mkdir -p "$CHECK_DIR"

# Stubs for the two types the party UI names but does not own. They exist so this
# check is a handful of files rather than the whole app, and they are stubs in name
# only: everything the party screen actually reads is the real thing.
cat > "$CHECK_DIR/Stubs.swift" <<'STUBS'
import Foundation
import SwiftUI
import Observation

/// The queue entry, as the party screen needs it: an id, some labels, and a
/// duration. The real one lives with the player and carries far more than a party
/// ever sends.
struct QueueEntry: Identifiable, Hashable {
    let id: String
    var title: String
    var artist: String
    var source: String
    var thumbnailUrl: String?
    var durationText: String?
    var albumName: String?
    var artworkData: Data?
    var isLocal: Bool
    var fromAutoplay: Bool = false

    var videoId: String? { source.hasPrefix("yt:") ? String(source.dropFirst(3)) : (isLocal ? nil : id) }
    var durationSeconds: Double { 0 }
}

/// The artwork a queue row draws.
///
/// A grey box of the right size, because what this check is about is the *row*: the
/// real `ArtworkView` is in `Common.swift` alongside the asset-catalog symbols the
/// Xcode build generates, and pulling that file in would make this check depend on a
/// build step it has no business depending on.
struct ArtworkView: View {
    var url: String?
    var data: Data?
    var side: CGFloat?

    var body: some View {
        Rectangle()
            .fill(.quaternary)
            .frame(width: side, height: side)
            .accessibilityHidden(true)
    }
}

/// The app's navigation flags, as far as the party screen reaches them.
///
/// The real `AppModel` lives in `BitChordApp.swift` next to the whole app, and the
/// party screen uses exactly one of its fields. Declaring the one field it needs is
/// better than compiling the entire app to check a screen: the screen cannot read a
/// flag that is not here, so a rename on either side is still a compile error.
@Observable
final class AppModel {
    var scenePhase: ScenePhase = .active
    /// Set by a `bitchord://party/…` link arriving from outside the app.
    var pendingPartyInvite: String?
}

/// The player, as far as the party binding reaches it. Every member here is called
/// by `PartySync`, and none of them does anything: the binding's decisions are
/// portable Kotlin with tests, and this check is about the screens.
@MainActor
final class PlaybackController {
    var isPlaying = false
    var position: Double = 0
    var onLocalIntent: (() -> Void)?
    private var intentSuppression = 0

    func withLocalIntentSuppressed<T>(_ body: () -> T) -> T {
        intentSuppression += 1
        defer { intentSuppression -= 1 }
        return body()
    }

    func seek(to seconds: Double) { position = seconds }
    func togglePlayPause() { isPlaying.toggle() }
    func play(_ entries: [QueueEntry], at index: Int = 0) {}
    func pauseForBackground() {}
}
STUBS

xcrun swiftc \
  -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
  -target arm64-apple-macos15.0 \
  -swift-version 5 \
  -F "$FW" \
  -framework BitChordShared \
  -Xlinker -rpath -Xlinker "$FW/BitChordShared.framework/Versions/A" \
  -o "$CHECK_DIR/check" \
  "${SOURCES[@]}" "$CHECK_DIR/Stubs.swift"

"$CHECK_DIR/check"
