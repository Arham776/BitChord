#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "Usage: $0 <release-tag> <uploaded-dmg> <release-notes.md>" >&2
  exit 2
fi

tag="$1"
dmg_path="$2"
notes_path="$3"
if [[ ! "$tag" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Release tag must look like 0.1.2 or v0.1.2." >&2
  exit 2
fi
if [[ ! -f "$dmg_path" || ! -f "$notes_path" ]]; then
  echo "Both the uploaded DMG and its release-notes Markdown file must exist." >&2
  exit 2
fi

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
derived_data="$HOME/Library/Developer/Xcode/DerivedData"
generate_appcast="$(find "$derived_data" -path '*/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast' -type f -print -quit 2>/dev/null || true)"
if [[ -z "$generate_appcast" ]]; then
  echo "Sparkle's generate_appcast was not found. Open/resolve AppleApp/BitChord.xcodeproj once in Xcode first." >&2
  exit 1
fi

archive_name="$(basename "$dmg_path")"
notes_name="${archive_name%.*}.md"
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
cp "$repo_root/appcast.xml" "$stage/appcast.xml"
cp "$dmg_path" "$stage/$archive_name"
cp "$notes_path" "$stage/$notes_name"

"$generate_appcast" \
  --account BitChord \
  --download-url-prefix "https://github.com/bagumamartin/BitChord/releases/download/$tag/" \
  --full-release-notes-url "https://github.com/bagumamartin/BitChord/releases/tag/$tag" \
  --embed-release-notes \
  "$stage"

cp "$stage/appcast.xml" "$repo_root/appcast.xml"
echo "Updated $repo_root/appcast.xml for $tag. Commit and push it after the matching DMG is attached to that GitHub release."
