#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

mkdir -p build/asic
LOG_DIR="${ASIC_LOG_DIR:-build/asic}"
mkdir -p "$LOG_DIR"

TOP="${ASIC_TOP:-h264_encoder_top}"
RTL_FILES=(rtl/*.v)

echo "[asic] Verilator frontend lint for $TOP"
verilator --lint-only --timing -Wall -Wno-fatal \
  -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-WIDTH \
  -Wno-PINCONNECTEMPTY -Wno-BLKSEQ -Wno-CASEINCOMPLETE --top-module "$TOP" \
  "${RTL_FILES[@]}" 2>&1 | tee "$LOG_DIR/verilator_frontend_lint.log"

if command -v yosys >/dev/null 2>&1; then
  echo "[asic] Yosys frontend smoke"
  yosys -s scripts/asic_yosys_smoke.ys 2>&1 | tee "$LOG_DIR/yosys_frontend_smoke.log"
else
  echo "[asic] Yosys not installed; skipped Yosys smoke after Verilator frontend lint." | tee "$LOG_DIR/yosys_frontend_smoke.log"
fi
