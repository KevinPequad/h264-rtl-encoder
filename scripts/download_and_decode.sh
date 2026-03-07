#!/bin/bash
set -e

VIDEO_URL="${VIDEO_URL:-https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4}"
OUTPUT_DIR="${OUTPUT_DIR:-/workspace/data}"
WIDTH="${WIDTH:-320}"
HEIGHT="${HEIGHT:-176}"
FPS="${FPS:-24}"
CLIP_SECONDS="${CLIP_SECONDS:-20}"
mkdir -p "$OUTPUT_DIR"

echo "Downloading Big Buck Bunny..."
if ! wget -q -O "$OUTPUT_DIR/bigbuckbunny.mp4" "$VIDEO_URL"; then
    echo "ERROR: Failed to download video" >&2
    exit 1
fi

if [ ! -s "$OUTPUT_DIR/bigbuckbunny.mp4" ]; then
    echo "ERROR: Downloaded file is empty" >&2
    exit 1
fi

echo "Decoding first ${CLIP_SECONDS} seconds to raw YUV420 at ${WIDTH}x${HEIGHT}..."
ffmpeg -y -i "$OUTPUT_DIR/bigbuckbunny.mp4" \
    -t "$CLIP_SECONDS" \
    -vf "fps=${FPS},scale=${WIDTH}:${HEIGHT}" \
    -pix_fmt yuv420p \
    -f rawvideo \
    "$OUTPUT_DIR/raw_frames.yuv"

if [ ! -s "$OUTPUT_DIR/raw_frames.yuv" ]; then
    echo "ERROR: Failed to produce raw_frames.yuv" >&2
    exit 1
fi

# Compute frame count from file size
FRAME_BYTES=$((WIDTH * HEIGHT * 3 / 2))
FILE_SIZE=$(stat -c%s "$OUTPUT_DIR/raw_frames.yuv" 2>/dev/null || stat -f%z "$OUTPUT_DIR/raw_frames.yuv")
FRAME_COUNT=$((FILE_SIZE / FRAME_BYTES))

echo "Extracted $FRAME_COUNT frames"
echo "Frame size: ${WIDTH}x${HEIGHT} YUV420 = $FRAME_BYTES bytes per frame"
echo "Total raw size: $FILE_SIZE bytes"

# Create a single test frame for initial testing
ffmpeg -y -i "$OUTPUT_DIR/bigbuckbunny.mp4" \
    -frames:v 1 \
    -vf "scale=${WIDTH}:${HEIGHT}" \
    -pix_fmt yuv420p \
    -f rawvideo \
    "$OUTPUT_DIR/test_frame.yuv"

echo "Created test_frame.yuv (single frame for initial testing)"
