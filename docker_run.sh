#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
IMAGE_NAME="${IMAGE_NAME:-h264-encoder}"
DOCKER_SCRIPT="${DOCKER_SCRIPT:-/workspace/docker/run_one_frame.sh}"

echo "Building Docker container..."
docker build -t "$IMAGE_NAME" "$SCRIPT_DIR/docker"

echo "Running encoder pipeline in Docker..."
docker run --rm -it \
    -v "$SCRIPT_DIR:/workspace" \
    "$IMAGE_NAME" \
    bash "$DOCKER_SCRIPT"
