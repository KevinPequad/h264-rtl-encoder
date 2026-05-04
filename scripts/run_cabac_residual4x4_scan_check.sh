#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d /tmp/h264_cabac_residual4x4_scan.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

cd "$ROOT"
export PATH=/home/chudpc/.local/verilator-5.020/bin:$PATH

verilator --cc --exe --build \
  -Wall -Wno-fatal \
  --Mdir "$TMP_DIR/obj_dir" \
  --top-module h264_cabac_residual4x4_scan \
  -I"$ROOT/rtl" \
  "$ROOT/rtl/h264_cabac_residual4x4_scan.v" \
  "$ROOT/tb/tb_cabac_residual4x4_scan.cpp" \
  -o Vh264_cabac_residual4x4_scan

"$TMP_DIR/obj_dir/Vh264_cabac_residual4x4_scan"
