#!/bin/bash
set -euo pipefail

echo "=== H.264 Verilog Encoder Pipeline ==="

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

mkdir -p "$SCRIPT_DIR/data"
mkdir -p "$SCRIPT_DIR/output"

WIDTH="${WIDTH:-320}"
HEIGHT="${HEIGHT:-176}"
FPS="${FPS:-24}"
CLIP_SECONDS="${CLIP_SECONDS:-20}"
JOBS="${JOBS:-$(nproc)}"
FRAME_BYTES=$((WIDTH * HEIGHT * 3 / 2))
RAW_YUV="${RAW_YUV:-$SCRIPT_DIR/data/raw_frames.yuv}"
RAW_HEX_DIR="${RAW_HEX_DIR:-$SCRIPT_DIR/data}"
ENCODED_H264="${ENCODED_H264:-$SCRIPT_DIR/output/encoded.h264}"
OUTPUT_MP4="${OUTPUT_MP4:-$SCRIPT_DIR/output/output.mp4}"

OUTPUT_DIR="$SCRIPT_DIR/data"
export WIDTH HEIGHT FPS CLIP_SECONDS OUTPUT_DIR

echo "Step 1: Download and decode Big Buck Bunny (first 20 seconds)..."
bash "$SCRIPT_DIR/scripts/download_and_decode.sh"

echo ""
echo "Step 2: Convert raw YUV to memory format..."
python3 "$SCRIPT_DIR/scripts/yuv_to_mem.py" "$RAW_YUV" "$RAW_HEX_DIR"

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
echo "Build jobs:     ${JOBS}"

echo ""
echo "Step 3: Build, run, and package..."
JOBS="$JOBS" \
WIDTH="$WIDTH" \
HEIGHT="$HEIGHT" \
BIT_DEPTH="${BIT_DEPTH:-8}" \
CHROMA_FORMAT_IDC="${CHROMA_FORMAT_IDC:-1}" \
FRAMES="$FRAME_COUNT" \
TIMEOUT="$TIMEOUT" \
YUV_INPUT="$RAW_YUV" \
H264_OUTPUT="$ENCODED_H264" \
OUTPUT_MP4="$OUTPUT_MP4" \
bash "$SCRIPT_DIR/build_run.sh"

echo ""
echo "=== Done! Output: $OUTPUT_MP4 ==="
