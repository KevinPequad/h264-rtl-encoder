#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
export PATH=/home/chudpc/.local/verilator-5.020/bin:$PATH

python3 scripts/audit_cabac_chroma_residual_scaffold.py

python3 - <<'PY'
from pathlib import Path

W = H = 16
y0 = bytes([64]) * (W * H)
y1 = bytes([64]) * (W * H)
flat_chroma = bytes([128]) * ((W // 2) * (H // 2))
checker = bytes(136 if ((x + y) % 2) else 128 for y in range(H // 2) for x in range(W // 2))
patterns = {
    "checker": (flat_chroma, checker),
    "single_tl": (
        flat_chroma,
        bytes(136 if (x < 4 and y < 4 and ((x + y) % 2)) else 128 for y in range(H // 2) for x in range(W // 2)),
    ),
    "single_br": (
        flat_chroma,
        bytes(136 if (x >= 4 and y >= 4 and ((x + y) % 2)) else 128 for y in range(H // 2) for x in range(W // 2)),
    ),
    "both_planes": (checker, checker),
}
out_dir = Path("data")
out_dir.mkdir(parents=True, exist_ok=True)
for name, (cb, cr) in patterns.items():
    out = out_dir / f"smoke_16x16_2f_cabac_p16x16_chroma_residual_cr_ac_{name}.yuv"
    out.write_bytes(y0 + flat_chroma + flat_chroma + y1 + cb + cr)
    print(f"[INFO] CR_AC {name} fixture {out} size={out.stat().st_size}")
PY

BUILD_OUT="$(mktemp /tmp/h264_cabac_cr_ac_probe_build.XXXXXX)"
python3 - <<'PY' > "$BUILD_OUT"
from scripts.rtl_runner import BuildConfig, build_sim, stage_workspace
workspace = stage_workspace('h264_cabac_cr_ac_probe_')
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

run_expected_miss() {
  local name="$1"
  local expected_signature="$2"
  local expected_counters="${3:-cabac_chroma_cb_ac_mbs=0 cabac_chroma_cr_ac_mbs=1}"
  local input="data/smoke_16x16_2f_cabac_p16x16_chroma_residual_cr_ac_${name}.yuv"
  local h264="output/cabac_p16x16_chroma_residual_cr_ac_${name}.h264"
  local sim_log="output/validation_cabac_p16x16_chroma_residual_cr_ac_${name}.sim.log"
  local ffmpeg_log="output/validation_cabac_p16x16_chroma_residual_cr_ac_${name}.ffmpeg.log"

  "$SIM" \
    +frames=2 \
    +timeout=5000000 \
    +input="$ROOT/$input" \
    +output="$ROOT/$h264" \
    +idr_interval=12 > "$sim_log" 2>&1

  if ! grep -q 'cabac_p16x16_mbs=1' "$sim_log"; then
    echo "[FAIL] CR_AC ${name} did not exercise integrated CABAC P16x16"
    tail -80 "$sim_log"
    exit 1
  fi
  if ! grep -q "$expected_counters" "$sim_log"; then
    echo "[FAIL] CR_AC ${name} did not match expected CABAC chroma AC counters: ${expected_counters}"
    tail -80 "$sim_log"
    exit 1
  fi
  if ! grep -Eq 'cavlc_suppressed_bits=[1-9][0-9]*' "$sim_log"; then
    echo "[FAIL] CR_AC ${name} did not suppress the legacy CAVLC payload"
    tail -80 "$sim_log"
    exit 1
  fi

  if ffmpeg -v error -xerror -i "$h264" -f null - > "$ffmpeg_log" 2>&1; then
    echo "[FAIL] CR_AC ${name} strict-decoded; promote the gate instead of keeping this expected-miss probe"
    exit 1
  fi
  if ! grep -q "$expected_signature" "$ffmpeg_log"; then
    echo "[FAIL] CR_AC ${name} expected strict FFmpeg decode miss signature '$expected_signature'"
    tail -80 "$ffmpeg_log"
    exit 1
  fi
  echo "[PASS] CR_AC ${name} remains isolated at expected strict FFmpeg decode miss signature ${expected_signature}"
}

run_expected_miss checker 'bytestream -29'
run_expected_miss single_tl 'bytestream -5'
run_expected_miss single_br 'bytestream -35'
run_expected_miss both_planes 'bytestream -22' 'cabac_chroma_cb_ac_mbs=1 cabac_chroma_cr_ac_mbs=1'

echo "[PASS] CABAC P16x16 Cr AC strict-decode blocker is reproduced across checker/single-block Cr-only probes and a both-plane AC probe"
