#!/usr/bin/env bash
# Fetch Automix ONNX graphs into AppleApp/Resources/Models/.
# Same I/O contracts as upstream beat_this_int8.onnx / vocals_umxhq_int8.onnx
# (Beat This! mel [1, T, 128] → two logit heads; open-unmix STFT [1, 2, 2049, T]).
# The upstream int8 assets are not published; these public MIT graphs are the
# same architectures (FP32 Beat This! small0, UMX-L vocals).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$ROOT/AppleApp/Resources/Models"
mkdir -p "$DEST"

BEAT_URL="https://huggingface.co/ashudesai/songbird-models/resolve/main/small0.onnx"
VOCAL_URL="https://huggingface.co/nsosu/demucs-onnx/resolve/main/umxl_vocals.onnx"

fetch() {
  local url="$1" out="$2"
  if [[ -s "$out" ]]; then
    echo "already present: $out"
    return
  fi
  echo "downloading $(basename "$out")…"
  curl -L --fail --retry 3 -o "$out" "$url"
}

fetch "$BEAT_URL" "$DEST/beat_this.onnx"
fetch "$VOCAL_URL" "$DEST/vocals_umxhq.onnx"
ls -lh "$DEST"/*.onnx
