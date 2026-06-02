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
    "bitstream_has_chroma_residual_context_banks": all(token in bitstream for token in ["cabac_chroma_dc_cbf_ctx_state_97", "cabac_chroma_ac_cbf_ctx_state_101", "cabac_chroma_dc_sig0_ctx_state_149", "cabac_chroma_ac_sig0_ctx_state_152", "cabac_chroma_dc_last0_ctx_state_210", "cabac_chroma_ac_last0_ctx_state_213", "cabac_chroma_dc_level1_ctx_state_258", "cabac_chroma_ac_level1_ctx_state_267"]),
    "bitstream_uses_chroma_residual_context_banks": "function automatic [3:0] cabac_chroma_cbf_ctx_sel" in bitstream and "function automatic [6:0] cabac_chroma_cbf_ctx_state" in bitstream and "CABAC_CTX_CHROMA_DC_CBF" in bitstream and "CABAC_CTX_CHROMA_AC_CBF" in bitstream and "cabac_chroma_sig0_ctx_state(cabac_res_chroma_payload_is_dc)" in bitstream and "CABAC_CTX_CHROMA_DC_LEVELGT1" in bitstream,
    "bitstream_initializes_chroma_residual_contexts": "cabac_chroma_dc_cbf_ctx_state_97 <= cabac_init_state(5, 54, 26);" in bitstream and "cabac_chroma_ac_cbf_ctx_state_101 <= cabac_init_state(-1, 48, 26);" in bitstream and "cabac_chroma_dc_sig0_ctx_state_149 <= cabac_init_state(3, 64, 26);" in bitstream and "cabac_chroma_ac_levelgt1_ctx_state_271 <= cabac_init_state(2, 40, 26);" in bitstream,
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
    "top_reports_chroma_residual_counters": "frame_cabac_chroma_cb_dc_mb_count" in top and "frame_cabac_chroma_cr_dc_mb_count" in top and "frame_cabac_chroma_cb_ac_block_count" in top and "[CABAC_CHROMA] Frame %0d" in top,
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
import re
import shutil
import subprocess
import sys

root = Path.cwd()
sys.path.insert(0, str(root / "scripts"))
from rtl_runner import BuildConfig, build_sim, run_sim, stage_workspace

out_dir = root / "output"
out_dir.mkdir(exist_ok=True)
ac_input_path = Path("/tmp/h264_cabac_p16x16_chroma_residual_16x16_2f.yuv")
dc_input_path = Path("/tmp/h264_cabac_p16x16_chroma_dc_residual_16x16_2f.yuv")
build_log = out_dir / "cabac_p16x16_chroma_residual_probe.build.log"

# 16x16 yuv420p, two frames.  Keep luma flat while changing both chroma
# planes on frame 1 so the P MB stays in the CABAC P16x16 lane but carries
# nonzero chroma AC residual snapshots into the bitstream writer.
with ac_input_path.open("wb") as f:
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

# Uniform chroma deltas should exercise Cb/Cr DC residual payloads while keeping
# every chroma AC block at total_coeffs=0. This guards the cbp_chroma==1 lane
# separately from the DC+AC probe above.
with dc_input_path.open("wb") as f:
    for frame_idx in range(2):
        f.write(bytes([64]) * (16 * 16))
        cb = 160 if frame_idx == 1 else 128
        cr = 96 if frame_idx == 1 else 128
        f.write(bytes([cb]) * (8 * 8))
        f.write(bytes([cr]) * (8 * 8))


def run_chroma_probe(sim_bin, name, input_path, require_dc_only):
    output_path = out_dir / f"{name}.h264"
    sim_log = out_dir / f"{name}.sim.log"
    ffmpeg_log = out_dir / f"{name}.ffmpeg.log"
    proc = run_sim(sim_bin, 2, 20_000_000, input_path, output_path, capture=True)
    sim_text = (proc.stdout or "") + (proc.stderr or "")
    sim_log.write_text(sim_text, encoding="utf-8")
    if "[TB] 2 frames encoded" not in sim_text:
        raise SystemExit(f"missing two-frame encode summary in {name}")
    if "cabac_p16x16_mbs=1" not in sim_text:
        raise SystemExit(f"{name} did not exercise a CABAC P16x16 MB")
    if "isCb=1" not in sim_text or "isCr=1" not in sim_text:
        raise SystemExit(f"{name} did not produce Cb/Cr scan evidence")
    if "chDC=1" not in sim_text:
        raise SystemExit(f"{name} did not produce chroma DC residual scan evidence")
    if require_dc_only:
        nonzero_chroma_ac = [
            line for line in sim_text.splitlines()
            if "[ZZD]" in line and "chAC=1" in line and re.search(r"TC=([1-9][0-9]*)", line)
        ]
        if nonzero_chroma_ac:
            raise SystemExit(f"{name} unexpectedly produced nonzero chroma AC residuals: {nonzero_chroma_ac[:2]}")
    elif "chAC=1" not in sim_text:
        raise SystemExit(f"{name} did not produce chroma AC residual scan evidence")

    chroma_counter_lines = [
        line for line in sim_text.splitlines()
        if line.startswith("[CABAC_CHROMA] Frame 1 ")
    ]
    if not chroma_counter_lines:
        raise SystemExit(f"{name} missing CABAC chroma counter summary")
    counter_line = chroma_counter_lines[-1]
    counters = {
        key: int(value)
        for key, value in re.findall(
            r"(cabac_chroma_mbs|cabac_chroma_dc_mbs|cabac_chroma_ac_mbs|cb_dc_mbs|cr_dc_mbs|cb_ac_mbs|cr_ac_mbs|cb_ac_blocks|cr_ac_blocks)=([0-9]+)",
            counter_line,
        )
    }
    required_keys = {
        "cabac_chroma_mbs",
        "cabac_chroma_dc_mbs",
        "cabac_chroma_ac_mbs",
        "cb_dc_mbs",
        "cr_dc_mbs",
        "cb_ac_mbs",
        "cr_ac_mbs",
        "cb_ac_blocks",
        "cr_ac_blocks",
    }
    missing_keys = sorted(required_keys - counters.keys())
    if missing_keys:
        raise SystemExit(f"{name} CABAC chroma counter line missing keys {missing_keys}: {counter_line}")
    if counters["cabac_chroma_mbs"] != 1:
        raise SystemExit(f"{name} expected one CABAC chroma MB, got: {counter_line}")
    if counters["cb_dc_mbs"] != 1 or counters["cr_dc_mbs"] != 1:
        raise SystemExit(f"{name} expected both Cb and Cr DC payloads, got: {counter_line}")
    if require_dc_only:
        if counters["cabac_chroma_dc_mbs"] != 1 or counters["cabac_chroma_ac_mbs"] != 0:
            raise SystemExit(f"{name} expected DC-only chroma CBP class, got: {counter_line}")
        if counters["cb_ac_mbs"] != 0 or counters["cr_ac_mbs"] != 0 or counters["cb_ac_blocks"] != 0 or counters["cr_ac_blocks"] != 0:
            raise SystemExit(f"{name} unexpectedly reported chroma AC payloads: {counter_line}")
    else:
        if counters["cabac_chroma_dc_mbs"] != 0 or counters["cabac_chroma_ac_mbs"] != 1:
            raise SystemExit(f"{name} expected DC+AC chroma CBP class, got: {counter_line}")
        if counters["cb_ac_mbs"] != 1 or counters["cr_ac_mbs"] != 1 or counters["cb_ac_blocks"] <= 0 or counters["cr_ac_blocks"] <= 0:
            raise SystemExit(f"{name} expected Cb and Cr AC payload counters, got: {counter_line}")

    ff = subprocess.run(
        ["ffmpeg", "-y", "-v", "error", "-xerror", "-i", str(output_path), "-f", "null", "-"],
        text=True,
        capture_output=True,
        check=False,
    )
    ffmpeg_text = (ff.stdout or "") + (ff.stderr or "")
    ffmpeg_log.write_text(ffmpeg_text, encoding="utf-8")
    if ff.returncode != 0:
        raise SystemExit(ffmpeg_text or f"ffmpeg strict decode failed for {name} with exit {ff.returncode}")
    print(f"[PASS] {name}: strict FFmpeg decode ok ({output_path})")


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
    run_chroma_probe(sim_bin, "cabac_p16x16_chroma_residual_probe", ac_input_path, require_dc_only=False)
    run_chroma_probe(sim_bin, "cabac_p16x16_chroma_dc_residual_probe", dc_input_path, require_dc_only=True)
finally:
    shutil.rmtree(workspace, ignore_errors=True)
PY
