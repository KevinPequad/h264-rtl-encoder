#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
export PATH=/home/chudpc/.local/verilator-5.020/bin:$PATH

INPUT="data/smoke_16x16_2f_cabac_p16x16_luma_residual.yuv"
OUT="output/cabac_p16x16_luma_residual_green.h264"
SIM_LOG="output/validation_cabac_p16x16_residual_green.sim.log"
FF_LOG="output/validation_cabac_p16x16_residual_green.ffmpeg.log"

python3 - <<'PY'
from pathlib import Path
W = H = 16
y0 = bytes([64]) * (W * H)
u0 = bytes([128]) * ((W // 2) * (H // 2))
v0 = bytes([128]) * ((W // 2) * (H // 2))
y1 = bytes([72]) * (W * H)
u1 = bytes([128]) * ((W // 2) * (H // 2))
v1 = bytes([128]) * ((W // 2) * (H // 2))
out = Path('data/smoke_16x16_2f_cabac_p16x16_luma_residual.yuv')
out.parent.mkdir(parents=True, exist_ok=True)
out.write_bytes(y0 + u0 + v0 + y1 + u1 + v1)
print(f"[INFO] luma-residual GREEN fixture {out} size={out.stat().st_size}")
PY

BUILD_OUT="$(mktemp /tmp/h264_cabac_luma_green_build.XXXXXX)"
python3 - <<'PY' > "$BUILD_OUT"
from scripts.rtl_runner import BuildConfig, build_sim, stage_workspace
workspace = stage_workspace('h264_cabac_luma_green_')
config = BuildConfig(
    width=16,
    height=16,
    bit_depth=8,
    chroma_format_idc=1,
    enable_idr_ipcm=1,
    ipcm_sad_threshold=0,
    enable_cabac_p16x16=1,
)
print(build_sim(workspace, config))
PY
SIM="$(tail -1 "$BUILD_OUT")"
mkdir -p output
"$SIM" \
  +frames=2 \
  +timeout=5000000 \
  +input="$ROOT/$INPUT" \
  +output="$ROOT/$OUT" \
  +idr_interval=12 > "$SIM_LOG" 2>&1

if grep -q '\[CABAC_PSUBSET\]' "$SIM_LOG"; then
  echo "[FAIL] residual GREEN hit CABAC subset guard"
  tail -80 "$SIM_LOG"
  exit 1
fi
if ! grep -q 'cabac_p16x16_mbs=1' "$SIM_LOG"; then
  echo "[FAIL] residual GREEN did not exercise integrated CABAC P16x16"
  tail -80 "$SIM_LOG"
  exit 1
fi
if ! grep -q 'cavlc_suppressed_bits=140' "$SIM_LOG"; then
  echo "[FAIL] residual GREEN did not suppress the legacy CAVLC residual payload"
  tail -80 "$SIM_LOG"
  exit 1
fi

set +e
ffmpeg -v error -err_detect explode -i "$OUT" -f null - > "$FF_LOG" 2>&1
ff_rc=$?
set -e
if [ "$ff_rc" -ne 0 ] || [ -s "$FF_LOG" ]; then
  echo "[FAIL] strict FFmpeg decode reported residual CABAC errors"
  cat "$FF_LOG"
  exit 1
fi

echo "[PASS] CABAC P16x16 luma residual GREEN strict-decoded"
echo "[INFO] output=$OUT"
