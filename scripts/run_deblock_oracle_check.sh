#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
cd "$REPO_ROOT/tb"
export PATH=/home/chudpc/.local/verilator-5.020/bin:$PATH
JOBS=${BUILD_JOBS:-$(nproc)}
rm -rf obj_dir_deblock_edge Vh264_deblock_check_top
verilator --cc --exe --build -Wall -Wno-fatal --top-module h264_deblock_check_top \
  -I../rtl -Mdir obj_dir_deblock_edge -j "$JOBS" \
  ../rtl/h264_deblock_tables.v ../rtl/h264_deblock_edge.v h264_deblock_check_top.v tb_h264_deblock_edge.cpp \
  -CFLAGS "-O2 -std=c++17" \
  -o Vh264_deblock_check_top
./obj_dir_deblock_edge/Vh264_deblock_check_top
