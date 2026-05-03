#!/usr/bin/env bash
set -euo pipefail

# Run from anywhere; script resolves repo root.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

mkdir -p build/asic
exec yosys -s scripts/asic_yosys_smoke.ys "$@"
