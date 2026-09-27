#!/usr/bin/env bash
# Fetch Automix ONNX graphs into AppleApp/Resources/Models/.
# Same I/O contracts as upstream beat_this_int8.onnx / vocals_umxhq_int8.onnx
# (Beat This! mel [1, T, 128] → two logit heads; open-unmix STFT [1, 2, 2049, T]).
# The upstream int8 assets are not published; these public MIT graphs are the
# same architectures (FP32 Beat This! small0, UMX-L vocals).
#
# Pinned to a revision and checked against a SHA-256, the same two facts the app
# itself downloads by (see AutomixModelStore.swift). A branch can move and a tag
# can be re-pointed; a commit and a digest cannot, and a dev box and a listener's
# device must end up with the same bytes or parity claims mean nothing.
#
# This is the developer/CI path. The app fetches the same graphs at runtime on
# first run, so a build with no models here still ships and still works.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$ROOT/AppleApp/Resources/Models"
mkdir -p "$DEST"

# Pinned Hugging Face revisions. Both repositories declare MIT.
BEAT_URL="https://huggingface.co/ashudesai/songbird-models/resolve/345312bf5604913b3c0d05815f93c81c4b114e4d/small0.onnx"
VOCAL_URL="https://huggingface.co/nsosu/demucs-onnx/resolve/571310473535558f41c1bcd8ed4955515b983490/umxl_vocals.onnx"

BEAT_SHA="c462b064a4033050ca6a5354bf866ff4610ab1fd8f1dec1e494b20b22d870aea"
VOCAL_SHA="da6c48a21f1231eef0ea61dc00e8e4c6e5c29d37f86685323d68de1e6836c4cb"

fetch() {
  local url="$1" out="$2" want="$3"
  if [[ -s "$out" ]] && [[ "$(shasum -a 256 "$out" | awk '{print $1}')" == "$want" ]]; then
    echo "already present and verified: $out"
    return
  fi
  echo "downloading $(basename "$out")…"
  curl -L --fail --retry 3 -o "$out.tmp" "$url"
  local got
  got="$(shasum -a 256 "$out.tmp" | awk '{print $1}')"
  if [[ "$got" != "$want" ]]; then
    rm -f "$out.tmp"
    echo "checksum mismatch for $(basename "$out")" >&2
    echo "  expected $want" >&2
    echo "  got      $got" >&2
    exit 1
  fi
  mv "$out.tmp" "$out"
  echo "verified $(basename "$out")"
}

fetch "$BEAT_URL" "$DEST/beat_this.onnx" "$BEAT_SHA"
fetch "$VOCAL_URL" "$DEST/vocals_umxhq.onnx" "$VOCAL_SHA"
ls -lh "$DEST"/*.onnx
