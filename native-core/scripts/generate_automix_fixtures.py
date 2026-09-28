#!/usr/bin/env python3
"""Generate synthetic Automix score fixtures (not checked in — see README)."""

from __future__ import annotations

import math
import struct
import wave
from pathlib import Path

RATE = 22_050  # enough for tempo/envelope; keeps fixtures small


def write_stereo(path: Path, samples: list[float]) -> None:
    with wave.open(str(path), "w") as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(RATE)
        frames = bytearray()
        for s in samples:
            v = max(-1.0, min(1.0, s))
            i = int(v * 32767)
            frames += struct.pack("<hh", i, i)
        w.writeframes(frames)


def synth(
    duration: float,
    bpm: float,
    freq: float,
    amp: float = 0.35,
    fade_out: float = 0.0,
    silence_tail: float = 0.0,
    click: bool = True,
) -> list[float]:
    n = int(duration * RATE)
    beat = 60.0 / bpm
    samples: list[float] = []
    for i in range(n):
        t = i / RATE
        tone = amp * math.sin(2 * math.pi * freq * t)
        tone += amp * 0.25 * math.sin(2 * math.pi * freq * 2 * t)
        tone += amp * 0.4 * math.sin(2 * math.pi * (freq / 4) * t)
        if click and (t % beat) < 0.012:
            tone += 0.55 * math.exp(-((t % beat) * 80))
        if t < 4.0:
            env = 0.35 + 0.65 * (t / 4.0)
        elif t > duration - 8.0:
            env = max(0.15, (duration - t) / 8.0)
        else:
            env = 1.0
        if fade_out > 0 and t > duration - fade_out:
            env *= max(0.0, (duration - t) / fade_out)
        samples.append(tone * env)
    if silence_tail > 0:
        samples.extend([0.0] * int(silence_tail * RATE))
    return samples


def main() -> None:
    out_dir = Path(__file__).resolve().parents[1] / "fixtures" / "automix"
    out_dir.mkdir(parents=True, exist_ok=True)
    write_stereo(out_dir / "01-out.wav", synth(45.0, 120.0, 220.0, fade_out=6.0, silence_tail=2.0))
    write_stereo(out_dir / "01-in.wav", synth(40.0, 122.0, 246.94, amp=0.32))
    write_stereo(out_dir / "02-out.wav", synth(42.0, 96.0, 196.0, fade_out=5.0))
    write_stereo(out_dir / "02-in.wav", synth(38.0, 148.0, 329.63, amp=0.3))
    write_stereo(out_dir / "03-out.wav", synth(50.0, 110.0, 164.81, amp=0.4, fade_out=10.0, silence_tail=4.0))
    write_stereo(out_dir / "03-in.wav", synth(36.0, 112.0, 174.61, amp=0.33))
    print(f"wrote fixtures under {out_dir}")


if __name__ == "__main__":
    main()
