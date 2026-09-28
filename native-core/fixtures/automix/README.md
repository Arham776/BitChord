# Automix evaluation fixtures

Generate synthetic pairs (not checked in — too large for git):

```bash
python3 native-core/scripts/generate_automix_fixtures.py
cargo run --release --example automix_render -- --score-dir native-core/fixtures/automix
```

Or drop your own matched pairs:

```text
01-out.flac
01-in.flac
02-out.wav
02-in.wav
```

Each line reports style, playback rate, Smoothness Index, and analysis sources.
A non-zero exit means at least one pair forced a stretch beyond ±4% (Apple failure mode).

Suggested coverage:

- compatible dance tempi (expect `DjBlend`, rate ≈ 1.0, high smooth)
- hard tempo gap (expect `DjFilter` or `EqualPower`, rate = 1.0)
- rock fade-out into silence-trimmed mix-out
