#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

WIDTH="${WIDTH:-320}"
HEIGHT="${HEIGHT:-176}"
BIT_DEPTH="${BIT_DEPTH:-8}"
CHROMA_FORMAT_IDC="${CHROMA_FORMAT_IDC:-1}"
FRAMES="${FRAMES:-1}"
TIMEOUT="${TIMEOUT:-100000000}"
JOBS="${JOBS:-$(nproc)}"
YUV_INPUT="${YUV_INPUT:-$SCRIPT_DIR/data/raw_frames.yuv}"
H264_OUTPUT="${H264_OUTPUT:-$SCRIPT_DIR/output/manual_run.h264}"
OUTPUT_MP4="${OUTPUT_MP4:-$SCRIPT_DIR/output/manual_run.mp4}"
PACKAGE_MP4="${PACKAGE_MP4:-1}"

mkdir -p "$SCRIPT_DIR/output"

if [ ! -s "$YUV_INPUT" ]; then
    echo "ERROR: Missing input YUV: $YUV_INPUT" >&2
    exit 1
fi

echo "Building simulator..."
make -C "$SCRIPT_DIR/tb" -j"$JOBS" all \
    WIDTH="$WIDTH" \
    HEIGHT="$HEIGHT" \
    BIT_DEPTH="$BIT_DEPTH" \
    CHROMA_FORMAT_IDC="$CHROMA_FORMAT_IDC"

echo "Running RTL encoder..."
"$SCRIPT_DIR/tb/Vh264_encoder_top" \
    +frames="$FRAMES" \
    +timeout="$TIMEOUT" \
    +input="$YUV_INPUT" \
    +output="$H264_OUTPUT"

if [ "$PACKAGE_MP4" = "1" ]; then
    echo "Packaging MP4..."
    python3 "$SCRIPT_DIR/scripts/package_mp4.py" \
        "$H264_OUTPUT" \
        "$OUTPUT_MP4" \
        --fps "${FPS:-24}" \
        --width "$WIDTH" \
        --height "$HEIGHT"
fi

echo "Done."
echo "  H.264: $H264_OUTPUT"
if [ "$PACKAGE_MP4" = "1" ]; then
    echo "  MP4:   $OUTPUT_MP4"
fi
