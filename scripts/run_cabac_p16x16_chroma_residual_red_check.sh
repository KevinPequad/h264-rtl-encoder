#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

python3 - <<'PY'
from pathlib import Path
root = Path.cwd()
bitstream = (root / "rtl/h264_bitstream.v").read_text()
top = (root / "rtl/h264_encoder_top.v").read_text()
runner = (root / "scripts/rtl_runner.py").read_text()
checks = {
    "bitstream_has_chroma_cbp_port": "input  wire [1:0]  cabac_cbp_chroma" in bitstream,
    "bitstream_has_second_chroma_cbp_context": "cabac_cbp_chroma_ctx_state_78" in bitstream,
    "bitstream_emits_chroma_cbp_nonzero_bin": "cabac_bin_value <= (cabac_cbp_chroma != 2'd0);" in bitstream,
    "bitstream_emits_chroma_cbp_ac_bin": "cabac_bin_value <= (cabac_cbp_chroma == 2'd2);" in bitstream,
    "top_keeps_chroma_cbp_dormant_until_payload_scheduler": ".cabac_cbp_chroma(2'd0)" in top,
    "rtl_runner_honors_build_jobs_env": "os.environ.get(\"BUILD_JOBS\")" in runner,
}
failed = [name for name, ok in checks.items() if not ok]
for name, ok in checks.items():
    print(f"[{'PASS' if ok else 'FAIL'}] {name}")
if failed:
    raise SystemExit("missing CABAC chroma residual scaffold checks: " + ", ".join(failed))
PY

THREADS="${THREADS:-1}" BUILD_JOBS="${BUILD_JOBS:-1}" \
  python3 scripts/regress_smoke_matrix.py --case smoke_8b_420_cabac_p16x16
