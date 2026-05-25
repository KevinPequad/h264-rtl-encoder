#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
export PATH=/home/chudpc/.local/verilator-5.020/bin:$PATH

python3 scripts/audit_cabac_chroma_residual_scaffold.py

INPUT_DC="data/smoke_16x16_2f_cabac_p16x16_chroma_residual_dc.yuv"
INPUT_AC="data/smoke_16x16_2f_cabac_p16x16_chroma_residual_ac.yuv"
python3 - <<'PY'
from pathlib import Path
W = H = 16
# IDR flat, P frames with chroma-only residual. These are the RED cases for the
# next CABAC milestone after luma residual GREEN: chroma DC-only and DC+AC
# coefficient syntax.
y0 = bytes([64]) * (W * H)
u0 = bytes([128]) * ((W // 2) * (H // 2))
v0 = bytes([128]) * ((W // 2) * (H // 2))
y1 = bytes([64]) * (W * H)
u1_dc = bytes([136]) * ((W // 2) * (H // 2))
u1_ac = bytes(136 if ((x ^ y) & 1) else 128 for y in range(H // 2) for x in range(W // 2))
v1 = bytes([128]) * ((W // 2) * (H // 2))
fixtures = {
    'dc': (Path('data/smoke_16x16_2f_cabac_p16x16_chroma_residual_dc.yuv'), u1_dc),
    'ac': (Path('data/smoke_16x16_2f_cabac_p16x16_chroma_residual_ac.yuv'), u1_ac),
}
for name, (out, u1) in fixtures.items():
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_bytes(y0 + u0 + v0 + y1 + u1 + v1)
    print(f"[INFO] chroma-residual {name.upper()} RED fixture {out} size={out.stat().st_size}")
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
mkdir -p output

run_red_case() {
  local name="$1"
  local input="$2"
  local want_cbp_chroma="$3"
  local log="output/validation_cabac_p16x16_chroma_residual_${name}_red.sim.log"
  set +e
  "$SIM" \
    +frames=2 \
    +timeout=5000000 \
    +input="$ROOT/$input" \
    +output="$ROOT/output/cabac_p16x16_chroma_residual_${name}_red.h264" \
    +idr_interval=12 > "$log" 2>&1
  rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
    echo "[FAIL] chroma residual CABAC ${name} RED case unexpectedly encoded successfully"
    tail -80 "$log"
    exit 1
  fi
  if ! grep -q '\[CABAC_PSUBSET\] Unsupported non-skip MB' "$log"; then
    echo "[FAIL] chroma residual ${name} RED failed for an unexpected reason"
    tail -80 "$log"
    exit 1
  fi
  if ! grep -q "cbp_luma=0 cbp_chroma=${want_cbp_chroma}" "$log"; then
    echo "[FAIL] chroma residual ${name} RED did not prove expected chroma CBP=${want_cbp_chroma} guard"
    tail -80 "$log"
    exit 1
  fi
}

run_red_case "dc" "$INPUT_DC" 1
run_red_case "ac" "$INPUT_AC" 2

echo "[PASS] RED: integrated CABAC P16x16 chroma DC-only and DC+AC residuals are still blocked by CABAC_PSUBSET guard"
echo "[INFO] Next GREEN step: add CABAC chroma residual DC/AC coefficient-bin emission and strict FFmpeg decode."
