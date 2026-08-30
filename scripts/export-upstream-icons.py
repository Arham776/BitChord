#!/usr/bin/env python3
"""Export upstream BitChordIcons.kt glyphs to asset-catalog image sets.

Pipeline per bitchord-apple-ui-spec.md §6: Compose ImageVector path data
converts losslessly to SVG (moveTo/lineTo/arcToRelative/curveTo → M/L/A/C),
imported as template images with Preserve Vector Data. Stroke: 2.2, round
caps/joins — the family's signature. Run from the repo root.
"""

import os
import json

STROKE = 2.2

# (asset name, fill path d, stroke path d) — None = that layer absent.
ICONS = [
    ("bch-play", "M 6.8 4.8 L 19.2 12 L 6.8 19.2 Z", None),
    ("bch-search",
     None,
     "M 4.6 11 a 6.4 6.4 0 1 1 12.8 0 a 6.4 6.4 0 1 1 -12.8 0 "
     "M 15.9 15.9 L 20.4 20.4"),
    ("bch-explore",
     None,
     "M 3.4 12 a 8.6 8.6 0 1 1 17.2 0 a 8.6 8.6 0 1 1 -17.2 0 "
     "M 15.4 8.6 L 13.6 13.6 L 8.6 15.4 L 10.4 10.4 Z"),
    ("bch-shuffle",
     None,
     "M 3.4 7.4 L 7 7.4 L 16.6 16.6 L 20.6 16.6 "
     "M 18.1 14.1 L 20.6 16.6 L 18.1 19.1 "
     "M 3.4 16.6 L 7 16.6 L 9.8 13.9 "
     "M 13.9 10.1 L 16.6 7.4 L 20.6 7.4 "
     "M 18.1 4.9 L 20.6 7.4 L 18.1 9.9"),
    ("bch-repeat",
     None,
     "M 8.6 7.6 L 15.4 7.6 a 4.4 4.4 0 0 1 0 8.8 L 8.6 16.4 "
     "a 4.4 4.4 0 0 1 0 -8.8 Z "
     "M 13.5 5.7 L 15.4 7.6 L 13.5 9.5 "
     "M 10.5 14.5 L 8.6 16.4 L 10.5 18.3"),
    ("bch-infinity",
     None,
     "M 12 12 C 10.1 9.1 8.7 8 7.1 8 a 4 4 0 0 0 0 8 "
     "C 8.7 16 10.1 14.9 12 12 C 13.9 9.1 15.3 8 16.9 8 "
     "a 4 4 0 0 1 0 8 C 15.3 16 13.9 14.9 12 12"),
    ("bch-music-note",
     "M 4.2 17.7 a 2.9 2.5 0 1 1 5.8 0 a 2.9 2.5 0 1 1 -5.8 0 Z "
     "M 14.2 15.9 a 2.9 2.5 0 1 1 5.8 0 a 2.9 2.5 0 1 1 -5.8 0 Z",
     "M 10 17.7 L 10 6.7 M 20 15.9 L 20 4.9 M 10 6.7 L 20 4.9"),
    ("bch-lyrics",
     None,
     "M 6.2 4.6 L 17.8 4.6 a 2.8 2.8 0 0 1 2.8 2.8 L 20.6 13.6 "
     "a 2.8 2.8 0 0 1 -2.8 2.8 L 10.6 16.4 L 6.8 19.6 L 6.8 16.4 "
     "L 6.2 16.4 a 2.8 2.8 0 0 1 -2.8 -2.8 L 3.4 7.4 "
     "a 2.8 2.8 0 0 1 2.8 -2.8 Z "
     "M 7.6 9 L 16.4 9 M 7.6 12.1 L 13.2 12.1"),
    ("bch-chevron-right", None, "M 9.5 6.2 L 15.3 12 L 9.5 17.8"),
    ("bch-heart",
     None,
     "M 12 20 C 12 20 3.2 14.6 3.2 8.9 a 4.5 4.5 0 0 1 8.8 -1.5 "
     "a 4.5 4.5 0 0 1 8.8 1.5 C 20.8 14.6 12 20 12 20 Z"),
    ("bch-heart-filled",
     "M 12 20 C 12 20 3.2 14.6 3.2 8.9 a 4.5 4.5 0 0 1 8.8 -1.5 "
     "a 4.5 4.5 0 0 1 8.8 1.5 C 20.8 14.6 12 20 12 20 Z", None),
    ("bch-plus", None, "M 12 5 L 12 19 M 5 12 L 19 12"),
    ("bch-check", None, "M 5 12.8 L 9.6 17.4 L 19 6.9"),
    ("bch-download",
     None,
     "M 12 4.5 L 12 15.5 M 7.5 11 L 12 15.5 L 16.5 11 M 4.5 18 L 19.5 18"),
    ("bch-clock",
     None,
     "M 3.4 12 a 8.6 8.6 0 1 1 17.2 0 a 8.6 8.6 0 1 1 -17.2 0 "
     "M 12 7.4 L 12 12 L 15.4 13.8"),
    ("bch-pin",
     None,
     "M 9.6 8.4 a 3.4 3.4 0 1 1 6.8 0 a 3.4 3.4 0 1 1 -6.8 0 "
     "M 10.8 10.8 L 5.6 19.6"),
    ("bch-library",
     None,
     "M 4.6 4.8 L 4.6 19.2 M 9.2 4.8 L 9.2 19.2 M 13.8 4.8 L 13.8 19.2 "
     "M 17.2 5.6 L 20.6 18.9"),
]

SVG_TEMPLATE = '''<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none">
{paths}
</svg>
'''


def svg_for(fill_d, stroke_d) -> str:
    paths = []
    if fill_d:
        paths.append(f'  <path d="{fill_d}" fill="black"/>')
    if stroke_d:
        paths.append(
            f'  <path d="{stroke_d}" fill="none" stroke="black" '
            f'stroke-width="{STROKE}" stroke-linecap="round" stroke-linejoin="round"/>'
        )
    return SVG_TEMPLATE.format(paths="\n".join(paths))


def main() -> None:
    root = os.path.join(os.path.dirname(__file__), "..", "AppleApp", "Assets.xcassets")
    # Regenerate from scratch so removed glyphs don't linger.
    for entry in os.listdir(root):
        if entry.startswith("bch-") and entry.endswith(".imageset"):
            os.rmdir(os.path.join(root, entry)) if False else None
    import shutil
    for entry in os.listdir(root):
        if entry.startswith("bch-") and entry.endswith(".imageset"):
            shutil.rmtree(os.path.join(root, entry))

    for name, fill_d, stroke_d in ICONS:
        imageset = os.path.join(root, f"{name}.imageset")
        os.makedirs(imageset, exist_ok=True)
        with open(os.path.join(imageset, f"{name}.svg"), "w") as f:
            f.write(svg_for(fill_d, stroke_d))
        contents = {
            "images": [{"filename": f"{name}.svg", "idiom": "universal"}],
            "info": {"author": "xcode", "version": 1},
            "properties": {
                "preserves-vector-representation": True,
                "template-rendering-intent": "template",
            },
        }
        with open(os.path.join(imageset, "Contents.json"), "w") as f:
            json.dump(contents, f, indent=2)
    with open(os.path.join(root, "Contents.json"), "w") as f:
        json.dump({"info": {"author": "xcode", "version": 1}}, f, indent=2)
    print(f"OK: {len(ICONS)} icon image sets in AppleApp/Assets.xcassets")


if __name__ == "__main__":
    main()
