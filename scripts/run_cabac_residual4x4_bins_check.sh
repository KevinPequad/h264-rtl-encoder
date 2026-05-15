#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
export PATH=/home/chudpc/.local/verilator-5.020/bin:$PATH

BUILD_DIR="$(mktemp -d /tmp/h264_cabac_residual_bins.XXXXXX)"
verilator --cc --exe --build --threads 1 -Wall -Wno-fatal \
  --top-module h264_cabac_residual4x4_bins \
  -I"$ROOT/rtl" \
  "$ROOT/rtl/h264_cabac_residual4x4_bins.v" \
  "$ROOT/tb/tb_cabac_residual4x4_bins.cpp" \
  --Mdir "$BUILD_DIR/obj_dir" \
  -o Vh264_cabac_residual4x4_bins
"$BUILD_DIR/obj_dir/Vh264_cabac_residual4x4_bins"
