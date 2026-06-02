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
    "bitstream_has_chroma_payload_ports": "input  wire [511:0] cabac_chroma_dc_scan_flat" in bitstream and "input  wire [4095:0] cabac_chroma_scan_flat" in bitstream and "input  wire [15:0] cabac_chroma_nz_mask" in bitstream,
    "bitstream_has_second_chroma_cbp_context": "cabac_cbp_chroma_ctx_state_78" in bitstream,
    "bitstream_has_chroma_coeff_helpers": "function automatic signed [15:0] cabac_chroma_coeff_at" in bitstream and "function automatic signed [15:0] cabac_chroma_dc_coeff_at" in bitstream and "function automatic cabac_chroma_cbf_at" in bitstream and "function automatic [3:0] cabac_chroma_last_nonzero_coeff_idx" in bitstream,
    "bitstream_emits_chroma_cbp_nonzero_bin": "cabac_bin_value <= (cabac_cbp_chroma != 2'd0);" in bitstream,
    "bitstream_emits_chroma_cbp_ac_bin": "cabac_bin_value <= (cabac_cbp_chroma == 2'd2);" in bitstream,
    "top_captures_chroma_ac_payload_snapshot": "cabac_chroma_scan_flat_reg[cabac_chroma_payload_blk_idx(chr_is_cr, chr_blk) * 256 +: 256] <= scan_flat;" in top,
    "top_captures_chroma_dc_payload_snapshots": "cabac_chroma_dc_scan_flat_reg[0 +: 256] <= scan_flat;" in top and "cabac_chroma_dc_scan_flat_reg[256 +: 256] <= scan_flat;" in top,
    "top_tracks_chroma_ac_nz_mask": "cabac_chroma_nz_mask_reg[cabac_chroma_payload_blk_idx(chr_is_cr, chr_blk)] <= (total_coeffs != 5'd0);" in top,
    "top_tracks_chroma_cbp_dc_class": "cabac_cbp_chroma_reg <= (cabac_cbp_chroma_reg == 2'd2) ? 2'd2 : 2'd1;" in top,
    "top_tracks_chroma_cbp_ac_class": "cabac_cbp_chroma_reg <= 2'd2;" in top,
    "top_keeps_chroma_cbp_dormant_until_payload_scheduler": ".cabac_cbp_chroma(cabac_cbp_chroma_dormant_w)" in top and "cabac_cbp_chroma_reg & 2'd0" in top,
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
