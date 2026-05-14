#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
export PATH=/home/chudpc/.local/verilator-5.020/bin:$PATH

INPUT="data/smoke_16x16_2f_cabac_p16x16_chroma_residual.yuv"
python3 - <<'PY'
from pathlib import Path
W = H = 16
# IDR flat, P frame with chroma-only residual. This is the RED case for the next
# CABAC milestone after luma residual GREEN: chroma DC/AC coefficient syntax.
y0 = bytes([64]) * (W * H)
u0 = bytes([128]) * ((W // 2) * (H // 2))
v0 = bytes([128]) * ((W // 2) * (H // 2))
y1 = bytes([64]) * (W * H)
u1 = bytes([136]) * ((W // 2) * (H // 2))
v1 = bytes([128]) * ((W // 2) * (H // 2))
out = Path('data/smoke_16x16_2f_cabac_p16x16_chroma_residual.yuv')
out.parent.mkdir(parents=True, exist_ok=True)
out.write_bytes(y0 + u0 + v0 + y1 + u1 + v1)
print(f"[INFO] chroma-residual RED fixture {out} size={out.stat().st_size}")
PY

BUILD_OUT="$(mktemp /tmp/h264_cabac_chroma_red_build.XXXXXX)"
python3 - <<'PY' > "$BUILD_OUT"
from scripts.rtl_runner import BuildConfig, build_sim, stage_workspace
workspace = stage_workspace('h264_cabac_chroma_red_')
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
LOG="output/validation_cabac_p16x16_chroma_residual_red.sim.log"
mkdir -p output
set +e
"$SIM" \
  +frames=2 \
  +timeout=5000000 \
  +input="$ROOT/$INPUT" \
  +output="$ROOT/output/cabac_p16x16_chroma_residual_red.h264" \
  +idr_interval=12 > "$LOG" 2>&1
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
  echo "[FAIL] chroma residual CABAC RED case unexpectedly encoded successfully"
  tail -80 "$LOG"
  exit 1
fi
if ! grep -q '\[CABAC_PSUBSET\] Unsupported non-skip MB' "$LOG"; then
  echo "[FAIL] chroma residual RED failed for an unexpected reason"
  tail -80 "$LOG"
  exit 1
fi

echo "[PASS] RED: integrated CABAC P16x16 chroma residual is still blocked by CABAC_PSUBSET guard"
echo "[INFO] Next GREEN step: add CABAC chroma residual DC/AC coefficient-bin emission and strict FFmpeg decode."
