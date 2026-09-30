# Local NowPlaying with mixing reproduction

This standalone iOS 27 app plays a real, quiet, looping PCM tone with
`AVAudioPlayer`. It has no BitChord engine or shared library and publishes only
through `NowPlaying.MediaSession`. Audio configuration and activation are awaited
off the main thread before registering the session. The category is `.playback`,
the mode is `.default`, and the sole category option is `.mixWithOthers`.

Generate the project with:

```sh
xcodegen generate --spec AppleApp/tests/NowPlayingMixingRepro/project.yml
```

Open the generated project in Xcode, choose the signing team for your account,
and run `NowPlayingMixingRepro` on a physical device. Press **Play mixed tone**,
open Control Center, and try Pause/Play and seeking. Repeat after locking and
unlocking, and with a different audio app playing before and after the tone.
The optional launch argument `--play-mixed-tone` starts the test automatically.
Add `--generic-content` to use `GenericContent` instead of `MusicContent`, keeping
the player, duration and audio options identical. The probe checks prominence
on foreground entry and once 300 ms after publication, without periodic retries.

Record the OS version/build, effective audio category/options, the three session
flags, exact request errors, and visible controls. Logs use `[NowPlayingProbe]`.
Application-primary success and system-primary status are separate observations;
neither replaces checking the native card and whether its controls work.

On 2026-09-30, an iPhone 15 Pro Max running iOS 27.0.1 (24A446) reproduced
`MediaSessionError.internalFailure` from system promotion with both no competing
audio and other audio active. In both cases activation and application-primary
publication succeeded. See `device-results.log`, `device-probe-result.png`, and
the parent `NowPlayingDeviceFindings.md` for the captured evidence and limits.
The `GenericContent` comparison also failed with other audio active, both on
active foreground entry and after the 300 ms delay. The two no-competing-audio
and competing-audio cold tests above used `MusicContent`.

Apple documentation:

- [Publishing media sessions](https://developer.apple.com/documentation/nowplaying/publishing-media-sessions)
- [System-primary requests](https://developer.apple.com/documentation/nowplaying/mediasession/requesttobecomesystemprimary())
- [Framework integration guidance](https://developer.apple.com/documentation/nowplaying)

The shared long-form audio route policy is not an alternative for this test:
the Xcode 27 `AVAudioSession.h` contract permits no category options with that
policy. Removing `.mixWithOthers` would change the behavior being reproduced.
