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
# IDR flat, P frames with chroma-only residual.  These fixtures cover the first
# strict integrated CABAC P16x16 chroma residual milestone: DC-only
# coded_block_pattern_chroma=1 and DC+AC coded_block_pattern_chroma=2.
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
    print(f"[INFO] chroma-residual {name.upper()} fixture {out} size={out.stat().st_size}")
PY

BUILD_OUT="$(mktemp /tmp/h264_cabac_chroma_build.XXXXXX)"
python3 - <<'PY' > "$BUILD_OUT"
from scripts.rtl_runner import BuildConfig, build_sim, stage_workspace
workspace = stage_workspace('h264_cabac_chroma_')
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

run_case() {
  local name="$1"
  local input="$2"
  local want_cbp_chroma="$3"
  local h264="output/cabac_p16x16_chroma_residual_${name}.h264"
  local sim_log="output/validation_cabac_p16x16_chroma_residual_${name}.sim.log"
  local ffmpeg_log="output/validation_cabac_p16x16_chroma_residual_${name}.ffmpeg.log"

  "$SIM" \
    +frames=2 \
    +timeout=5000000 \
    +input="$ROOT/$input" \
    +output="$ROOT/$h264" \
    +idr_interval=12 > "$sim_log" 2>&1

  if ! grep -q 'cabac_p16x16_mbs=1' "$sim_log"; then
    echo "[FAIL] chroma residual ${name} did not exercise integrated CABAC P16x16"
    tail -80 "$sim_log"
    exit 1
  fi
  if ! grep -q 'cabac_chroma_mbs=1' "$sim_log"; then
    echo "[FAIL] chroma residual ${name} did not mark the CABAC chroma residual lane"
    tail -80 "$sim_log"
    exit 1
  fi
  if [ "$want_cbp_chroma" = "1" ]; then
    if ! grep -q 'cabac_chroma_dc_mbs=1 cabac_chroma_ac_mbs=0' "$sim_log"; then
      echo "[FAIL] chroma residual ${name} did not preserve DC-only coded_block_pattern_chroma=1"
      tail -80 "$sim_log"
      exit 1
    fi
  else
    if ! grep -q 'cabac_chroma_dc_mbs=0 cabac_chroma_ac_mbs=1' "$sim_log"; then
      echo "[FAIL] chroma residual ${name} did not preserve DC+AC coded_block_pattern_chroma=2"
      tail -80 "$sim_log"
      exit 1
    fi
  fi
  if ! grep -Eq 'cavlc_suppressed_bits=[1-9][0-9]*' "$sim_log"; then
    echo "[FAIL] chroma residual ${name} did not suppress the legacy CAVLC payload"
    tail -80 "$sim_log"
    exit 1
  fi

  ffmpeg -v error -xerror -i "$h264" -f null - > "$ffmpeg_log" 2>&1 || {
    echo "[FAIL] chroma residual ${name} failed strict FFmpeg decode"
    tail -80 "$ffmpeg_log"
    exit 1
  }

  local raw_yuv
  local expected_bytes
  local actual_bytes
  raw_yuv="$(mktemp "/tmp/h264_cabac_chroma_${name}_decode.XXXXXX.yuv")"
  expected_bytes=$((16 * 16 * 3 / 2 * 2))
  ffmpeg -y -v error -xerror -i "$h264" -f rawvideo -pix_fmt yuv420p "$raw_yuv" > /dev/null 2>&1 || {
    echo "[FAIL] chroma residual ${name} failed raw FFmpeg frame extraction"
    rm -f "$raw_yuv"
    exit 1
  }
  actual_bytes="$(wc -c < "$raw_yuv")"
  rm -f "$raw_yuv"
  if [ "$actual_bytes" -ne "$expected_bytes" ]; then
    echo "[FAIL] chroma residual ${name} decoded ${actual_bytes} bytes, expected ${expected_bytes} bytes for exactly two 16x16 yuv420p frames"
    exit 1
  fi

  if [ "$want_cbp_chroma" = "1" ]; then
    echo "[PASS] CABAC P16x16 chroma DC-only residual strict-decoded with two decoded frames"
  else
    echo "[PASS] CABAC P16x16 chroma DC+AC residual strict-decoded with two decoded frames"
  fi
}

run_case "dc" "$INPUT_DC" 1
run_case "ac" "$INPUT_AC" 2

echo "[PASS] CABAC P16x16 chroma residual DC-only and DC+AC smoke streams strict-decoded"
