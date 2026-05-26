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
        "bitstream_initializes_chroma_residual_contexts",
        "rtl/h264_bitstream.v",
        r"cabac_res_chroma_dc_cbf_ctx_state\[0\]\s*<=\s*cabac_init_state\(5,\s*54,\s*26\).*?cabac_res_chroma_dc_sig_ctx_state\[0\]\s*<=\s*cabac_init_state\(3,\s*64,\s*26\).*?cabac_res_chroma_dc_last_ctx_state\[0\]\s*<=\s*cabac_init_state\(1,\s*67,\s*26\).*?cabac_res_chroma_dc_level_ctx_state_0\s*<=\s*cabac_init_state\(0,\s*70,\s*26\).*?cabac_res_chroma_ac_cbf_ctx_state\[0\]\s*<=\s*cabac_init_state\(-1,\s*48,\s*26\).*?cabac_res_chroma_ac_sig_ctx_state\[0\]\s*<=\s*cabac_init_state\(7,\s*50,\s*26\).*?cabac_res_chroma_ac_last_ctx_state\[0\]\s*<=\s*cabac_init_state\(16,\s*30,\s*26\).*?cabac_res_chroma_ac_level_ctx_state_0\s*<=\s*cabac_init_state\(0,\s*58,\s*26\)",
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
        "gate_generates_cr_ac_expected_miss_fixture",
        "scripts/run_cabac_p16x16_chroma_residual_red_check.sh",
        r"INPUT_CR_AC=.*?smoke_16x16_2f_cabac_p16x16_chroma_residual_cr_ac\.yuv.*?'cr_ac':.*?CABAC_CHROMA_INCLUDE_CR_AC",
    ),
    (
        "gate_checks_cb_vs_cr_ac_plane_counters",
        "scripts/run_cabac_p16x16_chroma_residual_red_check.sh",
        r"cabac_chroma_cb_ac_mbs=1\s+cabac_chroma_cr_ac_mbs=0.*?cabac_chroma_cb_ac_mbs=0\s+cabac_chroma_cr_ac_mbs=1",
    ),
    (
        "gate_locks_cr_ac_bytestream29_expected_miss",
        "scripts/run_cabac_p16x16_chroma_residual_red_check.sh",
        r"expect_ffmpeg_fail.*?bytestream -29.*?expected strict FFmpeg decode miss",
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

    print("[PASS] CABAC chroma residual wiring preserves CBP, scan, context-base, state-dispatch, category scheduling, and Cr AC expected-miss coverage")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
