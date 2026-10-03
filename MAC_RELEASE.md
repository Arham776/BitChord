# macOS release DMG

Use `scripts/package-mac-dmg.sh` to turn an Xcode-exported `BitChord.app` into
the standard Finder-ready DMG. It works on a staging copy, checks that the app's
marketing version matches the requested version, removes embedded provisioning
profiles and existing signatures, repairs the Mac framework runpath if needed,
and ad-hoc signs the staged app. It also scales the 1536×1024 artwork to the
768×512 Finder window and positions the app and Applications link consistently.

## Build the DMG

Export the macOS app from Xcode, then run:

```sh
scripts/package-mac-dmg.sh 0.1.1 \
  "/path/to/BitChord Xcode export"
```

The script writes `BitChord-0.1.1.dmg` into the export folder. For an existing
output file, pass `--overwrite`. To choose another destination, pass
`--output-dir "/path/to/output"`.

The script requires Xcode command line tools, `create-dmg`, and (only for
publishing) the GitHub CLI. For publishing, it reads the repository identity
and URL from the checkout rather than assuming a fixed owner or repo name. The
input export is left untouched. The final DMG is verified with `hdiutil` before
it replaces an existing output file.

## Publish a new GitHub release

Push the matching `vVERSION` Git tag first, then create the release with a notes
file:

```sh
scripts/package-mac-dmg.sh 0.1.2 \
  "/path/to/BitChord Xcode export" \
  --create-release \
  --notes "/path/to/0.1.2-release-notes.md"
```

`--create-release` requires that the Git tag already exists on GitHub, checks it
with `gh release create --verify-tag`, and asks before publishing the release.
It attaches the DMG and uses the supplied Markdown as the release notes. It does
not silently create a Git tag from whatever commit happens to be checked out.
If the local DMG already exists, also pass `--overwrite` to rebuild it.

## Add to an existing GitHub release

To add an asset without replacing an existing one:

```sh
scripts/package-mac-dmg.sh 0.1.1 \
  "/path/to/BitChord Xcode export" \
  --publish
```

If that release already has `BitChord-VERSION.dmg`, add `--replace-asset` to
explicitly replace it. For a rebuilt local DMG and an existing asset, use
`--overwrite --publish --replace-asset`. `--notes FILE` is optional for an
existing release; when supplied, it also replaces the release description. The
GitHub upload is separate from publishing the signed Sparkle `appcast.xml`;
generate and publish the appcast after confirming the final DMG is attached to
the release.

## Signing and Gatekeeper

This procedure removes Apple provisioning profiles and Developer ID signatures,
then applies an ad-hoc signature so the staged app's nested code is internally
consistent and can launch. It does not notarize the app or remove Gatekeeper's
first-open warning. Release notes should continue to include the approved
Gatekeeper instructions for users.
