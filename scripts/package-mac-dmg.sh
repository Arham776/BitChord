#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Package BitChord's exported macOS app as a consistently laid out DMG.

Usage:
  scripts/package-mac-dmg.sh <version> <export-folder> [options]

Arguments:
  version        Marketing version, for example 0.1.1
  export-folder  Folder containing BitChord.app from the Xcode export

Options:
  --output-dir DIR  Write BitChord-VERSION.dmg to DIR (default: export-folder)
  --overwrite       Replace an existing local DMG with the same name
  --publish         Upload an asset to an existing GitHub release
  --replace-asset   Replace the same-named asset (requires --publish)
  --create-release  Create a new GitHub release from an existing vVERSION tag
  --notes FILE      Release notes (required for --create-release)
  -h, --help        Show this help

The app is copied before processing. The exported app is left untouched.
GitHub changes ask for confirmation. New releases require a pushed Git tag.
EOF
}

fail() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

if [[ $# -eq 1 && ( "$1" == "-h" || "$1" == "--help" ) ]]; then
  usage
  exit 0
fi
[[ $# -ge 2 ]] || { usage >&2; exit 2; }
version="$1"
export_dir="$2"
shift 2
repo_root="$(cd "$(dirname "$0")/.." && pwd)"

output_dir=""
overwrite=0
publish=0
create_release=0
replace_asset=0
notes_file=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-dir)
      [[ $# -ge 2 ]] || fail "--output-dir needs a path"
      output_dir="$2"
      shift 2
      ;;
    --overwrite)
      overwrite=1
      shift
      ;;
    --publish)
      publish=1
      shift
      ;;
    --replace-asset)
      replace_asset=1
      shift
      ;;
    --create-release)
      create_release=1
      shift
      ;;
    --notes)
      [[ $# -ge 2 ]] || fail "--notes needs a Markdown file"
      notes_file="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "Unknown option: $1"
      ;;
  esac
done

[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "version must look like 0.1.1"
[[ "$publish" -eq 0 || "$create_release" -eq 0 ]] || fail "choose either --publish or --create-release"
[[ "$replace_asset" -eq 0 || "$publish" -eq 1 ]] || fail "--replace-asset requires --publish"
[[ -d "$export_dir" ]] || fail "export folder does not exist: $export_dir"
app_source="$export_dir/BitChord.app"
[[ -d "$app_source" ]] || fail "expected BitChord.app inside: $export_dir"

if [[ -z "$output_dir" ]]; then
  output_dir="$export_dir"
fi
mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd)"
dmg_path="$output_dir/BitChord-$version.dmg"

if [[ -e "$dmg_path" && "$overwrite" -ne 1 ]]; then
  fail "DMG already exists: $dmg_path (pass --overwrite to replace it)"
fi
if [[ -n "$notes_file" && ! -f "$notes_file" ]]; then
  fail "release notes file does not exist: $notes_file"
fi
if [[ -n "$notes_file" && "$publish" -ne 1 && "$create_release" -ne 1 ]]; then
  fail "--notes requires --publish or --create-release"
fi
if [[ "$create_release" -eq 1 && -z "$notes_file" ]]; then
  fail "--create-release requires --notes FILE"
fi

for tool in ditto codesign otool install_name_tool sips hdiutil create-dmg; do
  command -v "$tool" >/dev/null 2>&1 || fail "required tool not found: $tool"
done
[[ -x /usr/libexec/PlistBuddy ]] || fail "required tool not found: /usr/libexec/PlistBuddy"
if [[ "$publish" -eq 1 || "$create_release" -eq 1 ]]; then
  command -v gh >/dev/null 2>&1 || fail "GitHub CLI (gh) is required for --publish"
  gh auth status >/dev/null 2>&1 || fail "sign in to GitHub CLI first (gh auth login)"
  github_repo="$(cd "$repo_root" && gh repo view --json nameWithOwner --jq '.nameWithOwner')" \
    || fail "could not determine the GitHub repository from this checkout"
  github_repo_url="$(cd "$repo_root" && gh repo view --json url --jq '.url')" \
    || fail "could not determine the GitHub repository URL from this checkout"
  tag="v$version"
  if [[ "$publish" -eq 1 ]]; then
    release_assets="$(gh release view "$tag" --repo "$github_repo" --json assets --jq '.assets[].name')" \
      || fail "GitHub release $tag does not exist; use --create-release for a new release"
    if printf '%s\n' "$release_assets" | grep -Fxq "BitChord-$version.dmg" && [[ "$replace_asset" -ne 1 ]]; then
      fail "the release already has BitChord-$version.dmg; pass --replace-asset to replace it"
    fi
  elif gh release view "$tag" --repo "$github_repo" >/dev/null 2>&1; then
    fail "GitHub release $tag already exists; use --publish to add or update its asset"
  fi
fi

plist="$app_source/Contents/Info.plist"
[[ -f "$plist" ]] || fail "app Info.plist not found"
short_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")"
build_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")"
[[ "$short_version" == "$version" ]] || fail "export is version $short_version, not requested version $version"
executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$plist")"
app_executable="$app_source/Contents/MacOS/$executable"
[[ -f "$app_executable" ]] || fail "app executable not found: $app_executable"

background_source="$repo_root/artwork/cover-exports/DMG-background.png"
[[ -f "$background_source" ]] || fail "DMG background not found: $background_source"

stage="$(mktemp -d "${TMPDIR:-/tmp}/bitchord-dmg.XXXXXX")"
cleanup() {
  if [[ -n "${mounted_device:-}" ]]; then
    hdiutil detach "$mounted_device" -quiet >/dev/null 2>&1 || true
  fi
  rm -rf "$stage"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir -p "$stage/payload"
ditto "$app_source" "$stage/payload/BitChord.app"
app="$stage/payload/BitChord.app"
candidate="$stage/BitChord-$version.dmg"

printf 'Preparing BitChord %s (build %s)…\n' "$version" "$build_version"

# Remove embedded provisioning profiles and every nested Apple signature from
# the staged copy, then apply a fresh ad-hoc signature inside-out.
find "$app" -name embedded.provisionprofile -type f -delete
while IFS= read -r -d '' code_bundle; do
  codesign --remove-signature "$code_bundle" >/dev/null 2>&1 || true
done < <(find "$app" -depth \( -name '*.appex' -o -name '*.framework' -o -name '*.xpc' -o -name '*.app' \) -print0)
codesign --remove-signature "$app" >/dev/null 2>&1 || true

# Some exported builds omit the Mac app's parent Frameworks runpath. Repair it
# on the staged executable before signing so Sparkle and embedded frameworks load.
if ! otool -l "$app/Contents/MacOS/$executable" | grep -Fq '@executable_path/../Frameworks'; then
  install_name_tool -add_rpath '@executable_path/../Frameworks' "$app/Contents/MacOS/$executable"
fi

codesign --force --deep --sign - --timestamp=none "$app"
codesign --verify --deep --strict "$app"

# Finder displays this window in points. The artwork is 2x (1536x1024 pixels),
# so use a 768x512 pixel copy for a 768x512 point window on Retina displays.
sips -z 512 768 "$background_source" --out "$stage/dmg-background.png" >/dev/null

create-dmg \
  --overwrite \
  --volname "BitChord $version" \
  --background "$stage/dmg-background.png" \
  --window-pos 200 120 \
  --window-size 768 512 \
  --text-size 12 \
  --icon-size 110 \
  --icon "BitChord.app" 192 310 \
  --hide-extension "BitChord.app" \
  --app-drop-link 576 310 \
  --hdiutil-quiet \
  "$candidate" "$stage/payload"

hdiutil verify "$candidate" >/dev/null
mv -f "$candidate" "$dmg_path"
printf 'Created and verified: %s\n' "$dmg_path"

if [[ "$publish" -eq 1 ]]; then
  tag="v$version"
  if [[ "$replace_asset" -eq 1 ]]; then
    printf 'This will replace the %s DMG asset on GitHub release %s.\n' "BitChord-$version.dmg" "$tag"
  else
    printf 'This will add the %s DMG asset to GitHub release %s.\n' "BitChord-$version.dmg" "$tag"
  fi
  read -r -p 'Continue? [y/N] ' answer
  [[ "$answer" == "y" || "$answer" == "Y" ]] || fail "publishing cancelled"
  if [[ "$replace_asset" -eq 1 ]]; then
    gh release upload "$tag" "$dmg_path" --repo "$github_repo" --clobber
  else
    gh release upload "$tag" "$dmg_path" --repo "$github_repo"
  fi
  if [[ -n "$notes_file" ]]; then
    gh release edit "$tag" --repo "$github_repo" --notes-file "$notes_file"
  fi
  printf 'Updated GitHub release: %s/releases/tag/%s\n' "$github_repo_url" "$tag"
elif [[ "$create_release" -eq 1 ]]; then
  tag="v$version"
  printf 'This will create and publish GitHub release %s with the DMG and supplied notes.\n' "$tag"
  read -r -p 'Continue? [y/N] ' answer
  [[ "$answer" == "y" || "$answer" == "Y" ]] || fail "publishing cancelled"
  gh release create "$tag" "$dmg_path" \
    --repo "$github_repo" \
    --verify-tag \
    --title "BitChord $version" \
    --notes-file "$notes_file"
  printf 'Created GitHub release: %s/releases/tag/%s\n' "$github_repo_url" "$tag"
fi
