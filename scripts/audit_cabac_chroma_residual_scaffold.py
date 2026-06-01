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
        r"INPUT_CR_AC=.*?smoke_16x16_2f_cabac_p16x16_chroma_residual_cr_ac\.yuv.*?'cr_ac':.*?run_case \"cr_ac\" \"\$INPUT_CR_AC\" 2 0 1 0 4",
    ),
    (
        "gate_checks_cb_vs_cr_ac_plane_counters",
        "scripts/run_cabac_p16x16_chroma_residual_red_check.sh",
        r"cb_ac_mbs=1\s+cr_ac_mbs=0.*?cb_ac_mbs=0\s+cr_ac_mbs=1",
    ),
    (
        "gate_checks_chroma_dc_ac_block_plane_counters",
        "scripts/run_cabac_p16x16_chroma_residual_red_check.sh",
        r"expected_cb_dc_mbs=.*?expected_cr_dc_mbs=.*?expected_cb_ac_blocks=.*?expected_cr_ac_blocks=.*?cb_dc_mbs=\$\{expected_cb_dc_mbs\}\s+cr_dc_mbs=\$\{expected_cr_dc_mbs\}.*?cb_ac_blocks=\$\{expected_cb_ac_blocks\}\s+cr_ac_blocks=\$\{expected_cr_ac_blocks\}.*?run_case \"cb_dc\" \"\$INPUT_CB_DC\" 1 1 0 0 0.*?run_case \"cb_ac\" \"\$INPUT_CB_AC\" 2 1 0 4 0.*?run_case \"cr_dc\" \"\$INPUT_CR_DC\" 1 0 1 0 0.*?run_case \"cr_ac\" \"\$INPUT_CR_AC\" 2 0 1 0 4.*?run_case \"both_dc\" \"\$INPUT_BOTH_DC\" 1 1 1 0 0",
    ),
    (
        "gate_checks_decoded_chroma_plane_sanity",
        "scripts/run_cabac_p16x16_chroma_residual_red_check.sh",
        r"expected_u_sad.*?expected_v_sad.*?decoded-plane SAD drift.*?decoded plane sanity expected Cb-only change.*?decoded plane sanity expected Cr-only change.*?\[PASS\] chroma residual \{name\} decoded-plane sanity U_SAD=\{u_sad\} V_SAD=\{v_sad\}.*?run_case \"cb_dc\" \"\$INPUT_CB_DC\" 1 1 0 0 0 512 0.*?run_case \"cb_ac\" \"\$INPUT_CB_AC\" 2 1 0 4 0 256 0.*?run_case \"cr_dc\" \"\$INPUT_CR_DC\" 1 0 1 0 0 0 512.*?run_case \"cr_ac\" \"\$INPUT_CR_AC\" 2 0 1 0 4 0 256.*?run_case \"both_dc\" \"\$INPUT_BOTH_DC\" 1 1 1 0 0 512 512",
    ),
    (
        "gate_promotes_cr_ac_and_both_plane_strict_decode",
        "scripts/run_cabac_p16x16_chroma_residual_red_check.sh",
        r"INPUT_BOTH_DC=.*?smoke_16x16_2f_cabac_p16x16_chroma_residual_both_dc\.yuv.*?INPUT_BOTH_AC=.*?smoke_16x16_2f_cabac_p16x16_chroma_residual_both_ac\.yuv.*?'both_dc':.*?'both_ac':.*?run_case \"cr_ac\" \"\$INPUT_CR_AC\" 2 0 1 0 4 0 256\s+run_case \"both_dc\" \"\$INPUT_BOTH_DC\" 1 1 1 0 0 512 512\s+run_case \"both_ac\" \"\$INPUT_BOTH_AC\" 2 1 1 4 4 256 256\s+echo \"\[PASS\] CABAC P16x16 Cb/Cr DC-only, both-plane DC-only, single-plane AC, and both-plane AC chroma residual smoke streams strict-decoded\"",
    ),
    (
        "probe_promotes_both_plane_ac_strict_pass",
        "scripts/run_cabac_p16x16_chroma_cr_ac_probe.sh",
        r"run_strict_pass both_planes 'cabac_chroma_cb_ac_mbs=1\s+cabac_chroma_cr_ac_mbs=1' 'cabac_chroma_cb_ac_blocks=4\s+cabac_chroma_cr_ac_blocks=4'",
    ),
    (
        "probe_promotes_all_cb_mirror_sparse_passes",
        "scripts/run_cabac_p16x16_chroma_cr_ac_probe.sh",
        r"cb_mirror_single_tl.*?cb_mirror_single_br.*?run_strict_pass cb_mirror_single_tl 'cabac_chroma_cb_ac_mbs=1\s+cabac_chroma_cr_ac_mbs=0' 'cabac_chroma_cb_ac_blocks=1\s+cabac_chroma_cr_ac_blocks=0'.*?run_strict_pass cb_mirror_single_tr 'cabac_chroma_cb_ac_mbs=1\s+cabac_chroma_cr_ac_mbs=0' 'cabac_chroma_cb_ac_blocks=1\s+cabac_chroma_cr_ac_blocks=0'.*?run_strict_pass cb_mirror_single_bl 'cabac_chroma_cb_ac_mbs=1\s+cabac_chroma_cr_ac_mbs=0' 'cabac_chroma_cb_ac_blocks=1\s+cabac_chroma_cr_ac_blocks=0'.*?run_strict_pass cb_mirror_single_br 'cabac_chroma_cb_ac_mbs=1\s+cabac_chroma_cr_ac_mbs=0' 'cabac_chroma_cb_ac_blocks=1\s+cabac_chroma_cr_ac_blocks=0'",
    ),
    (
        "probe_promotes_right_quadrant_sparse_passes",
        "scripts/run_cabac_p16x16_chroma_cr_ac_probe.sh",
        r"single_tl.*?single_tr.*?single_bl.*?cb_mirror_single_tr.*?cb_mirror_single_bl.*?run_strict_pass single_tl 'cabac_chroma_cb_ac_mbs=0\s+cabac_chroma_cr_ac_mbs=1' 'cabac_chroma_cb_ac_blocks=0\s+cabac_chroma_cr_ac_blocks=1'.*?run_strict_pass single_tr 'cabac_chroma_cb_ac_mbs=0\s+cabac_chroma_cr_ac_mbs=1' 'cabac_chroma_cb_ac_blocks=0\s+cabac_chroma_cr_ac_blocks=1'.*?run_strict_pass single_bl 'cabac_chroma_cb_ac_mbs=0\s+cabac_chroma_cr_ac_mbs=1' 'cabac_chroma_cb_ac_blocks=0\s+cabac_chroma_cr_ac_blocks=1'.*?run_strict_pass single_br 'cabac_chroma_cb_ac_mbs=0\s+cabac_chroma_cr_ac_mbs=1' 'cabac_chroma_cb_ac_blocks=0\s+cabac_chroma_cr_ac_blocks=1'.*?run_strict_pass cb_mirror_single_tl 'cabac_chroma_cb_ac_mbs=1\s+cabac_chroma_cr_ac_mbs=0'.*?run_strict_pass cb_mirror_single_tr 'cabac_chroma_cb_ac_mbs=1\s+cabac_chroma_cr_ac_mbs=0'.*?run_strict_pass cb_mirror_single_bl 'cabac_chroma_cb_ac_mbs=1\s+cabac_chroma_cr_ac_mbs=0'.*?run_strict_pass cb_mirror_single_br 'cabac_chroma_cb_ac_mbs=1\s+cabac_chroma_cr_ac_mbs=0' 'cabac_chroma_cb_ac_blocks=1\s+cabac_chroma_cr_ac_blocks=0'",
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
        "top_reports_chroma_dc_plane_counters",
        "rtl/h264_encoder_top.v",
        r"frame_cabac_chroma_cb_dc_mb_count.*?frame_cabac_chroma_cr_dc_mb_count.*?cabac_chroma_cb_dc_mbs=%0d\s+cabac_chroma_cr_dc_mbs=%0d.*?cb_dc_mbs=%0d\s+cr_dc_mbs=%0d",
    ),
    (
        "top_reports_chroma_ac_block_counters",
        "rtl/h264_encoder_top.v",
        r"frame_cabac_chroma_cb_ac_block_count.*?frame_cabac_chroma_cr_ac_block_count.*?cabac_chroma_cb_ac_blocks=%0d\s+cabac_chroma_cr_ac_blocks=%0d",
    ),
    (
        "probe_locks_cr_ac_mask_lattice",
        "scripts/run_cabac_p16x16_chroma_cr_ac_mask_probe.py",
        r"STRICT_MASKS\s*=\s*set\(range\(1,\s*16\)\).*?expected_blocks\s*=\s*mask\.bit_count\(\).*?cr_ac_blocks=\{expected_blocks\}.*?expected_v\s*=\s*expected_blocks \* 64.*?CABAC P16x16 Cr-only chroma-AC mask lattice promoted: all 15 nonzero",
    ),
    (
        "probe_promotes_cross_plane_ac_gate",
        "scripts/run_cabac_p16x16_chroma_ac_cross_plane_first_payload_probe.py",
        r"cod_i_queue=-7.*?EXPECTED_HEADER_TAIL\s*=\s*0x6B.*?TAILS\s*=\s*\{.*?\(0x1,\s*0x1\):\s*\"0000000141d008086b3acbb8b517a9\".*?\(0x2,\s*0x4\):\s*\"0000000141d008086b3acbeb2d408a\".*?\(0x4,\s*0x2\):\s*\"0000000141d008086b3acbdfe134f0\".*?\(0x6,\s*0x9\):\s*\"0000000141d008086b3acc6941a435899e104b1c8a00\".*?\(0x9,\s*0x6\):\s*\"0000000141d008086b3acc68c9ae34745f6b095dfa00\".*?\(0x7,\s*0xB\):\s*\"0000000141d008086b3acc36849d0ec2488aacde0d00000300\".*?\(0xB,\s*0x7\):\s*\"0000000141d008086b3acc36849d0ec24af9158f060000\".*?\(0x2,\s*0xF\):\s*\"0000000141d008086b3acbf4ded3f999944575ae9b\".*?\(0x4,\s*0xF\):\s*\"0000000141d008086b3acbf452ba2e8e9222bad74d\".*?\(0x8,\s*0xF\):\s*\"0000000141d008086b3acbf3e7134c83288aeb5d37\".*?\(0x4,\s*0x8\):\s*\"0000000141d008086b3acbdfe134e5\".*?\(0x8,\s*0x4\):\s*\"0000000141d008086b3acbe70e2692\".*?\(0xF,\s*0x2\):\s*\"0000000141d008086b3acc332499ec2488aa9fedd7\".*?\(0xF,\s*0x4\):\s*\"0000000141d008086b3acc332499ec2488aa9fedc0\".*?\(0xF,\s*0x8\):\s*\"0000000141d008086b3acc332499ec2488aa9fedce\".*?\(0xF,\s*0xF\):\s*\"0000000141d008086b7acc\".*?\(0xE,\s*0x1\):\s*\"0000000141d008086b3acc3602d3f58ca1b3b4\".*?\(0xD,\s*0xE\):\s*\"0000000141d008086b3acc36849d158a9214bf7b590000\".*?\(0xE,\s*0xD\):\s*\"0000000141d008086b3acc36b8ad3f58ca1b3b4eb300000300\".*?AMPLITUDE_TAILS\s*=\s*\{.*?\(0x5,\s*0xA,\s*160,\s*136\):\s*\"0000000141d008086b\".*?\(0x5,\s*0xA,\s*136,\s*160\):\s*\"0000000141d008086b\".*?\(0x5,\s*0xA,\s*160,\s*160\):\s*\"0000000141d008086b7fff\".*?\(0x6,\s*0x9,\s*96,\s*160\):\s*\"0000000141d008086b7ffeef\".*?\(0x9,\s*0x6,\s*160,\s*96\):\s*\"0000000141d008086b7ade\".*?\(0xC,\s*0x3,\s*96,\s*160\):\s*\"0000000141d008086bbaff\".*?\(0x2,\s*0xF,\s*160,\s*96\):\s*\"0000000141d008086b3aff7dbfbe\".*?expected_u\s*=\s*cb_mask\.bit_count\(\) \* 8 \* abs\(cb_value - 128\).*?expected_v\s*=\s*cr_mask\.bit_count\(\) \* 8 \* abs\(cr_value - 128\).*?CABAC P16x16 cross-plane chroma-AC gate promoted.*?bottom-row cross-corner.*?reciprocal diagonal singleton.*?sparse\+dense right-column/bottom-row.*?all-but-one reciprocal complements.*?mixed-sign.*?high-amplitude Cb/Cr guards strict-decode",
    ),
    (
        "probe_locks_cross_plane_complementary_checker_guards",
        "scripts/run_cabac_p16x16_chroma_ac_cross_plane_first_payload_probe.py",
        r"TAILS\s*=\s*\{.*?\(0x5,\s*0xA\):\s*\"0000000141d008086b3acc6f8c66df5158a92c722b\".*?\(0xA,\s*0x5\):\s*\"0000000141d008086b3acc707c4426d40d584ac22b\".*?complementary checker",
    ),
    (
        "probe_locks_cross_plane_high_amp_split_guards",
        "scripts/run_cabac_p16x16_chroma_ac_cross_plane_first_payload_probe.py",
        r"AMPLITUDE_TAILS\s*=\s*\{.*?\(0x6,\s*0x9,\s*160,\s*160\):\s*\"0000000141d008086b7ffeef\".*?\(0xC,\s*0x3,\s*160,\s*160\):\s*\"0000000141d008086bbaff\".*?\(0x3,\s*0xC,\s*160,\s*160\):\s*\"0000000141d008086b7ecd\"",
    ),
    (
        "probe_locks_cross_plane_mixed_sign_complement_guards",
        "scripts/run_cabac_p16x16_chroma_ac_cross_plane_first_payload_probe.py",
        r"AMPLITUDE_TAILS\s*=\s*\{.*?\(0x1,\s*0xE,\s*96,\s*96\):\s*\"0000000141d008086b3add75\".*?\(0xE,\s*0x1,\s*96,\s*96\):\s*\"0000000141d008086b7fecfff7\".*?\(0xD,\s*0x2,\s*160,\s*96\):\s*\"0000000141d008086b3addf5\".*?\(0xD,\s*0x2,\s*96,\s*96\):\s*\"0000000141d008086b3bed75\".*?all-negative mixed-sign",
    ),
    (
        "bitstream_scopes_high_amp_cr_payload_context_bank",
        "rtl/h264_bitstream.v",
        r"cabac_res_chroma_ac_cr_sig_ctx_state.*?cabac_res_chroma_ac_cr_last_ctx_state.*?cabac_res_chroma_ac_cr_level_ctx_state_1.*?cabac_chroma_ac_split_plane_ctx.*?cabac_chroma_ac_cb_plane_nz_mask\(\)\s*==\s*4'h2.*?cabac_chroma_ac_cr_plane_nz_mask\(\)\s*==\s*4'hd.*?cabac_chroma_ac_cb_plane_nz_mask\(\)\s*==\s*4'h4.*?cabac_chroma_ac_cr_plane_nz_mask\(\)\s*==\s*4'hb.*?cabac_pending_ctx_sel\[4\]",
    ),
    (
        "probe_promotes_cross_plane_high_amp_miss_target",
        "scripts/run_cabac_p16x16_chroma_ac_high_amp_miss_probe.py",
        r"PROMOTED_CASES\s*=\s*\{.*?\(0x2,\s*0xD,\s*160,\s*160\):\s*\"0000000141d008086b3aec7fe6\".*?\(0x2,\s*0xD,\s*96,\s*160\):\s*\"0000000141d008086b3aec7f7c\".*?\(0x2,\s*0xD,\s*160,\s*96\):\s*\"0000000141d008086b3adefda6\".*?\(0x2,\s*0xD,\s*96,\s*96\):\s*\"0000000141d008086b3adefdfc\".*?\(0x4,\s*0xB,\s*160,\s*160\):\s*\"0000000141d008086b3bcf7fbf\".*?\(0x4,\s*0xB,\s*96,\s*160\):\s*\"0000000141d008086b3bcf7f7f\".*?\(0x4,\s*0xB,\s*160,\s*96\):\s*\"0000000141d008086b3becf5bf\".*?\(0x4,\s*0xB,\s*96,\s*96\):\s*\"0000000141d008086b3becf57f\".*?assert_planes\(cb_mask, cr_mask, fixture, raw, cb_value, cr_value\).*?former Cb singleton / Cr all-but-one",
    ),
    (
        "probe_locks_cross_plane_high_amp_trace_split_bank",
        "scripts/run_cabac_p16x16_chroma_ac_high_amp_trace_probe.py",
        r"promoted_cb2_crd_160_160.*?\"tail\":\s*\"0000000141d008086b3aec7fe6\".*?promoted_cb2_crd_096_096.*?\"tail\":\s*\"0000000141d008086b3adefdfc\".*?control_cbd_cr2_160_160.*?\"tail\":\s*\"0000000141d008086b3addf5\".*?payload_ctx_selects.*?kind=\(22\|23\|24\) sel=\(\\d\+\).*?saw_split_bank\s*=\s*any\(sel >= 16.*?former Cb0x2/Cr0xd",
    ),
    (
        "probe_locks_cr_ac_first_payload_substitutions",
        "scripts/run_cabac_p16x16_chroma_cr_ac_first_payload_substitution_probe.py",
        r"EXPECTED_FIRST_PAYLOAD\s*=\s*0xEB.*?QUEUE_M8_FIRST_PAYLOAD\s*=\s*0x75.*?BIT7_PROMOTED_PAYLOAD\s*=\s*0x6B.*?STRICT_MASKS\s*=\s*\{0x1,\s*0x2,\s*0x4,\s*0x6,\s*0x8,\s*0x9,\s*0xF\}.*?MISS_SIGNATURES\s*=\s*\{.*?0x3:\s*\"bytestream -6\".*?0xE:\s*\"bytestream -7\".*?for label, value in \(\(\"queue_m8_payload_0x75\", QUEUE_M8_FIRST_PAYLOAD\), \(\"bit7_payload_0x6b\", BIT7_PROMOTED_PAYLOAD\)\).*?assert_cr_only\(mask, fixture, raw, label\).*?check_both_plane_guard",
    ),
    (
        "probe_locks_queue_align_baseline_cb_cr_lattices",
        "scripts/run_cabac_p16x16_chroma_cb_ac_queue_align_probe.py",
        r"BASELINE_FULL\s*=\s*set\(range\(1,\s*16\)\).*?check_baseline\(.*?cr_fixtures.*?CR_AC_QUEUE_ALIGN baseline mask=0x\{mask:x\} remains strict.*?queue_m8 both-plane guard confirms global -8 remains non-committable.*?baseline source -7 queue initialization strict-decodes all 15 Cb-only and all 15 Cr-only masks",
    ),
    (
        "probe_promotes_cb_ac_shape_gate",
        "scripts/run_cabac_p16x16_chroma_cb_ac_shape_probe.sh",
        r"Post-cod_i_queue=-7 promotion gate.*?d0 08 08 6b 3a.*?byte-identical IDR.*?exact Cb-only.*?\(0, \"checker_odd\", \"checker_odd\", 133, 40, \"0000000141d008086b3acbb489\"\).*?\(3, \"horiz_bottom\", \"horiz_bottom\", 133, 40, \"0000000141d008086b3acbf1\"\).*?\(0, \"diag_main\", \"diag_main_a32\", 160, 128, \"0000000141d008086b3acc761a5dc1f142\"\).*?\(3, \"diag_anti\", \"diag_anti_a32\", 160, 128, \"0000000141d008086b3acc761eb9322d7d\"\).*?\(0, \"checker_even\", \"checker_even_a32\", 160, 256, \"0000000141d008086b3acc75701410a4\"\).*?\(3, \"horiz_bottom\", \"horiz_bottom_a32\", 160, 256, \"0000000141d008086b3acc757de56a\"\).*?final_slice\.startswith\(\"0000000141d008086b3a\"\)",
    ),
    (
        "probe_promotes_cb_ac_amplitude_gate",
        "scripts/run_cabac_p16x16_chroma_cb_ac_amplitude_probe.sh",
        r"Post-cod_i_queue=-7 promotion gate.*?\+4 checker perturbation.*?no-AC control.*?\+5\) and \+8 now strict-decode.*?\(0, 4, False, 32, \"0000000141d008086b\"\).*?\(3, 4, False, 32, \"0000000141d008086b\"\).*?\(0, 5, True, 40, \"0000000141d008086b3acbb489\"\).*?\(3, 5, True, 40, \"0000000141d008086b3acbf17e\"\).*?\(0, 8, True, 64, \"0000000141d008086b3acbb489\"\).*?\(3, 8, True, 64, \"0000000141d008086b3acbf17e\"\).*?final_slice\.startswith\(\"0000000141d008086b3a\"\).*?CABAC P16x16 sparse Cb AC amplitude gate promoted",
    ),
    (
        "probe_locks_cb_ac_phase_tail_partition",
        "scripts/run_cabac_p16x16_chroma_cb_ac_phase_probe.sh",
        r"PROMOTED_PAYLOADS\s*=\s*\(\(\"queue_m8_payload_0x75\", 0x75\), \(\"bit7_payload_0x6b\", 0x6B\)\).*?phase/polarity split is now locked at the\s+.*?bytestream boundary.*?\(\"top_left_pos_even\", 0, 5, 0, False, \"bytestream -19\", \"0000000141d008086beb2ed226\"\).*?\(\"top_right_neg_odd\", 1, -5, 1, False, \"bytestream -21\", \"0000000141d008086beb2f6b5d\"\).*?\(\"bottom_left_pos_even\", 2, 5, 0, False, \"bytestream -5\", \"0000000141d008086beb2fa1d4\"\).*?\(\"bottom_left_neg_even\", 2, -5, 0, True, \"\", \"0000000141d008086beb2fa1d5\"\).*?\(\"bottom_right_neg_odd\", 3, -5, 1, True, \"\", \"0000000141d008086beb2fc5f8\"\).*?expected_u_sad\s*=\s*8 \* abs\(delta\).*?final_slice\.startswith\(\"0000000141d008086beb\"\).*?assert_first_payload_substitutions\(h264, input_path, name, delta\).*?first-payload substitutions that promote/preserve the full phase lattice",
    ),
    (
        "probe_locks_cr_ac_phase_first_payload_partition",
        "scripts/run_cabac_p16x16_chroma_cr_ac_phase_probe.sh",
        r"PROMOTED_PAYLOADS\s*=\s*\(\(\"queue_m8_payload_0x75\", 0x75\), \(\"bit7_payload_0x6b\", 0x6B\)\).*?final P-slice tails are also locked here.*?\(\"top_left_quantized_even\", 0, 4, 0, False, 32, \"0000000141d008086b\"\).*?\(\"top_left_pos_even\", 0, 5, 0, True, 40, \"0000000141d008086beb2f99af\"\).*?\(\"top_right_neg_odd\", 1, -5, 1, True, 40, \"0000000141d008086beb2f9a24\"\).*?\(\"bottom_left_pos8_odd\", 2, 8, 1, True, 64, \"0000000141d008086beb2f9860\"\).*?\(\"bottom_right_pos8_odd\", 3, 8, 1, True, 64, \"0000000141d008086beb2f9986\"\).*?expected_v_sad\s*=\s*8 \* abs\(delta\).*?final_slice != expected_final_slice.*?final_slice\.startswith\(\"0000000141d008086beb\"\).*?assert_first_payload_substitutions\(h264, input_path, name, delta\).*?first-payload substitutions that preserve the full phase lattice",
    ),
    (
        "probe_promotes_cr_ac_shape_gate",
        "scripts/run_cabac_p16x16_chroma_cr_ac_shape_probe.sh",
        r"Post-cod_i_queue=-7 promotion gate.*?d0 08 08 6b 3a.*?byte-identical IDR.*?exact Cr-only.*?\(0, \"checker_odd\", \"checker_odd\", 133, 40, \"0000000141d008086b3acbe66b\"\).*?\(3, \"horiz_bottom\", \"horiz_bottom\", 133, 40, \"0000000141d008086b3acbe6\"\).*?\(0, \"diag_main\", \"diag_main_a32\", 160, 128, \"0000000141d008086b3acc140d346f726d\"\).*?\(3, \"diag_anti\", \"diag_anti_a32\", 160, 128, \"0000000141d008086b3acc140f5f2c5326\"\).*?\(0, \"checker_even\", \"checker_even_a32\", 160, 256, \"0000000141d008086b3acc13b842ac1e\"\).*?\(3, \"horiz_bottom\", \"horiz_bottom_a32\", 160, 256, \"0000000141d008086b3acc13bf079e\"\).*?final_slice\.startswith\(\"0000000141d008086b3a\"\)",
    ),
    (
        "probe_promotes_cr_ac_amplitude_gate",
        "scripts/run_cabac_p16x16_chroma_cr_ac_amplitude_probe.sh",
        r"Post-cod_i_queue=-7 promotion gate.*?\+4 checker perturbation.*?no-AC control.*?\+5\) and \+8 now strict-decode.*?\(0, 4, False, 32, \"0000000141d008086b\"\).*?\(3, 4, False, 32, \"0000000141d008086b\"\).*?\(0, 5, True, 40, \"0000000141d008086b3acbe66b\"\).*?\(3, 5, True, 40, \"0000000141d008086b3acbe661\"\).*?\(0, 8, True, 64, \"0000000141d008086b3acbe66b\"\).*?\(3, 8, True, 64, \"0000000141d008086b3acbe661\"\).*?final_slice\.startswith\(\"0000000141d008086b3a\"\).*?CABAC P16x16 sparse Cr AC amplitude gate promoted",
    ),
    (
        "gate_locks_combined_luma_chroma_dc_residual_smoke",
        "scripts/run_cabac_p16x16_luma_chroma_dc_residual_check.py",
        r"luma \+ chroma DC-only residual.*?EXPECTED_FINAL_SLICE\s*=\s*\"0000000141d008086b3ab6beea5045573d34f76b\".*?EXPECTED_CAVLC_SUPPRESSED_BITS\s*=\s*164.*?EXPECTED_Y_SAD\s*=\s*2048.*?EXPECTED_U_SAD\s*=\s*512.*?EXPECTED_V_SAD\s*=\s*512.*?cabac_chroma_dc_mbs=1.*?cabac_chroma_ac_mbs=0.*?cabac_chroma_cb_dc_mbs=1.*?cabac_chroma_cr_dc_mbs=1.*?cabac_chroma_cb_ac_blocks=0.*?cabac_chroma_cr_ac_blocks=0.*?CABAC P16x16 combined luma\+Cb\+Cr DC-only residual smoke strict-decodes",
    ),
    (
        "gate_locks_luma_single_plane_chroma_dc_residual_smoke",
        "scripts/run_cabac_p16x16_luma_single_chroma_dc_residual_check.py",
        r"luma \+ single-plane chroma-DC residual.*?EXPECTED_FINAL_SLICE\s*=\s*\"0000000141d008086b3ab6beea5045573d34f7\".*?EXPECTED_CAVLC_SUPPRESSED_BITS\s*=\s*152.*?EXPECTED_Y_SAD\s*=\s*2048.*?name=\"cb_dc\".*?expected_cb_dc_mbs=1.*?expected_cr_dc_mbs=0.*?expected_u_sad=512.*?expected_v_sad=0.*?name=\"cr_dc\".*?expected_cb_dc_mbs=0.*?expected_cr_dc_mbs=1.*?expected_u_sad=0.*?expected_v_sad=512.*?cabac_chroma_dc_mbs=1.*?cabac_chroma_ac_mbs=0.*?cabac_chroma_cb_dc_mbs=\{case\.expected_cb_dc_mbs\}.*?cabac_chroma_cr_dc_mbs=\{case\.expected_cr_dc_mbs\}.*?CABAC P16x16 luma plus single-plane Cb/Cr DC residual smoke cases strict-decode",
    ),
    (
        "gate_locks_combined_luma_chroma_residual_smoke",
        "scripts/run_cabac_p16x16_luma_chroma_residual_check.py",
        r"both luma residual and both-plane chroma AC residual.*?EXPECTED_FINAL_SLICE\s*=\s*\"0000000141d008086b3afee9ffdd7d77fdb6f7\".*?EXPECTED_CAVLC_SUPPRESSED_BITS\s*=\s*240.*?EXPECTED_Y_SAD\s*=\s*2048.*?EXPECTED_U_SAD\s*=\s*256.*?EXPECTED_V_SAD\s*=\s*256.*?cabac_chroma_cb_ac_blocks=4.*?cabac_chroma_cr_ac_blocks=4.*?CABAC P16x16 combined luma\+Cb\+Cr AC residual smoke strict-decodes",
    ),
    (
        "gate_locks_luma_single_plane_chroma_ac_residual_smoke",
        "scripts/run_cabac_p16x16_luma_single_chroma_ac_residual_check.py",
        r"luma \+ single-plane chroma-AC residual.*?EXPECTED_CAVLC_SUPPRESSED_BITS\s*=\s*190.*?EXPECTED_Y_SAD\s*=\s*2048.*?name=\"cb_ac\".*?expected_final_slice=\"0000000141d008086b3abeff\".*?expected_u_sad=256.*?expected_v_sad=0.*?expected_cb_ac_blocks=4.*?expected_cr_ac_blocks=0.*?name=\"cr_ac\".*?expected_final_slice=\"0000000141d008086b3af7ef\".*?expected_u_sad=0.*?expected_v_sad=256.*?expected_cb_ac_blocks=0.*?expected_cr_ac_blocks=4.*?CABAC P16x16 luma plus single-plane Cb/Cr AC residual smoke cases strict-decode",
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

    print("[PASS] CABAC chroma residual wiring preserves CBP, scan, context bases, edge-coded plane-local chroma AC CBF context selection, state-dispatch, category scheduling, decoded-plane sanity coverage, dense Cr strict-pass promotion, Cr sparse strict-pass promotion, promoted Cb/Cr chroma-AC mask lattices with exact plane-local SAD, promoted cross-plane Cb+Cr AC strict-decode coverage, dense Cb and both-plane AC strict-pass controls plus decoded-plane sanity, chroma AC per-plane block counters, scoped high-amplitude cross-plane Cr payload-bank promotion locks, Cr AC first-payload substitution coverage, refreshed queue-alignment Cb/Cr lattice baseline coverage, Cb/Cr AC promoted shape/amplitude strict-decode coverage, Cb AC phase/polarity tail plus first-payload substitution coverage, Cr AC phase/polarity tail plus first-payload substitution coverage, and combined plus single-plane luma/chroma DC-only/AC residual strict-decode smoke coverage with locked current decoded-plane metrics")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
