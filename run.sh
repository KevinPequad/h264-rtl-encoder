#!/bin/bash
set -e

echo "=== H.264 Verilog Encoder Pipeline ==="

mkdir -p /workspace/data
mkdir -p /workspace/output

WIDTH="${WIDTH:-320}"
HEIGHT="${HEIGHT:-176}"
FPS="${FPS:-24}"
CLIP_SECONDS="${CLIP_SECONDS:-20}"
FRAME_BYTES=$((WIDTH * HEIGHT * 3 / 2))
RAW_YUV="${RAW_YUV:-/workspace/data/raw_frames.yuv}"
RAW_HEX_DIR="${RAW_HEX_DIR:-/workspace/data}"
ENCODED_H264="${ENCODED_H264:-/workspace/output/encoded.h264}"
OUTPUT_MP4="${OUTPUT_MP4:-/workspace/output/output.mp4}"

export WIDTH HEIGHT FPS CLIP_SECONDS

echo "Step 1: Download and decode Big Buck Bunny (first 20 seconds)..."
bash /workspace/scripts/download_and_decode.sh

echo ""
echo "Step 2: Convert raw YUV to memory format..."
python3 /workspace/scripts/yuv_to_mem.py "$RAW_YUV" "$RAW_HEX_DIR"

if [ ! -s "$RAW_YUV" ]; then
    echo "ERROR: Missing raw YUV input: $RAW_YUV" >&2
    exit 1
fi

RAW_SIZE=$(stat -c%s "$RAW_YUV")
FRAME_COUNT=$((RAW_SIZE / FRAME_BYTES))
TIMEOUT="${TIMEOUT:-500000000}"

if [ "$FRAME_COUNT" -le 0 ]; then
    echo "ERROR: No complete YUV frames found in $RAW_YUV" >&2
    exit 1
fi

echo "Frame geometry: ${WIDTH}x${HEIGHT} @ ${FPS} fps"
echo "Raw input size: ${RAW_SIZE} bytes"
echo "Frame count:    ${FRAME_COUNT}"
echo "Sim timeout:    ${TIMEOUT} cycles"

echo ""
echo "Step 3: Build Verilator simulation..."
cd /workspace/tb
make clean && make

echo ""
echo "Step 4: Run H.264 encoder simulation..."
rm -f "$ENCODED_H264" "$OUTPUT_MP4"
./Vh264_encoder_top \
    +frames="$FRAME_COUNT" \
    +timeout="$TIMEOUT" \
    +input="$RAW_YUV" \
    +output="$ENCODED_H264"

echo ""
echo "Step 5: Package encoded bitstream to MP4..."
python3 /workspace/scripts/package_mp4.py \
    "$ENCODED_H264" \
    "$OUTPUT_MP4" \
    --fps "$FPS" \
    --width "$WIDTH" \
    --height "$HEIGHT"

echo ""
echo "=== Done! Output: $OUTPUT_MP4 ==="
