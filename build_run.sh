#!/bin/bash
set -e
BUILD=/tmp/h264_build
rm -rf "$BUILD"
mkdir -p "$BUILD"
cp -r "/mnt/c/Users/thoug/My Drive/SideHustle/h264_encoder/rtl" "$BUILD/"
cp -r "/mnt/c/Users/thoug/My Drive/SideHustle/h264_encoder/tb" "$BUILD/"
cp -r "/mnt/c/Users/thoug/My Drive/SideHustle/h264_encoder/data" "$BUILD/"
mkdir -p "$BUILD/output"

cd "$BUILD"
verilator --cc --exe -Wall -Wno-fatal --top-module h264_encoder_top \
  -Irtl rtl/*.v tb/tb_h264_encoder.cpp \
  -CFLAGS "-std=c++17" -o Vh264_encoder_top 2>&1 | tail -10
make -j$(nproc) -C obj_dir -f Vh264_encoder_top.mk 2>&1 | tail -3
echo "=== Build OK ==="

FRAMES=${1:-7}
TIMEOUT=${2:-500000000}
./obj_dir/Vh264_encoder_top +frames=$FRAMES +input=data/raw_frames.yuv \
  +output=output/encoded.h264 +timeout=$TIMEOUT 2>&1

OUTDIR="/mnt/c/Users/thoug/My Drive/SideHustle/h264_encoder/output"
cp output/encoded.h264 "$OUTDIR/encoded.h264"
cp output/ref_frame_*.raw "$OUTDIR/" 2>/dev/null || true
cp output/recon.yuv "$OUTDIR/recon.yuv" 2>/dev/null || true

# Decode and compare
ffmpeg -y -i output/encoded.h264 -pix_fmt yuv420p output/decoded.yuv 2>/dev/null
cp output/decoded.yuv "$OUTDIR/decoded.yuv"

cp '/mnt/c/Users/thoug/My Drive/SideHustle/h264_encoder/compare_all.py' .
python3 compare_all.py
cp '/mnt/c/Users/thoug/My Drive/SideHustle/h264_encoder/compare_yuv.py' .
python3 compare_yuv.py
echo "=== Done ==="
