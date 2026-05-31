#!/usr/bin/env python3
"""Audit the integrated CABAC chroma-residual bring-up wiring.

The strict chroma-residual smoke gate depends on top-level chroma DC/AC scan
capture, full 2-bit chroma CBP handoff, category-specific CABAC residual
context bases, chroma DC/AC context-state dispatch, and the residual FSM's
luma/chroma-DC/chroma-AC category scheduler in the bitstream writer.
"""

from __future__ import annotations

import argparse
import re
from pathlib import Path


CHECKS: tuple[tuple[str, str, str], ...] = (
    (
        "top_preserves_2bit_chroma_cbp",
        "rtl/h264_encoder_top.v",
        r"\.cabac_cbp_chroma\(\s*i16_cbp_chroma\s*\)",
    ),
    (
        "top_exports_chroma_dc_scan",
        "rtl/h264_encoder_top.v",
        r"cabac_chroma_dc_scan_flat_w\s*=\s*\{\s*cabac_chroma_dc_scan_buf\[1\],\s*cabac_chroma_dc_scan_buf\[0\]",
    ),
    (
        "top_exports_chroma_ac_scan",
        "rtl/h264_encoder_top.v",
        r"cabac_chroma_ac_scan_flat_w\s*=\s*\{\s*cabac_chroma_ac_scan_buf\[31\].*cabac_chroma_ac_scan_buf\[0\]",
    ),
    (
        "top_allows_chroma_residual_subset",
        "rtl/h264_encoder_top.v",
        r"cabac_residual_p16x16_eligible_w\s*=\s*mb_has_residual\s*&&\s*\(\(mb_cbp_luma_w\s*!=\s*4'd0\)\s*\|\|\s*\(i16_cbp_chroma\s*!=\s*2'd0\)\)",
    ),
    (
        "top_preserves_chroma_dc_only_cbp",
        "rtl/h264_encoder_top.v",
        r"i16_chroma_ac_nonzero\s*\|\|\s*\(total_coeffs\s*!=\s*5'd0\).*?i16_cbp_chroma\s*<=\s*2'd2.*?else if \(i16_chroma_dc_nonzero\).*?i16_cbp_chroma\s*<=\s*2'd1",
    ),
    (
        "bitstream_emits_nonzero_chroma_cbp_first_bin",
        "rtl/h264_bitstream.v",
        r"cabac_bin_value\s*<=\s*\(\s*cabac_cbp_chroma\s*!=\s*2'd0\s*\)",
    ),
    (
        "bitstream_emits_chroma_cbp_ac_bin",
        "rtl/h264_bitstream.v",
        r"cabac_cbp_chroma\s*!=\s*2'd0.*?cabac_cbp_chroma_ctx_state\[1\].*?cabac_pending_ctx_sel\s*<=\s*4'd1.*?cabac_bin_value\s*<=\s*\(\s*cabac_cbp_chroma\s*==\s*2'd2\s*\)",
    ),
    (
        "bitstream_preserves_chroma_cbp_ctx1_state",
        "rtl/h264_bitstream.v",
        r"CABAC_CTX_CBPCHROMA:\s*cabac_cbp_chroma_ctx_state\[cabac_pending_ctx_sel\[2:0\]\]\s*<=\s*cabac_ctx_state_out.*?cabac_cbp_chroma_ctx_state\[1\]\s*<=\s*cabac_init_state\(-20,\s*94,\s*26\)",
    ),
    (
        "bitstream_has_chroma_dc_category",
        "rtl/h264_bitstream.v",
        r"CABAC_RES_CAT_CHROMA_DC\s*=\s*2'd1",
    ),
    (
        "bitstream_has_chroma_ac_category",
        "rtl/h264_bitstream.v",
        r"CABAC_RES_CAT_CHROMA_AC\s*=\s*2'd2",
    ),
    (
        "bitstream_selects_chroma_dc_scan",
        "rtl/h264_bitstream.v",
        r"CABAC_RES_CAT_CHROMA_DC:\s*cabac_res_coeff_at\s*=\s*cabac_chroma_dc_coeff_at",
    ),
    (
        "bitstream_selects_chroma_ac_scan",
        "rtl/h264_bitstream.v",
        r"CABAC_RES_CAT_CHROMA_AC:\s*cabac_res_coeff_at\s*=\s*cabac_chroma_ac_coeff_at",
    ),
    (
        "bitstream_chroma_dc_context_bases",
        "rtl/h264_bitstream.v",
        r"CABAC_RES_CAT_CHROMA_DC:\s*cabac_res_ctx_cbf_base_for\s*=\s*9'd97.*CABAC_RES_CAT_CHROMA_DC:\s*cabac_res_ctx_sig_base_for\s*=\s*9'd149.*CABAC_RES_CAT_CHROMA_DC:\s*cabac_res_ctx_last_base_for\s*=\s*9'd210.*CABAC_RES_CAT_CHROMA_DC:\s*cabac_res_ctx_level_gt1_for\s*=\s*9'd257.*CABAC_RES_CAT_CHROMA_DC:\s*cabac_res_ctx_level_gt2_for\s*=\s*9'd262",
    ),
    (
        "bitstream_chroma_ac_context_bases",
        "rtl/h264_bitstream.v",
        r"CABAC_RES_CAT_CHROMA_AC:\s*cabac_res_ctx_cbf_base_for\s*=\s*9'd101.*CABAC_RES_CAT_CHROMA_AC:\s*cabac_res_ctx_sig_base_for\s*=\s*9'd152.*CABAC_RES_CAT_CHROMA_AC:\s*cabac_res_ctx_last_base_for\s*=\s*9'd213.*CABAC_RES_CAT_CHROMA_AC:\s*cabac_res_ctx_level_gt1_for\s*=\s*9'd266.*CABAC_RES_CAT_CHROMA_AC:\s*cabac_res_ctx_level_gt2_for\s*=\s*9'd277",
    ),
    (
        "residual_bins_cbf_context_increment_input",
        "rtl/h264_cabac_residual4x4_bins.v",
        r"input\s+wire\s+\[1:0\]\s+ctx_cbf_sel.*?emit_bin\(event_value,\s*1'b0,\s*ctx_cbf_base\s*\+\s*\{7'd0,\s*ctx_cbf_sel\}\)",
    ),
    (
        "bitstream_uses_plane_local_chroma_ac_cbf_context",
        "rtl/h264_bitstream.v",
        r"function automatic \[1:0\] cabac_res_chroma_ac_cbf_ctx_sel_for.*?plane-local.*?CABAC_CHROMA_AC_BLOCKS_PER_PLANE.*?left_coded_i = plane_block_i\[0\].*?top_coded_i = \(plane_block_i >= 3'd2\).*?cabac_res_chroma_ac_cbf_ctx_sel_for = \{top_coded_i, left_coded_i\}.*?cabac_res_chroma_ac_cr_cbf_ctx_state.*?9'd101:\s*begin\s*if \(cabac_res_block_idx >= CABAC_CHROMA_AC_BLOCKS_PER_PLANE\).*?cabac_res_chroma_ac_cr_cbf_ctx_state\[cabac_res_chroma_ac_cbf_ctx_sel_for\(cabac_res_block_idx\)\].*?else\s*cabac_ctx_state_in\s*<=\s*cabac_res_chroma_ac_cbf_ctx_state\[cabac_res_chroma_ac_cbf_ctx_sel_for\(cabac_res_block_idx\)\].*?cabac_pending_ctx_sel\s*<=\s*\{1'b0,\s*\(cabac_res_block_idx >= CABAC_CHROMA_AC_BLOCKS_PER_PLANE\),\s*cabac_res_chroma_ac_cbf_ctx_sel_for\(cabac_res_block_idx\)\}",
    ),
    (
        "bitstream_dispatches_plane_specific_chroma_ac_cbf_contexts",
        "rtl/h264_bitstream.v",
        r"if \(\(cabac_res_bin_ctx_idx >= 9'd101\) && \(cabac_res_bin_ctx_idx <= 9'd104\)\) begin\s*if \(cabac_res_block_idx >= CABAC_CHROMA_AC_BLOCKS_PER_PLANE\)\s*cabac_ctx_state_in\s*<=\s*cabac_res_chroma_ac_cr_cbf_ctx_state\[cabac_res_bin_ctx_idx\[1:0\] - 2'd1\];\s*else\s*cabac_ctx_state_in\s*<=\s*cabac_res_chroma_ac_cbf_ctx_state\[cabac_res_bin_ctx_idx\[1:0\] - 2'd1\];\s*cabac_pending_ctx_kind\s*<=\s*CABAC_CTX_RES_CHRAC_CBF;\s*cabac_pending_ctx_sel\s*<=\s*\{1'b0,\s*\(cabac_res_block_idx >= CABAC_CHROMA_AC_BLOCKS_PER_PLANE\),\s*\(cabac_res_bin_ctx_idx\[1:0\] - 2'd1\)\}",
    ),
    (
        "bitstream_handles_sparse_cb_chroma_ac_cbf_walk",
        "rtl/h264_bitstream.v",
        r"cabac_chroma_ac_cb_plane_any_nz.*?cabac_chroma_ac_cb_plane_full_nz.*?cabac_chroma_ac_cr_plane_any_nz.*?cabac_chroma_ac_cr_plane_full_nz.*?cabac_chroma_ac_cb_plane_any_nz\(\) &&\s*!cabac_chroma_ac_cb_plane_full_nz\(\) &&\s*!cabac_chroma_ac_cr_plane_any_nz\(\).*?bottom-row sparse Cb.*?3'd2: begin left_coded_i = 1'b1; top_coded_i = 1'b1; end.*?default: begin left_coded_i = 1'b0; top_coded_i = 1'b0; end.*?cabac_chroma_ac_cr_plane_full_nz\(\).*?cabac_res_chroma_ac_cbf_ctx_sel_for = \{top_coded_i, left_coded_i\}",
    ),
    (
        "bitstream_initializes_chroma_residual_contexts",
        "rtl/h264_bitstream.v",
        r"cabac_res_chroma_dc_cbf_ctx_state\[0\]\s*<=\s*cabac_init_state\(5,\s*54,\s*26\).*?cabac_res_chroma_dc_sig_ctx_state\[0\]\s*<=\s*cabac_init_state\(3,\s*64,\s*26\).*?cabac_res_chroma_dc_last_ctx_state\[0\]\s*<=\s*cabac_init_state\(1,\s*67,\s*26\).*?cabac_res_chroma_dc_level_ctx_state_0\s*<=\s*cabac_init_state\(0,\s*70,\s*26\).*?cabac_res_chroma_ac_cbf_ctx_state\[0\]\s*<=\s*cabac_init_state\(-1,\s*48,\s*26\).*?cabac_res_chroma_ac_cr_cbf_ctx_state\[0\]\s*<=\s*cabac_init_state\(-1,\s*48,\s*26\).*?cabac_res_chroma_ac_sig_ctx_state\[0\]\s*<=\s*cabac_init_state\(7,\s*50,\s*26\).*?cabac_res_chroma_ac_last_ctx_state\[0\]\s*<=\s*cabac_init_state\(16,\s*30,\s*26\).*?cabac_res_chroma_ac_level_ctx_state_0\s*<=\s*cabac_init_state\(0,\s*58,\s*26\)",
    ),
    (
        "bitstream_dispatches_chroma_dc_context_state",
        "rtl/h264_bitstream.v",
        r"cabac_res_category\s*==\s*CABAC_RES_CAT_CHROMA_DC(?=.*?CABAC_CTX_RES_CHRDC_CBF)(?=.*?CABAC_CTX_RES_CHRDC_SIG)(?=.*?CABAC_CTX_RES_CHRDC_LAST)(?=.*?CABAC_CTX_RES_CHRDC_LEVEL).*?end else if \(cabac_res_category\s*==\s*CABAC_RES_CAT_CHROMA_AC",
    ),
    (
        "bitstream_dispatches_chroma_ac_context_state",
        "rtl/h264_bitstream.v",
        r"cabac_res_category\s*==\s*CABAC_RES_CAT_CHROMA_AC(?=.*?CABAC_CTX_RES_CHRAC_CBF)(?=.*?CABAC_CTX_RES_CHRAC_SIG)(?=.*?CABAC_CTX_RES_CHRAC_LAST)(?=.*?CABAC_CTX_RES_CHRAC_LEVEL).*?end else begin",
    ),
    (
        "bitstream_bounds_chroma_residual_categories",
        "rtl/h264_bitstream.v",
        r"function automatic \[3:0\] cabac_res_last_block_for.*?CABAC_RES_CAT_CHROMA_DC:\s*cabac_res_last_block_for\s*=\s*4'd1.*?CABAC_RES_CAT_CHROMA_AC:\s*cabac_res_last_block_for\s*=\s*CABAC_CHROMA_AC_TOTAL_MINUS1.*?default:\s*cabac_res_last_block_for\s*=\s*4'd15",
    ),
    (
        "bitstream_schedules_chroma_dc_after_luma",
        "rtl/h264_bitstream.v",
        r"cabac_res_block_idx\s*==\s*cabac_res_last_block_for\(cabac_res_category\).*?cabac_res_category\s*==\s*CABAC_RES_CAT_LUMA.*?cabac_cbp_chroma\s*!=\s*2'd0.*?cabac_res_category\s*<=\s*CABAC_RES_CAT_CHROMA_DC",
    ),
    (
        "bitstream_starts_chroma_dc_when_luma_cbp_zero",
        "rtl/h264_bitstream.v",
        r"cabac_res_category\s*<=\s*\(cabac_cbp_luma\s*!=\s*4'd0\)\s*\?\s*CABAC_RES_CAT_LUMA\s*:\s*CABAC_RES_CAT_CHROMA_DC",
    ),
    (
        "bitstream_schedules_chroma_ac_after_dc",
        "rtl/h264_bitstream.v",
        r"cabac_res_category\s*==\s*CABAC_RES_CAT_CHROMA_DC.*?cabac_cbp_chroma\s*==\s*2'd2.*?cabac_res_category\s*<=\s*CABAC_RES_CAT_CHROMA_AC",
    ),
    (
        "gate_generates_cr_ac_strict_fixture",
        "scripts/run_cabac_p16x16_chroma_residual_red_check.sh",
        r"INPUT_CR_AC=.*?smoke_16x16_2f_cabac_p16x16_chroma_residual_cr_ac\.yuv.*?'cr_ac':.*?run_case \"cr_ac\" \"\$INPUT_CR_AC\" 2",
    ),
    (
        "gate_checks_cb_vs_cr_ac_plane_counters",
        "scripts/run_cabac_p16x16_chroma_residual_red_check.sh",
        r"cb_ac_mbs=1\s+cr_ac_mbs=0.*?cb_ac_mbs=0\s+cr_ac_mbs=1",
    ),
    (
        "gate_checks_decoded_chroma_plane_sanity",
        "scripts/run_cabac_p16x16_chroma_residual_red_check.sh",
        r"decoded plane sanity expected Cb-only change.*?decoded plane sanity expected Cr-only change.*?\[PASS\] chroma residual \{name\} decoded-plane sanity U_SAD=\{u_sad\} V_SAD=\{v_sad\}",
    ),
    (
        "gate_promotes_cr_ac_strict_decode",
        "scripts/run_cabac_p16x16_chroma_residual_red_check.sh",
        r"run_case \"cr_ac\" \"\$INPUT_CR_AC\" 2\s+echo \"\[PASS\] CABAC P16x16 Cb/Cr DC-only and DC\+AC chroma residual smoke streams strict-decoded\"",
    ),
    (
        "probe_promotes_both_plane_ac_strict_pass",
        "scripts/run_cabac_p16x16_chroma_cr_ac_probe.sh",
        r"run_strict_pass both_planes 'cabac_chroma_cb_ac_mbs=1\s+cabac_chroma_cr_ac_mbs=1' 'cabac_chroma_cb_ac_blocks=4\s+cabac_chroma_cr_ac_blocks=4'",
    ),
    (
        "probe_promotes_bottom_row_cb_mirror_sparse_passes",
        "scripts/run_cabac_p16x16_chroma_cr_ac_probe.sh",
        r"cb_mirror_single_tl.*?cb_mirror_single_br.*?run_expected_miss cb_mirror_single_tl 'bytestream -19' 'cabac_chroma_cb_ac_mbs=1\s+cabac_chroma_cr_ac_mbs=0' 'cabac_chroma_cb_ac_blocks=1\s+cabac_chroma_cr_ac_blocks=0'.*?run_expected_miss cb_mirror_single_tr 'bytestream -21' 'cabac_chroma_cb_ac_mbs=1\s+cabac_chroma_cr_ac_mbs=0' 'cabac_chroma_cb_ac_blocks=1\s+cabac_chroma_cr_ac_blocks=0'.*?run_strict_pass cb_mirror_single_bl 'cabac_chroma_cb_ac_mbs=1\s+cabac_chroma_cr_ac_mbs=0' 'cabac_chroma_cb_ac_blocks=1\s+cabac_chroma_cr_ac_blocks=0'.*?run_strict_pass cb_mirror_single_br 'cabac_chroma_cb_ac_mbs=1\s+cabac_chroma_cr_ac_mbs=0' 'cabac_chroma_cb_ac_blocks=1\s+cabac_chroma_cr_ac_blocks=0'",
    ),
    (
        "probe_promotes_right_quadrant_sparse_passes",
        "scripts/run_cabac_p16x16_chroma_cr_ac_probe.sh",
        r"single_tl.*?single_tr.*?single_bl.*?cb_mirror_single_tr.*?cb_mirror_single_bl.*?run_strict_pass single_tl 'cabac_chroma_cb_ac_mbs=0\s+cabac_chroma_cr_ac_mbs=1' 'cabac_chroma_cb_ac_blocks=0\s+cabac_chroma_cr_ac_blocks=1'.*?run_strict_pass single_tr 'cabac_chroma_cb_ac_mbs=0\s+cabac_chroma_cr_ac_mbs=1' 'cabac_chroma_cb_ac_blocks=0\s+cabac_chroma_cr_ac_blocks=1'.*?run_strict_pass single_bl 'cabac_chroma_cb_ac_mbs=0\s+cabac_chroma_cr_ac_mbs=1' 'cabac_chroma_cb_ac_blocks=0\s+cabac_chroma_cr_ac_blocks=1'.*?run_strict_pass single_br 'cabac_chroma_cb_ac_mbs=0\s+cabac_chroma_cr_ac_mbs=1' 'cabac_chroma_cb_ac_blocks=0\s+cabac_chroma_cr_ac_blocks=1'.*?run_expected_miss cb_mirror_single_tl 'bytestream -19'.*?run_expected_miss cb_mirror_single_tr 'bytestream -21'.*?run_strict_pass cb_mirror_single_bl 'cabac_chroma_cb_ac_mbs=1\s+cabac_chroma_cr_ac_mbs=0'.*?run_strict_pass cb_mirror_single_br 'cabac_chroma_cb_ac_mbs=1\s+cabac_chroma_cr_ac_mbs=0' 'cabac_chroma_cb_ac_blocks=1\s+cabac_chroma_cr_ac_blocks=0'",
    ),
    (
        "probe_promotes_dense_cb_cr_ac_pass_controls",
        "scripts/run_cabac_p16x16_chroma_cr_ac_probe.sh",
        r"cb_checker.*?checker.*?run_strict_pass cb_checker 'cabac_chroma_cb_ac_mbs=1\s+cabac_chroma_cr_ac_mbs=0' 'cabac_chroma_cb_ac_blocks=4\s+cabac_chroma_cr_ac_blocks=0'.*?run_strict_pass checker 'cabac_chroma_cb_ac_mbs=0\s+cabac_chroma_cr_ac_mbs=1' 'cabac_chroma_cb_ac_blocks=0\s+cabac_chroma_cr_ac_blocks=4'",
    ),
    (
        "probe_checks_dense_cb_ac_decoded_plane_sanity",
        "scripts/run_cabac_p16x16_chroma_cr_ac_probe.sh",
        r"strict-pass decoded plane sanity expected Cb-only change.*?strict-pass decoded plane sanity expected Cr-only change.*?strict-pass decoded-plane sanity U_SAD=\{u_sad\} V_SAD=\{v_sad\}",
    ),
    (
        "probe_locks_chroma_ac_block_counters",
        "scripts/run_cabac_p16x16_chroma_cr_ac_probe.sh",
        r"expected_blocks=.*?cabac_chroma_cb_ac_blocks=0\s+cabac_chroma_cr_ac_blocks=4.*?run_strict_pass single_tl 'cabac_chroma_cb_ac_mbs=0\s+cabac_chroma_cr_ac_mbs=1' 'cabac_chroma_cb_ac_blocks=0\s+cabac_chroma_cr_ac_blocks=1'.*?run_strict_pass both_planes 'cabac_chroma_cb_ac_mbs=1\s+cabac_chroma_cr_ac_mbs=1' 'cabac_chroma_cb_ac_blocks=4\s+cabac_chroma_cr_ac_blocks=4'",
    ),
    (
        "top_reports_chroma_ac_block_counters",
        "rtl/h264_encoder_top.v",
        r"frame_cabac_chroma_cb_ac_block_count.*?frame_cabac_chroma_cr_ac_block_count.*?cabac_chroma_cb_ac_blocks=%0d\s+cabac_chroma_cr_ac_blocks=%0d",
    ),
    (
        "probe_locks_cr_ac_mask_lattice",
        "scripts/run_cabac_p16x16_chroma_cr_ac_mask_probe.py",
        r"STRICT_MASKS\s*=\s*\{\s*0x1,\s*0x2,\s*0x4,\s*0x6,\s*0x8,\s*0x9,\s*0xF,\s*\}.*?MISS_SIGNATURES\s*=\s*\{.*?0x3:\s*\"bytestream -6\".*?0x5:\s*\"bytestream -16\".*?0x7:\s*\"bytestream -37\".*?0xA:\s*\"bytestream -12\".*?0xB:\s*\"bytestream -17\".*?0xC:\s*\"bytestream -16\".*?0xD:\s*\"bytestream -17\".*?0xE:\s*\"bytestream -7\".*?expected_blocks\s*=\s*mask\.bit_count\(\).*?cr_ac_blocks=\{expected_blocks\}.*?expected_v\s*=\s*expected_blocks \* 64",
    ),
    (
        "probe_locks_cr_ac_first_payload_substitutions",
        "scripts/run_cabac_p16x16_chroma_cr_ac_first_payload_substitution_probe.py",
        r"EXPECTED_FIRST_PAYLOAD\s*=\s*0xEB.*?QUEUE_M8_FIRST_PAYLOAD\s*=\s*0x75.*?BIT7_PROMOTED_PAYLOAD\s*=\s*0x6B.*?STRICT_MASKS\s*=\s*\{0x1,\s*0x2,\s*0x4,\s*0x6,\s*0x8,\s*0x9,\s*0xF\}.*?MISS_SIGNATURES\s*=\s*\{.*?0x3:\s*\"bytestream -6\".*?0xE:\s*\"bytestream -7\".*?for label, value in \(\(\"queue_m8_payload_0x75\", QUEUE_M8_FIRST_PAYLOAD\), \(\"bit7_payload_0x6b\", BIT7_PROMOTED_PAYLOAD\)\).*?assert_cr_only\(mask, fixture, raw, label\).*?check_both_plane_guard",
    ),
    (
        "probe_locks_cb_ac_shape_tail_partition",
        "scripts/run_cabac_p16x16_chroma_cb_ac_shape_probe.sh",
        r"d0 08 08 6b header tail and first residual payload byte eb.*?\(0, \"checker_odd\", False, \"bytestream -19\", \"0000000141d008086beb2ed226\"\).*?\(0, \"vert_left\", True, \"\", \"0000000141d008086beb2f\"\).*?\(1, \"horiz_top\", True, \"\", \"0000000141d008086beb2f\"\).*?\(2, \"checker_even\", False, \"bytestream -5\", \"0000000141d008086beb2fa1d4\"\).*?\(3, \"vert_left\", False, \"bytestream -6\", \"0000000141d008086beb2fc7\"\).*?final_slice\.startswith\(\"0000000141d008086beb\"\).*?repair target is residual coefficient emission/order/arithmetic tail",
    ),
)


def repo_root() -> Path:
    return Path(__file__).resolve().parents[1]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-root", type=Path, default=repo_root())
    args = parser.parse_args()

    root = args.repo_root.resolve()
    failures: list[str] = []
    for name, rel_path, pattern in CHECKS:
        path = root / rel_path
        text = path.read_text(encoding="utf-8")
        if not re.search(pattern, text, flags=re.S):
            failures.append(f"{name}: missing {rel_path} / {pattern}")
        else:
            print(f"[PASS] {name}")

    if failures:
        print("[FAIL] CABAC chroma residual scaffold audit failed:")
        for failure in failures:
            print(f"  - {failure}")
        return 1

    print("[PASS] CABAC chroma residual wiring preserves CBP, scan, context bases, edge-coded plane-local chroma AC CBF context selection, state-dispatch, category scheduling, decoded-plane sanity coverage, dense Cr strict-pass promotion, Cr sparse strict-pass promotion, dense Cb and both-plane AC strict-pass controls plus decoded-plane sanity, chroma AC per-plane block counters, Cr AC mask-lattice signatures, Cr AC first-payload substitution coverage, and Cb AC shape/tail partition coverage")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
