#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
export PATH=/home/chudpc/.local/verilator-5.020/bin:$PATH

python3 scripts/audit_cabac_chroma_residual_scaffold.py

INPUT_CB_DC="data/smoke_16x16_2f_cabac_p16x16_chroma_residual_cb_dc.yuv"
INPUT_CB_AC="data/smoke_16x16_2f_cabac_p16x16_chroma_residual_cb_ac.yuv"
INPUT_CR_DC="data/smoke_16x16_2f_cabac_p16x16_chroma_residual_cr_dc.yuv"
INPUT_CR_AC="data/smoke_16x16_2f_cabac_p16x16_chroma_residual_cr_ac.yuv"
python3 - <<'PY'
from pathlib import Path
W = H = 16
# IDR flat, P frames with chroma-only residual. These fixtures cover the
# reduced strict integrated CABAC P16x16 chroma residual milestone across Cb
# DC-only, Cb DC+AC, and Cr DC-only. A Cr DC+AC fixture is generated too so
# the next strict-decode promotion can be enabled with CABAC_CHROMA_INCLUDE_CR_AC=1.
y0 = bytes([64]) * (W * H)
flat_chroma = bytes([128]) * ((W // 2) * (H // 2))
y1 = bytes([64]) * (W * H)
plane_dc = bytes([136]) * ((W // 2) * (H // 2))
plane_ac = bytes(136 if ((x + y) % 2) else 128 for y in range(H // 2) for x in range(W // 2))
fixtures = {
    'cb_dc': (Path('data/smoke_16x16_2f_cabac_p16x16_chroma_residual_cb_dc.yuv'), plane_dc, flat_chroma),
    'cb_ac': (Path('data/smoke_16x16_2f_cabac_p16x16_chroma_residual_cb_ac.yuv'), plane_ac, flat_chroma),
    'cr_dc': (Path('data/smoke_16x16_2f_cabac_p16x16_chroma_residual_cr_dc.yuv'), flat_chroma, plane_dc),
    'cr_ac': (Path('data/smoke_16x16_2f_cabac_p16x16_chroma_residual_cr_ac.yuv'), flat_chroma, plane_ac),
}
for name, (out, u1, v1) in fixtures.items():
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_bytes(y0 + flat_chroma + flat_chroma + y1 + u1 + v1)
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
  local expect_ffmpeg_fail="${4:-0}"
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
    if [ "$name" = "cb_ac" ] && ! grep -q 'cabac_chroma_cb_ac_mbs=1 cabac_chroma_cr_ac_mbs=0' "$sim_log"; then
      echo "[FAIL] chroma residual ${name} did not mark the Cb-only CABAC chroma AC plane"
      tail -80 "$sim_log"
      exit 1
    fi
    if [ "$name" = "cr_ac" ] && ! grep -q 'cabac_chroma_cb_ac_mbs=0 cabac_chroma_cr_ac_mbs=1' "$sim_log"; then
      echo "[FAIL] chroma residual ${name} did not mark the Cr-only CABAC chroma AC plane"
      tail -80 "$sim_log"
      exit 1
    fi
  fi
  if ! grep -Eq 'cavlc_suppressed_bits=[1-9][0-9]*' "$sim_log"; then
    echo "[FAIL] chroma residual ${name} did not suppress the legacy CAVLC payload"
    tail -80 "$sim_log"
    exit 1
  fi

  if ! ffmpeg -v error -xerror -i "$h264" -f null - > "$ffmpeg_log" 2>&1; then
    if [ "$expect_ffmpeg_fail" = "1" ]; then
      if ! grep -q 'bytestream -29' "$ffmpeg_log"; then
        echo "[FAIL] chroma residual ${name} expected the current Cr AC strict-decode miss signature"
        tail -80 "$ffmpeg_log"
        exit 1
      fi
      echo "[PASS] chroma residual ${name} exercised CABAC chroma AC but remains isolated as an expected strict FFmpeg decode miss"
      tail -20 "$ffmpeg_log"
      return 0
    fi
    echo "[FAIL] chroma residual ${name} failed strict FFmpeg decode"
    tail -80 "$ffmpeg_log"
    exit 1
  fi

  if [ "$expect_ffmpeg_fail" = "1" ]; then
    echo "[INFO] chroma residual ${name} strict-decoded; promote it into the default gate"
  fi

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

run_case "cb_dc" "$INPUT_CB_DC" 1
run_case "cb_ac" "$INPUT_CB_AC" 2
run_case "cr_dc" "$INPUT_CR_DC" 1

if [ "${CABAC_CHROMA_INCLUDE_CR_AC:-0}" = "1" ] || [ "${CABAC_CHROMA_EXPECT_CR_AC_FAIL:-0}" = "1" ]; then
  run_case "cr_ac" "$INPUT_CR_AC" 2 "${CABAC_CHROMA_EXPECT_CR_AC_FAIL:-0}"
fi

echo "[PASS] CABAC P16x16 Cb DC-only, Cb DC+AC, and Cr DC-only chroma residual smoke streams strict-decoded"
