`seek-tone.m4a` is a generated three-second stereo AAC-LC fixture (44.1 kHz,
64 kbps). Left: 440 Hz sine at 8000/32768; right: 660 Hz at 6000/32768.
It was encoded from signed 16-bit PCM using macOS `afconvert -f m4af -d aac
-b 64000`. It contains no sampled or copyrighted recording.

Used to check compressed preroll, silence-boundary seeks and region cuts.
