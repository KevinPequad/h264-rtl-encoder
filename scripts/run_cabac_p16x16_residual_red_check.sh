#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
echo "[INFO] RED gate promoted: running CABAC P16x16 luma residual GREEN check"
exec "$ROOT/scripts/run_cabac_p16x16_residual_green_check.sh"
