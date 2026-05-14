#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
export PATH=/home/chudpc/.local/verilator-5.020/bin:$PATH

INPUT="data/smoke_16x16_2f_cabac_p16x16_luma_residual.yuv"
python3 - <<'PY'
from pathlib import Path
W = H = 16
# IDR flat, P frame with luma-only residual. This is the RED case for the next
# real CABAC milestone: integrated P_L0_16x16 nonzero residual coefficient bins.
y0 = bytes([64]) * (W * H)
u0 = bytes([128]) * ((W // 2) * (H // 2))
v0 = bytes([128]) * ((W // 2) * (H // 2))
y1 = bytes([72]) * (W * H)
u1 = bytes([128]) * ((W // 2) * (H // 2))
v1 = bytes([128]) * ((W // 2) * (H // 2))
out = Path('data/smoke_16x16_2f_cabac_p16x16_luma_residual.yuv')
out.parent.mkdir(parents=True, exist_ok=True)
out.write_bytes(y0 + u0 + v0 + y1 + u1 + v1)
print(f"[INFO] luma-residual RED fixture {out} size={out.stat().st_size}")
PY

BUILD_OUT="$(mktemp /tmp/h264_cabac_luma_red_build.XXXXXX)"
python3 - <<'PY' > "$BUILD_OUT"
from scripts.rtl_runner import BuildConfig, build_sim, stage_workspace
workspace = stage_workspace('h264_cabac_luma_red_')
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
LOG="/tmp/h264_cabac_luma_red.log"
set +e
"$SIM" \
  +frames=2 \
  +timeout=500000000 \
  +input="$ROOT/$INPUT" \
  +output="$ROOT/output/cabac_p16x16_luma_residual_red.h264" \
  +idr_interval=12 > "$LOG" 2>&1
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
  echo "[FAIL] luma residual CABAC RED case unexpectedly encoded successfully"
  exit 1
fi
if ! grep -q '\[CABAC_PSUBSET\] Unsupported non-skip MB' "$LOG"; then
  echo "[FAIL] luma residual RED failed for an unexpected reason"
  tail -80 "$LOG"
  exit 1
fi

echo "[PASS] RED: integrated CABAC P16x16 luma residual is still blocked by CABAC_PSUBSET guard"
echo "[INFO] Next GREEN step: replace this guard hit with real CABAC residual coefficient-bin emission and strict FFmpeg decode."
