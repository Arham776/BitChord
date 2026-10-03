# macOS automatic updates

BitChord uses Sparkle 2.10 for macOS updates. It checks the `appcast.xml` feed
in this repository, downloads the DMG attached to a GitHub Release, and verifies
Sparkle's EdDSA signature before installing it. iPhone and iPad builds instead
show an update alert and link to the same repository's release notes; the user
updates through the channel they originally used to install BitChord.

## Preferences

The About section on macOS has a manual **Check for Updates** action, an automatic
check toggle, and an automatic download/install toggle. With automatic installation
enabled, Sparkle downloads a verified update and installs it when BitChord quits.
When it is disabled, Sparkle can still check automatically and present its normal
update prompt for the user to install. Sparkle exposes these two independent
preferences; there is no separate built-in “download automatically, then ask before
install” setting.

## Release workflow

1. Build and export a Mac app with a higher `CFBundleVersion`.
2. Package the export with `scripts/package-mac-dmg.sh`. For a new release, push
   its `vVERSION` Git tag first, then use `--create-release --notes FILE`. For an
   existing GitHub release, use `--publish`; replacing its existing DMG also
   requires `--replace-asset`. The script preserves the matching DMG filename
   used by the appcast.
3. Generate the signed appcast after the final DMG is attached to GitHub. Save
   the release notes as a local Markdown file and run:

   ```sh
   scripts/generate-mac-appcast.sh v0.1.2 \
     "/path/to/BitChord-0.1.2.dmg" \
     "/path/to/0.1.2-release-notes.md"
   ```

   The script uses Sparkle's `generate_appcast` with the `BitChord` signing key in
   the login Keychain, embeds the notes, and writes the signed enclosure entry to
   `appcast.xml`. Resolve the Xcode package once if that tool is not present yet.
4. Commit and push the updated `appcast.xml` to `main`. Confirm the raw feed is
   reachable at `https://raw.githubusercontent.com/bagumamartin/BitChord/main/appcast.xml`.

The private EdDSA key stays in the login Keychain under the `BitChord` account.
Only the corresponding `SUPublicEDKey` is in `AppleApp/project.yml`. Never commit
the private key or leave an export unencrypted. Keep a protected backup outside
the repository so it can be imported on a replacement Mac; without the key,
future appcast entries cannot be signed with the key already embedded in released
apps.

## Existing installs

Builds released before Sparkle was added cannot install their own Sparkle-enabled
update. Their users need to install the first Sparkle-enabled Mac release manually;
subsequent releases can update through Sparkle. iOS and iPadOS never install an
app update themselves and continue to point users to the release page.
