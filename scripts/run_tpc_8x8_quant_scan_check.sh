#!/usr/bin/env bash
set -euo pipefail
BIT_DEPTH=8
QP_SWEEP="0,6,12,18,24,30,36,42,48,51"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --bit-depth) BIT_DEPTH="$2"; shift 2 ;;
    --qp-sweep) QP_SWEEP="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
if [[ "$BIT_DEPTH" != "8" && "$BIT_DEPTH" != "10" ]]; then
  echo "--bit-depth must be 8 or 10" >&2
  exit 2
fi
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"
mkdir -p output build
if [[ -x /home/chudpc/.local/verilator-5.020/bin/verilator ]]; then
  VERILATOR=${VERILATOR:-/home/chudpc/.local/verilator-5.020/bin/verilator}
else
  VERILATOR=${VERILATOR:-verilator}
fi
LABEL="tpc_8x8_quant_dequant_unit_${BIT_DEPTH}b"
BUILD_DIR="build/${LABEL}"
BUILD_LOG="output/${LABEL}.build.log"
SIM_LOG="output/${LABEL}.log"
SCAN_LOG="output/tpc_8x8_scan_unit.log"
rm -rf "$BUILD_DIR"
{
  echo "LABEL=$LABEL"
  echo "VERILATOR=$($VERILATOR --version)"
  echo "BIT_DEPTH=$BIT_DEPTH"
  echo "QP_SWEEP=$QP_SWEEP"
  echo "SOURCES=tb/h264_tpc_8x8_unit_top.v rtl/h264_transform8x8.v rtl/h264_inverse_transform8x8.v rtl/h264_quantize8x8.v rtl/h264_inverse_quant8x8.v rtl/h264_zigzag8x8.v tb/tb_tpc_8x8_unit.cpp"
  OBJCACHE= "$VERILATOR" --cc --exe --build -j "$(nproc)" \
    -Wall -Wno-fatal -Wno-WIDTH -Wno-UNSIGNED -Wno-BLKSEQ -Wno-UNUSEDSIGNAL \
    --top-module h264_tpc_8x8_unit_top -I"$ROOT/rtl" -Mdir "$BUILD_DIR" \
    -GBIT_DEPTH="$BIT_DEPTH" \
    -CFLAGS "-O2 -std=c++17" \
    "$ROOT/rtl/h264_transform8x8.v" \
    "$ROOT/rtl/h264_inverse_transform8x8.v" \
    "$ROOT/rtl/h264_quantize8x8.v" \
    "$ROOT/rtl/h264_inverse_quant8x8.v" \
    "$ROOT/rtl/h264_zigzag8x8.v" \
    "$ROOT/tb/h264_tpc_8x8_unit_top.v" \
    "$ROOT/tb/tb_tpc_8x8_unit.cpp" \
    -o Vh264_tpc_8x8_unit_top
} >"$BUILD_LOG" 2>&1
"$BUILD_DIR/Vh264_tpc_8x8_unit_top" +mode=quant_dequant +bit_depth="$BIT_DEPTH" +qp_sweep="$QP_SWEEP" >"$SIM_LOG" 2>&1
"$BUILD_DIR/Vh264_tpc_8x8_unit_top" +mode=scan +bit_depth="$BIT_DEPTH" >"$SCAN_LOG" 2>&1
cat "$SIM_LOG"
cat "$SCAN_LOG"
echo "build_log=$BUILD_LOG"
echo "sim_log=$SIM_LOG"
echo "scan_log=$SCAN_LOG"
