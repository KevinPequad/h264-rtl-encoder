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
single_tl = bytes(136 if (x < 4 and y < 4 and ((x + y) % 2)) else 128 for y in range(H // 2) for x in range(W // 2))
single_tr = bytes(136 if (x >= 4 and y < 4 and ((x + y) % 2)) else 128 for y in range(H // 2) for x in range(W // 2))
single_bl = bytes(136 if (x < 4 and y >= 4 and ((x + y) % 2)) else 128 for y in range(H // 2) for x in range(W // 2))
single_br = bytes(136 if (x >= 4 and y >= 4 and ((x + y) % 2)) else 128 for y in range(H // 2) for x in range(W // 2))
patterns = {
    # Dense Cb-only AC is the current strict-decode control: the sparse Cb
    # mirrors below fail, while this full-plane checker still decodes. Keep the
    # pass case in the same probe run so the blocker stays narrowed to sparse AC
    # context/ordering behavior rather than all Cb AC emission.
    "cb_checker": (checker, flat_chroma),
    "checker": (flat_chroma, checker),
    "single_tl": (flat_chroma, single_tl),
    "single_tr": (flat_chroma, single_tr),
    "single_bl": (flat_chroma, single_bl),
    "single_br": (flat_chroma, single_br),
    "both_planes": (checker, checker),
    # Cb-only mirrors of the single-block Cr probes keep the blocker from being
    # misattributed to the Cr plane alone: identical sparse AC shapes currently
    # reproduce strict-decode misses on Cb too, with different signatures.
    "cb_mirror_single_tl": (single_tl, flat_chroma),
    "cb_mirror_single_tr": (single_tr, flat_chroma),
    "cb_mirror_single_bl": (single_bl, flat_chroma),
    "cb_mirror_single_br": (single_br, flat_chroma),
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
  local expected_blocks="${4:-cabac_chroma_cb_ac_blocks=0 cabac_chroma_cr_ac_blocks=4}"
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
  if ! grep -q "$expected_blocks" "$sim_log"; then
    echo "[FAIL] CR_AC ${name} did not match expected CABAC chroma AC block counters: ${expected_blocks}"
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

run_strict_pass() {
  local name="$1"
  local expected_counters="$2"
  local expected_blocks="$3"
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
    echo "[FAIL] CR_AC ${name} strict-pass control did not exercise integrated CABAC P16x16"
    tail -80 "$sim_log"
    exit 1
  fi
  if ! grep -q "$expected_counters" "$sim_log"; then
    echo "[FAIL] CR_AC ${name} strict-pass control did not match expected CABAC chroma AC counters: ${expected_counters}"
    tail -80 "$sim_log"
    exit 1
  fi
  if ! grep -q "$expected_blocks" "$sim_log"; then
    echo "[FAIL] CR_AC ${name} strict-pass control did not match expected CABAC chroma AC block counters: ${expected_blocks}"
    tail -80 "$sim_log"
    exit 1
  fi
  if ! grep -Eq 'cavlc_suppressed_bits=[1-9][0-9]*' "$sim_log"; then
    echo "[FAIL] CR_AC ${name} strict-pass control did not suppress the legacy CAVLC payload"
    tail -80 "$sim_log"
    exit 1
  fi

  if ! ffmpeg -v error -xerror -i "$h264" -f null - > "$ffmpeg_log" 2>&1; then
    echo "[FAIL] CR_AC ${name} strict-pass control failed strict FFmpeg decode"
    tail -80 "$ffmpeg_log"
    exit 1
  fi

  local raw_yuv
  local expected_bytes
  local actual_bytes
  raw_yuv="$(mktemp "/tmp/h264_cabac_cr_ac_${name}_decode.XXXXXX.yuv")"
  expected_bytes=$((16 * 16 * 3 / 2 * 2))
  ffmpeg -y -v error -xerror -i "$h264" -f rawvideo -pix_fmt yuv420p "$raw_yuv" > /dev/null 2>&1 || {
    echo "[FAIL] CR_AC ${name} strict-pass control failed raw FFmpeg frame extraction"
    rm -f "$raw_yuv"
    exit 1
  }
  actual_bytes="$(wc -c < "$raw_yuv")"
  if [ "$actual_bytes" -ne "$expected_bytes" ]; then
    echo "[FAIL] CR_AC ${name} strict-pass control decoded ${actual_bytes} bytes, expected ${expected_bytes} bytes for two 16x16 yuv420p frames"
    rm -f "$raw_yuv"
    exit 1
  fi

  python3 - "$name" "$input" "$raw_yuv" <<'PY'
import sys
from pathlib import Path

name, input_path, decoded_path = sys.argv[1:4]
width = height = 16
frame_size = width * height * 3 // 2
luma_size = width * height
chroma_size = width * height // 4
src = Path(input_path).read_bytes()
dec = Path(decoded_path).read_bytes()

if dec[:frame_size] != src[:frame_size]:
    raise SystemExit(f"[FAIL] CR_AC {name} strict-pass control changed the IDR reference frame")

frame1 = frame_size
u0 = frame1 + luma_size
v0 = u0 + chroma_size
u_sad = sum(abs(dec[u0 + i] - src[u0 + i]) for i in range(chroma_size))
v_sad = sum(abs(dec[v0 + i] - src[v0 + i]) for i in range(chroma_size))

if name.startswith("cb_"):
    if u_sad == 0 or v_sad != 0:
        raise SystemExit(
            f"[FAIL] CR_AC {name} strict-pass decoded plane sanity expected Cb-only change, got U_SAD={u_sad} V_SAD={v_sad}"
        )
elif name.startswith("cr_"):
    if v_sad == 0 or u_sad != 0:
        raise SystemExit(
            f"[FAIL] CR_AC {name} strict-pass decoded plane sanity expected Cr-only change, got U_SAD={u_sad} V_SAD={v_sad}"
        )
else:
    raise SystemExit(f"[FAIL] CR_AC {name} strict-pass control has no decoded-plane sanity expectation")

print(f"[PASS] CR_AC {name} strict-pass decoded-plane sanity U_SAD={u_sad} V_SAD={v_sad}")
PY
  rm -f "$raw_yuv"

  echo "[PASS] CR_AC ${name} strict-pass control FFmpeg-decoded with ${expected_counters} and ${expected_blocks}"
}

run_strict_pass cb_checker 'cabac_chroma_cb_ac_mbs=1 cabac_chroma_cr_ac_mbs=0' 'cabac_chroma_cb_ac_blocks=4 cabac_chroma_cr_ac_blocks=0'
run_expected_miss checker 'bytestream -29' 'cabac_chroma_cb_ac_mbs=0 cabac_chroma_cr_ac_mbs=1' 'cabac_chroma_cb_ac_blocks=0 cabac_chroma_cr_ac_blocks=4'
run_expected_miss single_tl 'bytestream -5' 'cabac_chroma_cb_ac_mbs=0 cabac_chroma_cr_ac_mbs=1' 'cabac_chroma_cb_ac_blocks=0 cabac_chroma_cr_ac_blocks=1'
run_expected_miss single_tr 'bytestream -11' 'cabac_chroma_cb_ac_mbs=0 cabac_chroma_cr_ac_mbs=1' 'cabac_chroma_cb_ac_blocks=0 cabac_chroma_cr_ac_blocks=1'
run_expected_miss single_bl 'bytestream -15' 'cabac_chroma_cb_ac_mbs=0 cabac_chroma_cr_ac_mbs=1' 'cabac_chroma_cb_ac_blocks=0 cabac_chroma_cr_ac_blocks=1'
run_expected_miss single_br 'bytestream -35' 'cabac_chroma_cb_ac_mbs=0 cabac_chroma_cr_ac_mbs=1' 'cabac_chroma_cb_ac_blocks=0 cabac_chroma_cr_ac_blocks=1'
run_expected_miss both_planes 'bytestream -22' 'cabac_chroma_cb_ac_mbs=1 cabac_chroma_cr_ac_mbs=1' 'cabac_chroma_cb_ac_blocks=4 cabac_chroma_cr_ac_blocks=4'
run_expected_miss cb_mirror_single_tl 'bytestream -9' 'cabac_chroma_cb_ac_mbs=1 cabac_chroma_cr_ac_mbs=0' 'cabac_chroma_cb_ac_blocks=1 cabac_chroma_cr_ac_blocks=0'
run_expected_miss cb_mirror_single_tr 'bytestream -15' 'cabac_chroma_cb_ac_mbs=1 cabac_chroma_cr_ac_mbs=0' 'cabac_chroma_cb_ac_blocks=1 cabac_chroma_cr_ac_blocks=0'
run_expected_miss cb_mirror_single_bl 'bytestream -15' 'cabac_chroma_cb_ac_mbs=1 cabac_chroma_cr_ac_mbs=0' 'cabac_chroma_cb_ac_blocks=1 cabac_chroma_cr_ac_blocks=0'
run_expected_miss cb_mirror_single_br 'bytestream -23' 'cabac_chroma_cb_ac_mbs=1 cabac_chroma_cr_ac_mbs=0' 'cabac_chroma_cb_ac_blocks=1 cabac_chroma_cr_ac_blocks=0'

echo "[PASS] CABAC P16x16 sparse chroma AC strict-decode blocker is reproduced across all single-block Cr-only quadrants, both-plane, and all single-block Cb-only mirror probes with a dense Cb-only strict-pass control"
