#!/bin/bash
set -euo pipefail

WORKSPACE="${WORKSPACE:-/workspace}"
WIDTH="${WIDTH:-320}"
HEIGHT="${HEIGHT:-176}"
BIT_DEPTH="${BIT_DEPTH:-8}"
CHROMA_FORMAT_IDC="${CHROMA_FORMAT_IDC:-1}"
FPS="${FPS:-24}"
FRAMES="${FRAMES:-1}"
TIMEOUT="${TIMEOUT:-100000000}"
VIDEO_URL="${VIDEO_URL:-https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4}"
INPUT_MP4="${INPUT_MP4:-$WORKSPACE/data/bigbuckbunny.mp4}"
RAW_YUV="${RAW_YUV:-$WORKSPACE/data/docker_${WIDTH}x${HEIGHT}_${FRAMES}f.yuv}"
OUTPUT_H264="${OUTPUT_H264:-$WORKSPACE/output/docker_${WIDTH}x${HEIGHT}_${FRAMES}f.h264}"
OUTPUT_MP4="${OUTPUT_MP4:-$WORKSPACE/output/docker_${WIDTH}x${HEIGHT}_${FRAMES}f.mp4}"

mkdir -p "$WORKSPACE/data" "$WORKSPACE/output"

if [ ! -s "$INPUT_MP4" ]; then
    echo "Downloading Big Buck Bunny into $INPUT_MP4"
    wget -q -O "$INPUT_MP4" "$VIDEO_URL"
fi

if [ ! -s "$RAW_YUV" ]; then
    echo "Extracting $FRAMES frame(s) at ${WIDTH}x${HEIGHT} to $RAW_YUV"
    ffmpeg -y -hide_banner -loglevel error \
        -i "$INPUT_MP4" \
        -vf "scale=${WIDTH}:${HEIGHT},fps=${FPS}" \
        -frames:v "$FRAMES" \
        -pix_fmt yuv420p \
        -f rawvideo \
        "$RAW_YUV"
fi

BUILD_DIR="$(mktemp -d /tmp/h264_docker_build_XXXXXX)"
trap 'rm -rf "$BUILD_DIR"' EXIT

cp -r "$WORKSPACE/rtl" "$BUILD_DIR/"
cp -r "$WORKSPACE/tb" "$BUILD_DIR/"

echo "Building simulator in $BUILD_DIR"
make -C "$BUILD_DIR/tb" -j"$(nproc)" all \
    WIDTH="$WIDTH" \
    HEIGHT="$HEIGHT" \
    BIT_DEPTH="$BIT_DEPTH" \
    CHROMA_FORMAT_IDC="$CHROMA_FORMAT_IDC"

echo "Running $FRAMES frame(s) in Docker"
"$BUILD_DIR/tb/Vh264_encoder_top" \
    +frames="$FRAMES" \
    +timeout="$TIMEOUT" \
    +input="$RAW_YUV" \
    +output="$OUTPUT_H264"

echo "Packaging MP4 to $OUTPUT_MP4"
python3 "$WORKSPACE/scripts/package_mp4.py" \
    "$OUTPUT_H264" \
    "$OUTPUT_MP4" \
    --fps "$FPS" \
    --width "$WIDTH" \
    --height "$HEIGHT"

ffprobe -v error -select_streams v:0 \
    -show_entries stream=codec_name,profile,width,height,nb_frames \
    -of json "$OUTPUT_MP4" || true

echo "Docker smoke run complete"
echo "  H.264: $OUTPUT_H264"
echo "  MP4:   $OUTPUT_MP4"

