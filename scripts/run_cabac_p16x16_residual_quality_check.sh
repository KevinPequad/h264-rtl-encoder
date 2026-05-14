#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
export PATH=/home/chudpc/.local/verilator-5.020/bin:$PATH

INPUT="data/smoke_32x16_2f_cabac_p16x16_residual.yuv"
python3 - <<'PY'
from pathlib import Path
W,H=32,16
out=Path('data/smoke_32x16_2f_cabac_p16x16_residual.yuv')
frames=[]
for yval in (64, 64):
    y=bytes([yval])*(W*H)
    u=bytes([128])*((W//2)*(H//2))
    v=bytes([128])*((W//2)*(H//2))
    frames.append(y+u+v)
out.write_bytes(b''.join(frames))
print(f"[INFO] residual fixture {out} size={out.stat().st_size}")
PY

LABEL="cabac_p16x16_residual_quality"
python3 scripts/validate_clip.py \
  --width 32 --height 16 --frames 2 \
  --input "$INPUT" \
  --label "$LABEL" \
  --skip-x264 --skip-compare --skip-mp4 \
  --enable-idr-ipcm 1 \
  --ipcm-sad-threshold 0 \
  --enable-cabac-p16x16 1

H264="output/validation_${LABEL}.h264"
DEC="output/validation_${LABEL}.dec.yuv"
ffmpeg -v error -i "$H264" -f rawvideo -pix_fmt yuv420p "$DEC" -y

python3 - <<'PY'
import json
from pathlib import Path
W,H,F=32,16,2
fs=W*H*3//2
summary=json.loads(Path('output/validation_cabac_p16x16_residual_quality.json').read_text())
cabac_mbs=summary.get('b_mode_summary', {}).get('total_cabac_p16x16', 0)
print(f"[INFO] total_cabac_p16x16={cabac_mbs}")
if cabac_mbs < 1:
    raise SystemExit('[FAIL] gate did not exercise CABAC P16x16 macroblocks')
psnr_avg=summary.get('rtl_metrics', {}).get('psnr', {}).get('average')
print(f"[INFO] rtl_psnr_avg={psnr_avg}")
if psnr_avg is None or float(psnr_avg) < 20.0:
    raise SystemExit(f"[FAIL] residual CABAC decode quality below smoke threshold: psnr_avg={psnr_avg}")
dec=Path('output/validation_cabac_p16x16_residual_quality.dec.yuv').read_bytes()
if len(dec) < fs*F:
    raise SystemExit(f"[FAIL] decoded output too short: {len(dec)} bytes")
for frame in range(F):
    dy=dec[frame*fs:frame*fs+W*H]
    avg=sum(dy)/len(dy)
    print(f"[INFO] frame={frame} decoded_y_avg={avg:.2f}")
print('[PASS] CABAC P16x16 residual gate exercised residual syntax and strict-decoded')
PY
