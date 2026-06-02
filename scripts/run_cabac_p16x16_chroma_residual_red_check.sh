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
    "bitstream_has_chroma_dc_sign_helper": "function automatic cabac_chroma_dc_coeff_sign_at" in bitstream and "cabac_chroma_dc_coeff_sign_at = coeff_i[15];" in bitstream,
    "bitstream_has_chroma_dc_cbf_helper": "function automatic cabac_chroma_dc_cbf_at" in bitstream and "cabac_chroma_dc_cbf_at = 1'b1;" in bitstream,
    "bitstream_has_unified_chroma_payload_helpers": "function automatic cabac_chroma_payload_cbf_at" in bitstream and "function automatic [3:0] cabac_chroma_payload_last_nonzero_coeff_idx" in bitstream and "function automatic [15:0] cabac_chroma_payload_coeff_abs_at" in bitstream and "function automatic cabac_chroma_payload_coeff_sign_at" in bitstream,
    "bitstream_unifies_chroma_dc_ac_payload_selection": "payload_is_dc_i ?" in bitstream and "cabac_chroma_dc_cbf_at(plane_is_cr_i)" in bitstream and "cabac_chroma_cbf_at(blk_idx_i)" in bitstream and "cabac_chroma_dc_coeff_sign_at(plane_is_cr_i, coeff_idx_i)" in bitstream and "cabac_chroma_coeff_sign_at(blk_idx_i, coeff_idx_i)" in bitstream,
    "bitstream_has_chroma_payload_cursor_state": "reg        cabac_res_payload_is_chroma;" in bitstream and "reg        cabac_res_chroma_payload_is_dc;" in bitstream and "reg        cabac_res_chroma_plane_is_cr;" in bitstream and "reg [4:0]  cabac_res_chroma_payload_idx;" in bitstream and "reg [3:0]  cabac_res_chroma_blk_idx;" in bitstream and "reg [3:0]  cabac_res_payload_coeff_limit;" in bitstream,
    "bitstream_has_chroma_payload_cursor_helpers": "CABAC_CHROMA_PAYLOAD_DC_CB" in bitstream and "CABAC_CHROMA_PAYLOAD_DC_CR" in bitstream and "CABAC_CHROMA_PAYLOAD_AC_FIRST" in bitstream and "function automatic [3:0] cabac_chroma_payload_coeff_limit" in bitstream and "function automatic cabac_chroma_payload_cursor_is_dc" in bitstream and "function automatic cabac_chroma_payload_cursor_plane_is_cr" in bitstream and "function automatic [3:0] cabac_chroma_payload_cursor_blk_idx" in bitstream,
    "bitstream_widens_chroma_payload_cursor_for_422": "localparam [4:0] CABAC_CHROMA_PAYLOAD_DC_CB = 5'd0;" in bitstream and "input [4:0] payload_idx_i" in bitstream and "function automatic [4:0] cabac_chroma_payload_total" in bitstream and "5'd18" in bitstream,
    "bitstream_resets_chroma_payload_cursor_state": bitstream.count("cabac_res_payload_is_chroma <= 1'b0;") >= 2 and bitstream.count("cabac_res_chroma_payload_is_dc <= 1'b0;") >= 2 and bitstream.count("cabac_res_chroma_plane_is_cr <= 1'b0;") >= 2 and bitstream.count("cabac_res_chroma_payload_idx <= 5'd0;") >= 2 and bitstream.count("cabac_res_chroma_blk_idx <= 4'd0;") >= 2 and bitstream.count("cabac_res_payload_coeff_limit <= 4'd0;") >= 2,
    "bitstream_stages_chroma_payload_cursor_after_cbp": "cabac_res_chroma_payload_idx <= CABAC_CHROMA_PAYLOAD_DC_CB;" in bitstream and "cabac_res_chroma_payload_is_dc <= cabac_chroma_payload_cursor_is_dc(CABAC_CHROMA_PAYLOAD_DC_CB);" in bitstream and "cabac_res_chroma_plane_is_cr <= cabac_chroma_payload_cursor_plane_is_cr(CABAC_CHROMA_PAYLOAD_DC_CB);" in bitstream and "cabac_res_chroma_blk_idx <= cabac_chroma_payload_cursor_blk_idx(CABAC_CHROMA_PAYLOAD_DC_CB);" in bitstream and "cabac_res_payload_coeff_limit <= cabac_chroma_payload_coeff_limit(" in bitstream,
    "bitstream_has_chroma_payload_active_total": "function automatic [4:0] cabac_chroma_payload_active_total" in bitstream and "2'd1: cabac_chroma_payload_active_total = 5'd2;" in bitstream and "default: cabac_chroma_payload_active_total = cabac_chroma_payload_total();" in bitstream,
    "bitstream_enters_chroma_payload_after_luma": "cabac_res_payload_is_chroma <= 1'b1;" in bitstream and "cabac_bin_value <= cabac_chroma_payload_cbf_at(" in bitstream and "sub <= 6'd55;" in bitstream,
    "bitstream_schedules_chroma_payload_coeff_bins": "6'd55: begin" in bitstream and "CABAC chroma coded_block_flag overflow" in bitstream and "6'd56: begin" in bitstream and "cabac_chroma_payload_last_nonzero_coeff_idx(" in bitstream and "6'd59: begin" in bitstream and "cabac_chroma_payload_coeff_sign_at(" in bitstream,
    "bitstream_advances_chroma_payload_cursor": "cabac_res_chroma_has_next_payload_w" in bitstream and "cabac_res_chroma_payload_idx <= cabac_res_chroma_next_payload_idx_w;" in bitstream and "cabac_res_chroma_payload_is_dc <= cabac_res_next_chroma_payload_is_dc_w;" in bitstream,
    "bitstream_bounds_chroma_coeff_helpers": "localparam integer CABAC_CHROMA_AC_COEFFS = 15;" in bitstream and "localparam integer CABAC_CHROMA_DC_COEFFS = (CHROMA_FORMAT_IDC == 2) ? 8 : 4;" in bitstream and "coeff_i < CABAC_CHROMA_AC_COEFFS" in bitstream and bitstream.count("coeff_i < CABAC_CHROMA_DC_COEFFS") >= 2,
    "bitstream_emits_chroma_cbp_nonzero_bin": "cabac_bin_value <= (cabac_cbp_chroma != 2'd0);" in bitstream,
    "bitstream_emits_chroma_cbp_ac_bin": "cabac_bin_value <= (cabac_cbp_chroma == 2'd2);" in bitstream,
    "top_captures_chroma_ac_payload_snapshot": "cabac_chroma_scan_flat_reg[cabac_chroma_payload_blk_idx(chr_is_cr, chr_blk) * 256 +: 256] <= scan_flat;" in top,
    "top_captures_chroma_dc_payload_snapshots": "cabac_chroma_dc_scan_flat_reg[0 +: 256] <= scan_flat;" in top and "cabac_chroma_dc_scan_flat_reg[256 +: 256] <= scan_flat;" in top,
    "top_tracks_chroma_ac_nz_mask": "cabac_chroma_nz_mask_reg[cabac_chroma_payload_blk_idx(chr_is_cr, chr_blk)] <= (total_coeffs != 5'd0);" in top,
    "top_tracks_chroma_dc_snapshot_validity": "reg [1:0]    cabac_chroma_dc_valid_mask_reg;" in top and "cabac_chroma_dc_valid_mask_reg[0] <= 1'b1;" in top and "cabac_chroma_dc_valid_mask_reg[1] <= 1'b1;" in top,
    "top_tracks_chroma_ac_snapshot_validity": "reg [15:0]   cabac_chroma_ac_valid_mask_reg;" in top and "cabac_chroma_ac_valid_mask_reg[cabac_chroma_payload_blk_idx(chr_is_cr, chr_blk)] <= 1'b1;" in top,
    "top_has_chroma_payload_readiness_guard": "cabac_chroma_residual_payload_ready_w" in top and "CABAC_CHROMA_ACTIVE_BLK_MASK" in top and "cabac_luma_residual_payload_ready_w &&" in top and "cabac_chroma_residual_payload_ready_w" in top,
    "top_tracks_chroma_cbp_dc_class": "cabac_cbp_chroma_reg <= (cabac_cbp_chroma_reg == 2'd2) ? 2'd2 : 2'd1;" in top,
    "top_tracks_chroma_cbp_ac_class": "cabac_cbp_chroma_reg <= 2'd2;" in top,
    "top_feeds_chroma_cbp_to_bitstream": ".cabac_cbp_chroma(cabac_cbp_chroma_reg)" in top and "cabac_cbp_chroma_dormant_w" not in top and "cabac_cbp_chroma_reg & 2'd0" not in top,
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

THREADS="${THREADS:-1}" BUILD_JOBS="${BUILD_JOBS:-1}" \
  python3 - <<'PY'
from pathlib import Path
import os
import shutil
import subprocess
import sys

root = Path.cwd()
sys.path.insert(0, str(root / "scripts"))
from rtl_runner import BuildConfig, build_sim, run_sim, stage_workspace

out_dir = root / "output"
out_dir.mkdir(exist_ok=True)
input_path = Path("/tmp/h264_cabac_p16x16_chroma_residual_16x16_2f.yuv")
output_path = out_dir / "cabac_p16x16_chroma_residual_probe.h264"
build_log = out_dir / "cabac_p16x16_chroma_residual_probe.build.log"
sim_log = out_dir / "cabac_p16x16_chroma_residual_probe.sim.log"
ffmpeg_log = out_dir / "cabac_p16x16_chroma_residual_probe.ffmpeg.log"

# 16x16 yuv420p, two frames.  Keep luma flat while changing both chroma
# planes on frame 1 so the P MB stays in the CABAC P16x16 lane but carries
# nonzero chroma residual snapshots into the bitstream writer.
with input_path.open("wb") as f:
    for frame_idx in range(2):
        f.write(bytes([64]) * (16 * 16))
        cb = bytearray([128] * (8 * 8))
        cr = bytearray([128] * (8 * 8))
        if frame_idx == 1:
            for y in range(2, 6):
                for x in range(2, 6):
                    cb[y * 8 + x] = 160
            for y in range(1, 5):
                for x in range(3, 7):
                    cr[y * 8 + x] = 96
        f.write(cb)
        f.write(cr)

workspace = stage_workspace("h264_cabac_p16x16_chroma_residual_")
try:
    cfg = BuildConfig(
        width=16,
        height=16,
        bit_depth=8,
        chroma_format_idc=1,
        jobs=max(1, int(os.environ.get("BUILD_JOBS", os.environ.get("THREADS", "1")))),
        enable_idr_ipcm=1,
        inter_sad_threshold=20_000,
        enable_cabac_p16x16=1,
        enable_cabac_p16x16_fullpel_only=1,
    )
    sim_bin = build_sim(workspace, cfg, build_log)
    proc = run_sim(sim_bin, 2, 20_000_000, input_path, output_path, capture=True)
    sim_text = (proc.stdout or "") + (proc.stderr or "")
    sim_log.write_text(sim_text, encoding="utf-8")
    if "[TB] 2 frames encoded" not in sim_text:
        raise SystemExit("missing two-frame encode summary in chroma residual probe")
    if "cabac_p16x16_mbs=1" not in sim_text:
        raise SystemExit("chroma residual probe did not exercise a CABAC P16x16 MB")
    if "isCb=1" not in sim_text or "isCr=1" not in sim_text or "chAC=1" not in sim_text:
        raise SystemExit("chroma residual probe did not produce Cb/Cr AC residual scan evidence")

    ff = subprocess.run(
        ["ffmpeg", "-y", "-v", "error", "-xerror", "-i", str(output_path), "-f", "null", "-"],
        text=True,
        capture_output=True,
        check=False,
    )
    ffmpeg_text = (ff.stdout or "") + (ff.stderr or "")
    ffmpeg_log.write_text(ffmpeg_text, encoding="utf-8")
    if ff.returncode != 0:
        raise SystemExit(ffmpeg_text or f"ffmpeg strict decode failed with exit {ff.returncode}")
    print(f"[PASS] cabac_p16x16_chroma_residual_probe: strict FFmpeg decode ok ({output_path})")
finally:
    shutil.rmtree(workspace, ignore_errors=True)
PY
