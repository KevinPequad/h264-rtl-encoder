#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
cd "$REPO_ROOT"
export PATH=/home/chudpc/.local/verilator-5.020/bin:$PATH
mkdir -p data output logs tb/output
rm -f output/deblock_ref_frame0.h264 \
      output/deblock_ref_frame0_nodeblock.h264 \
      output/deblock_ref_expected.yuv \
      output/deblock_ref_expected_nodeblock.yuv \
      output/deblock_ref_2f.h264 \
      output/deblock_ref_2f_decoded.yuv \
      output/recon.yuv

WIDTH=32
HEIGHT=16
FRAME_SIZE=$((WIDTH * HEIGHT * 3 / 2))
COMMON_BUILD_ARGS=(
  WIDTH=$WIDTH HEIGHT=$HEIGHT BIT_DEPTH=8 CHROMA_FORMAT_IDC=1
  ENABLE_IDR_IPCM=0 ENABLE_P_IPCM=0 IPCM_SAD_THRESHOLD=0 INTER_SAD_THRESHOLD=999999
  EXTRA_VERILATOR_ARGS="--output-split 20000 --output-split-cfuncs 10000"
)

python3 - <<'PY'
from pathlib import Path
W,H=32,16
y=bytearray(W*H)
for r in range(H):
    for c in range(W):
        if c < 16:
            val = 58
        else:
            val = 64
        y[r*W+c]=val
cw,ch=W//2,H//2
cb=bytearray(cw*ch)
cr=bytearray(cw*ch)
for r in range(ch):
    for c in range(cw):
        cb[r*cw+c] = 118 if c < 8 else 124
        cr[r*cw+c] = 138 if c < 8 else 132
Path('data/deblock_ref_frame0.yuv').write_bytes(bytes(y+cb+cr))
PY

build_tb() {
  local deblock_enable=$1
  local disable_idc=$2
  local log_path=$3
  rm -rf tb/obj_dir
  make -C tb clean >/dev/null || true
  CCACHE_DISABLE=1 make -C tb all \
    "${COMMON_BUILD_ARGS[@]}" \
    DEBLOCK_ENABLE="$deblock_enable" DISABLE_DEBLOCKING_FILTER_IDC="$disable_idc" \
    2>&1 | tee "$log_path"
}

build_tb 0 1 logs/deblock_reference_build_nodeblock.log
./tb/Vh264_encoder_top \
  +frames=1 +timeout=20000000 \
  +input=data/deblock_ref_frame0.yuv \
  +output=output/deblock_ref_frame0_nodeblock.h264 \
  2>&1 | tee logs/deblock_reference_idr_nodeblock.sim.log
ffmpeg -y -v error -xerror -i output/deblock_ref_frame0_nodeblock.h264 \
  -f rawvideo -pix_fmt yuv420p output/deblock_ref_expected_nodeblock.yuv \
  2>&1 | tee logs/deblock_reference_idr_nodeblock.ffmpeg.log

build_tb 1 0 logs/deblock_reference_build.log
./tb/Vh264_encoder_top \
  +frames=1 +timeout=20000000 \
  +input=data/deblock_ref_frame0.yuv \
  +output=output/deblock_ref_frame0.h264 \
  2>&1 | tee logs/deblock_reference_idr.sim.log
ffmpeg -y -v error -xerror -i output/deblock_ref_frame0.h264 \
  -f rawvideo -pix_fmt yuv420p output/deblock_ref_expected.yuv \
  2>&1 | tee logs/deblock_reference_idr.ffmpeg.log

python3 - <<'PY'
from pathlib import Path
f0=Path('data/deblock_ref_frame0.yuv').read_bytes()
nodeblock=Path('output/deblock_ref_expected_nodeblock.yuv').read_bytes()
expected=Path('output/deblock_ref_expected.yuv').read_bytes()
if len(f0) != len(expected) or len(nodeblock) != len(expected):
    raise SystemExit(f'frame size mismatch: src={len(f0)} nodeblock={len(nodeblock)} expected={len(expected)}')
source_diff=sum(a!=b for a,b in zip(f0, expected))
deblock_diff=sum(a!=b for a,b in zip(nodeblock, expected))
print(f'[DEBLOCK_REF_FIXTURE] decoder-enabled frame0 differs from source in {source_diff} samples')
print(f'[DEBLOCK_REF_FIXTURE] deblock_enabled_vs_disabled_diff={deblock_diff}')
if deblock_diff == 0:
    raise SystemExit('fixture did not exercise deblocking; enabled and disabled decodes matched')
Path('data/deblock_ref_2f.yuv').write_bytes(f0 + expected)
PY

set +e
./tb/Vh264_encoder_top \
  +frames=2 +timeout=30000000 \
  +input=data/deblock_ref_2f.yuv \
  +output=output/deblock_ref_2f.h264 \
  +expected_ref=output/deblock_ref_expected.yuv \
  2>&1 | tee logs/deblock_reference_2f.sim.log
sim_status=${PIPESTATUS[0]}
set -e
if [ "$sim_status" -ne 0 ]; then
  echo "[DEBLOCK_REF_CHECK] simulator/reference check failed with status $sim_status" >&2
  exit "$sim_status"
fi

ffmpeg -y -v error -xerror -i output/deblock_ref_2f.h264 \
  -f rawvideo -pix_fmt yuv420p output/deblock_ref_2f_decoded.yuv \
  2>&1 | tee logs/deblock_reference_2f.ffmpeg.log

python3 - <<'PY'
from pathlib import Path
recon=Path('output/recon.yuv').read_bytes()
dec=Path('output/deblock_ref_2f_decoded.yuv').read_bytes()
if len(recon) != len(dec):
    raise SystemExit(f'recon/decode size mismatch: {len(recon)} vs {len(dec)}')
mism=sum(a!=b for a,b in zip(recon, dec))
print(f'[DEBLOCK_REF_CHECK] recon_vs_decoder_mismatches={mism}')
if mism:
    for i,(a,b) in enumerate(zip(recon,dec)):
        if a != b:
            print(f'[DEBLOCK_REF_CHECK] first_mismatch_offset={i} recon={a} decoded={b}')
            break
    raise SystemExit(1)
PY

echo "[DEBLOCK_REF_CHECK] PASS"
