#!/usr/bin/env python3
"""Integrated CABAC P16x16 luma + sparse chroma-AC residual smoke gate.

The dense luma+chroma AC gates prove all four chroma AC blocks active.  This
focused check covers representative sparse mixed cases with luma residual plus
one or two active chroma AC blocks, including all four single-plane Cb/Cr
quadrants, same-plane row/column pairs, same-block Cb+Cr quadrant cases, both
row-adjacent directions, both column-adjacent directions, opposite-diagonal Cb+Cr pairs,
and complementary two-block row/column pairs on both chroma planes, plus
high-amplitude same-quadrant and row/column-complement subsets with luma
residual present, same-mask row/diagonal controls, including their high-amplitude
forms, default all-but-one same-mask mirrors, the complementary split-row/column
+/-32 sign matrix, reciprocal high-amplitude right-column/diagonal skew pairs,
and mirrored
high-amplitude three-plus-one edge complements with mixed Cb/Cr signs, including
single-right/three-right, middle-left/middle-right, and corner-left/corner-right
all-but-one mirrors under luma residual.
It locks strict FFmpeg decode, plane-local CABAC counters, CAVLC suppression
counts, final P-slice bytes, current decoded-plane metrics, and per-4x4
chroma-block locality so sparse residuals cannot silently land in the wrong
chroma quadrant while preserving the same aggregate SAD, including the higher
magnitude CABAC payload path that previously needed separate non-luma probes.
"""

from __future__ import annotations

import os
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from scripts.rtl_runner import BuildConfig, build_sim, stage_workspace  # noqa: E402

WIDTH = HEIGHT = 16
LUMA_SIZE = WIDTH * HEIGHT
CHROMA_SIZE = (WIDTH // 2) * (HEIGHT // 2)
FRAME_SIZE = LUMA_SIZE + 2 * CHROMA_SIZE
EXPECTED_BYTES = FRAME_SIZE * 2
EXPECTED_Y_SAD = 2048


@dataclass(frozen=True)
class Case:
    name: str
    cb_mask: int
    cr_mask: int
    expected_final_slice: str
    expected_cavlc_suppressed_bits: int
    expected_y_sad: int
    expected_u_sad: int
    expected_v_sad: int
    cb_sample_value: int = 136
    cr_sample_value: int = 136

    @property
    def expected_cb_ac_mbs(self) -> int:
        return 1 if self.cb_mask else 0

    @property
    def expected_cr_ac_mbs(self) -> int:
        return 1 if self.cr_mask else 0

    @property
    def expected_cb_ac_blocks(self) -> int:
        return self.cb_mask.bit_count()

    @property
    def expected_cr_ac_blocks(self) -> int:
        return self.cr_mask.bit_count()


CASES = (
    Case(
        name="cb_ac_m1",
        cb_mask=0x1,
        cr_mask=0x0,
        expected_final_slice="0000000141d008086b3ab6e931d045573d34f76955d4",
        expected_cavlc_suppressed_bits=151,
        expected_y_sad=EXPECTED_Y_SAD,
        expected_u_sad=64,
        expected_v_sad=0,
    ),
    Case(
        name="cb_ac_m2",
        cb_mask=0x2,
        cr_mask=0x0,
        expected_final_slice="0000000141d008086b3ab6e931d045573d34f76a08ea",
        expected_cavlc_suppressed_bits=151,
        expected_y_sad=EXPECTED_Y_SAD,
        expected_u_sad=64,
        expected_v_sad=0,
    ),
    Case(
        name="cb_ac_m4",
        cb_mask=0x4,
        cr_mask=0x0,
        expected_final_slice="0000000141d008086b3ab6e931d045573d34f76a46",
        expected_cavlc_suppressed_bits=151,
        expected_y_sad=EXPECTED_Y_SAD,
        expected_u_sad=64,
        expected_v_sad=0,
    ),
    Case(
        name="cb_ac_m8",
        cb_mask=0x8,
        cr_mask=0x0,
        expected_final_slice="0000000141d008086b3ab6e931d045573d34f76a750e",
        expected_cavlc_suppressed_bits=151,
        expected_y_sad=EXPECTED_Y_SAD,
        expected_u_sad=64,
        expected_v_sad=0,
    ),
    Case(
        name="cb_ac_m3",
        cb_mask=0x3,
        cr_mask=0x0,
        expected_final_slice="0000000141d008086b3ab6e931d045573d34f76c734600000300",
        expected_cavlc_suppressed_bits=168,
        expected_y_sad=EXPECTED_Y_SAD,
        expected_u_sad=128,
        expected_v_sad=0,
    ),
    Case(
        name="cb_ac_m5",
        cb_mask=0x5,
        cr_mask=0x0,
        expected_final_slice="0000000141d008086b3ab6e931d045573d34f76cc5c200000300",
        expected_cavlc_suppressed_bits=166,
        expected_y_sad=EXPECTED_Y_SAD,
        expected_u_sad=128,
        expected_v_sad=0,
    ),
    Case(
        name="cb_ac_m10",
        cb_mask=0xA,
        cr_mask=0x0,
        expected_final_slice="0000000141d008086b3ab6e931d045573d34f76ccb1700000300",
        expected_cavlc_suppressed_bits=166,
        expected_y_sad=EXPECTED_Y_SAD,
        expected_u_sad=128,
        expected_v_sad=0,
    ),
    Case(
        name="cb_ac_m12",
        cb_mask=0xC,
        cr_mask=0x0,
        expected_final_slice="0000000141d008086b3ab6e931d045573d34f76c7a4100000300",
        expected_cavlc_suppressed_bits=168,
        expected_y_sad=EXPECTED_Y_SAD,
        expected_u_sad=128,
        expected_v_sad=0,
    ),
    Case(
        name="cr_ac_m1",
        cb_mask=0x0,
        cr_mask=0x1,
        expected_final_slice="0000000141d008086b3ab6e931d045573d34f76a3fd5",
        expected_cavlc_suppressed_bits=151,
        expected_y_sad=EXPECTED_Y_SAD,
        expected_u_sad=0,
        expected_v_sad=64,
    ),
    Case(
        name="cr_ac_m2",
        cb_mask=0x0,
        cr_mask=0x2,
        expected_final_slice="0000000141d008086b3ab6e931d045573d34f76a408b",
        expected_cavlc_suppressed_bits=151,
        expected_y_sad=EXPECTED_Y_SAD,
        expected_u_sad=0,
        expected_v_sad=64,
    ),
    Case(
        name="cr_ac_m4",
        cb_mask=0x0,
        cr_mask=0x4,
        expected_final_slice="0000000141d008086b3ab6e931d045573d34f76a3db8",
        expected_cavlc_suppressed_bits=151,
        expected_y_sad=EXPECTED_Y_SAD,
        expected_u_sad=0,
        expected_v_sad=64,
    ),
    Case(
        name="cr_ac_m8",
        cb_mask=0x0,
        cr_mask=0x8,
        expected_final_slice="0000000141d008086b3ab6e931d045573d34f76a3f83",
        expected_cavlc_suppressed_bits=151,
        expected_y_sad=EXPECTED_Y_SAD,
        expected_u_sad=0,
        expected_v_sad=64,
    ),
    Case(
        name="cr_ac_m3",
        cb_mask=0x0,
        cr_mask=0x3,
        expected_final_slice="0000000141d008086b3ab6e931d045573d34f76ad6a000000300",
        expected_cavlc_suppressed_bits=168,
        expected_y_sad=EXPECTED_Y_SAD,
        expected_u_sad=0,
        expected_v_sad=128,
    ),
    Case(
        name="cr_ac_m5",
        cb_mask=0x0,
        cr_mask=0x5,
        expected_final_slice="0000000141d008086b3ab6e931d045573d34f76af31d00000300",
        expected_cavlc_suppressed_bits=166,
        expected_y_sad=EXPECTED_Y_SAD,
        expected_u_sad=0,
        expected_v_sad=128,
    ),
    Case(
        name="cr_ac_m10",
        cb_mask=0x0,
        cr_mask=0xA,
        expected_final_slice="0000000141d008086b3ab6e931d045573d34f76af4fd00000300",
        expected_cavlc_suppressed_bits=166,
        expected_y_sad=EXPECTED_Y_SAD,
        expected_u_sad=0,
        expected_v_sad=128,
    ),
    Case(
        name="cr_ac_m12",
        cb_mask=0x0,
        cr_mask=0xC,
        expected_final_slice="0000000141d008086b3ab6e931d045573d34f76ad8e400000300",
        expected_cavlc_suppressed_bits=168,
        expected_y_sad=EXPECTED_Y_SAD,
        expected_u_sad=0,
        expected_v_sad=128,
    ),
    Case(
        name="cbcr_ac_m1",
        cb_mask=0x1,
        cr_mask=0x1,
        expected_final_slice="0000000141d008086b3ab6e931d045573d34f76966740000",
        expected_cavlc_suppressed_bits=162,
        expected_y_sad=EXPECTED_Y_SAD,
        expected_u_sad=64,
        expected_v_sad=64,
    ),
    Case(
        name="cbcr_ac_m2",
        cb_mask=0x2,
        cr_mask=0x2,
        expected_final_slice="0000000141d008086b3ab6e931d045573d34f76a57890000",
        expected_cavlc_suppressed_bits=162,
        expected_y_sad=EXPECTED_Y_SAD,
        expected_u_sad=64,
        expected_v_sad=64,
    ),
    Case(
        name="cbcr_ac_m4",
        cb_mask=0x4,
        cr_mask=0x4,
        expected_final_slice="0000000141d008086b3ab6e931d045573d34f76a1f1a0000",
        expected_cavlc_suppressed_bits=162,
        expected_y_sad=EXPECTED_Y_SAD,
        expected_u_sad=64,
        expected_v_sad=64,
    ),
    Case(
        name="cbcr_ac_m2_1",
        cb_mask=0x2,
        cr_mask=0x1,
        expected_final_slice="0000000141d008086b3ab6e931d045573d34f76a57890000",
        expected_cavlc_suppressed_bits=162,
        expected_y_sad=EXPECTED_Y_SAD,
        expected_u_sad=64,
        expected_v_sad=64,
    ),
    Case(
        name="cbcr_ac_m4_8",
        cb_mask=0x4,
        cr_mask=0x8,
        expected_final_slice="0000000141d008086b3ab6e931d045573d34f76a1f1a0000",
        expected_cavlc_suppressed_bits=162,
        expected_y_sad=EXPECTED_Y_SAD,
        expected_u_sad=64,
        expected_v_sad=64,
    ),
    Case(
        name="cbcr_ac_m1_2",
        cb_mask=0x1,
        cr_mask=0x2,
        expected_final_slice="0000000141d008086b3ab6e931d045573d34f76966740000",
        expected_cavlc_suppressed_bits=162,
        expected_y_sad=EXPECTED_Y_SAD,
        expected_u_sad=64,
        expected_v_sad=64,
    ),
    Case(
        name="cbcr_ac_m8_4",
        cb_mask=0x8,
        cr_mask=0x4,
        expected_final_slice="0000000141d008086b3ab6e931d045573d34f76a43ce0000",
        expected_cavlc_suppressed_bits=162,
        expected_y_sad=EXPECTED_Y_SAD,
        expected_u_sad=64,
        expected_v_sad=64,
    ),
    Case(
        name="cbcr_ac_m1_4",
        cb_mask=0x1,
        cr_mask=0x4,
        expected_final_slice="0000000141d008086b3ab6e931d045573d34f76966740000",
        expected_cavlc_suppressed_bits=162,
        expected_y_sad=EXPECTED_Y_SAD,
        expected_u_sad=64,
        expected_v_sad=64,
    ),
    Case(
        name="cbcr_ac_m4_1",
        cb_mask=0x4,
        cr_mask=0x1,
        expected_final_slice="0000000141d008086b3ab6e931d045573d34f76a1f1a0000",
        expected_cavlc_suppressed_bits=162,
        expected_y_sad=EXPECTED_Y_SAD,
        expected_u_sad=64,
        expected_v_sad=64,
    ),
    Case(
        name="cbcr_ac_m2_8",
        cb_mask=0x2,
        cr_mask=0x8,
        expected_final_slice="0000000141d008086b3ab6e931d045573d34f76a57890000",
        expected_cavlc_suppressed_bits=162,
        expected_y_sad=EXPECTED_Y_SAD,
        expected_u_sad=64,
        expected_v_sad=64,
    ),
    Case(
        name="cbcr_ac_m8_2",
        cb_mask=0x8,
        cr_mask=0x2,
        expected_final_slice="0000000141d008086b3ab6e931d045573d34f76a43ce0000",
        expected_cavlc_suppressed_bits=162,
        expected_y_sad=EXPECTED_Y_SAD,
        expected_u_sad=64,
        expected_v_sad=64,
    ),
    Case(
        name="cbcr_ac_m1_8",
        cb_mask=0x1,
        cr_mask=0x8,
        expected_final_slice="0000000141d008086b3ab6e931d045573d34f76966740000",
        expected_cavlc_suppressed_bits=162,
        expected_y_sad=EXPECTED_Y_SAD,
        expected_u_sad=64,
        expected_v_sad=64,
    ),
    Case(
        name="cbcr_ac_m8_1",
        cb_mask=0x8,
        cr_mask=0x1,
        expected_final_slice="0000000141d008086b3ab6e931d045573d34f76a43ce0000",
        expected_cavlc_suppressed_bits=162,
        expected_y_sad=EXPECTED_Y_SAD,
        expected_u_sad=64,
        expected_v_sad=64,
    ),
    Case(
        name="cbcr_ac_m2_4",
        cb_mask=0x2,
        cr_mask=0x4,
        expected_final_slice="0000000141d008086b3ab6e931d045573d34f76a57890000",
        expected_cavlc_suppressed_bits=162,
        expected_y_sad=EXPECTED_Y_SAD,
        expected_u_sad=64,
        expected_v_sad=64,
    ),
    Case(
        name="cbcr_ac_m4_2",
        cb_mask=0x4,
        cr_mask=0x2,
        expected_final_slice="0000000141d008086b3ab6e931d045573d34f76a1f1a0000",
        expected_cavlc_suppressed_bits=162,
        expected_y_sad=EXPECTED_Y_SAD,
        expected_u_sad=64,
        expected_v_sad=64,
    ),
    Case(
        name="cbcr_ac_m8",
        cb_mask=0x8,
        cr_mask=0x8,
        expected_final_slice="0000000141d008086b3ab6e931d045573d34f76a43ce0000",
        expected_cavlc_suppressed_bits=162,
        expected_y_sad=EXPECTED_Y_SAD,
        expected_u_sad=64,
        expected_v_sad=64,
    ),
    Case(
        name="cbcr_ac_m1_hi",
        cb_mask=0x1,
        cr_mask=0x1,
        expected_final_slice="0000000141d008086b3af6fd7bdd",
        expected_cavlc_suppressed_bits=234,
        expected_y_sad=EXPECTED_Y_SAD,
        expected_u_sad=256,
        expected_v_sad=256,
        cb_sample_value=160,
        cr_sample_value=160,
    ),
    Case(
        name="cbcr_ac_m2_hi",
        cb_mask=0x2,
        cr_mask=0x2,
        expected_final_slice="0000000141d008086b3abfed3bd9",
        expected_cavlc_suppressed_bits=234,
        expected_y_sad=EXPECTED_Y_SAD,
        expected_u_sad=256,
        expected_v_sad=256,
        cb_sample_value=160,
        cr_sample_value=160,
    ),
    Case(
        name="cbcr_ac_m4_hi",
        cb_mask=0x4,
        cr_mask=0x4,
        expected_final_slice="0000000141d008086b3afeed7df9",
        expected_cavlc_suppressed_bits=234,
        expected_y_sad=EXPECTED_Y_SAD,
        expected_u_sad=256,
        expected_v_sad=256,
        cb_sample_value=160,
        cr_sample_value=160,
    ),
    Case(
        name="cbcr_ac_m8_hi",
        cb_mask=0x8,
        cr_mask=0x8,
        expected_final_slice="0000000141d008086b3af6fbf9d8",
        expected_cavlc_suppressed_bits=230,
        expected_y_sad=EXPECTED_Y_SAD,
        expected_u_sad=256,
        expected_v_sad=256,
        cb_sample_value=160,
        cr_sample_value=160,
    ),
    Case(
        name="cbcr_ac_m6",
        cb_mask=0x6,
        cr_mask=0x6,
        expected_final_slice="0000000141d008086b3abff93df5",
        expected_cavlc_suppressed_bits=198,
        expected_y_sad=EXPECTED_Y_SAD,
        expected_u_sad=128,
        expected_v_sad=128,
    ),
    Case(
        name="cbcr_ac_m7",
        cb_mask=0x7,
        cr_mask=0x7,
        expected_final_slice="0000000141d008086b3af7eff1fc7fff",
        expected_cavlc_suppressed_bits=218,
        expected_y_sad=EXPECTED_Y_SAD,
        expected_u_sad=192,
        expected_v_sad=192,
    ),
    Case(
        name="cbcr_ac_m9",
        cb_mask=0x9,
        cr_mask=0x9,
        expected_final_slice="0000000141d008086b3afeebf3fb7d",
        expected_cavlc_suppressed_bits=198,
        expected_y_sad=EXPECTED_Y_SAD,
        expected_u_sad=128,
        expected_v_sad=128,
    ),
    Case(
        name="cbcr_ac_m11_same",
        cb_mask=0xB,
        cr_mask=0xB,
        expected_final_slice="0000000141d008086b3afeed79f65fff",
        expected_cavlc_suppressed_bits=218,
        expected_y_sad=EXPECTED_Y_SAD,
        expected_u_sad=192,
        expected_v_sad=192,
    ),
    Case(
        name="cbcr_ac_m13_same",
        cb_mask=0xD,
        cr_mask=0xD,
        expected_final_slice="0000000141d008086b3ab7fbb9f75f5f",
        expected_cavlc_suppressed_bits=218,
        expected_y_sad=EXPECTED_Y_SAD,
        expected_u_sad=192,
        expected_v_sad=192,
    ),
    Case(
        name="cbcr_ac_m14_same",
        cb_mask=0xE,
        cr_mask=0xE,
        expected_final_slice="0000000141d008086b3afeed7ddafd5f",
        expected_cavlc_suppressed_bits=218,
        expected_y_sad=EXPECTED_Y_SAD,
        expected_u_sad=192,
        expected_v_sad=192,
    ),
    Case(
        name="cbcr_ac_m6_hi",
        cb_mask=0x6,
        cr_mask=0x6,
        expected_final_slice="0000000141d008086b3af7e97df5fff77f3eff6d",
        expected_cavlc_suppressed_bits=308,
        expected_y_sad=EXPECTED_Y_SAD,
        expected_u_sad=512,
        expected_v_sad=512,
        cb_sample_value=160,
        cr_sample_value=160,
    ),
    Case(
        name="cbcr_ac_m7_hi_same",
        cb_mask=0x7,
        cr_mask=0x7,
        expected_final_slice="0000000141d008086b3ab7",
        expected_cavlc_suppressed_bits=360,
        expected_y_sad=EXPECTED_Y_SAD,
        expected_u_sad=768,
        expected_v_sad=768,
        cb_sample_value=160,
        cr_sample_value=160,
    ),
    Case(
        name="cbcr_ac_m9_hi",
        cb_mask=0x9,
        cr_mask=0x9,
        expected_final_slice="0000000141d008086b3afeff7dd6f777bdbdf7eebf",
        expected_cavlc_suppressed_bits=308,
        expected_y_sad=EXPECTED_Y_SAD,
        expected_u_sad=512,
        expected_v_sad=512,
        cb_sample_value=160,
        cr_sample_value=160,
    ),
    Case(
        name="cbcr_ac_m6_9_hi",
        cb_mask=0x6,
        cr_mask=0x9,
        expected_final_slice="0000000141d008086b3af7e97df5ffd7bd7efffd",
        expected_cavlc_suppressed_bits=308,
        expected_y_sad=EXPECTED_Y_SAD,
        expected_u_sad=512,
        expected_v_sad=512,
        cb_sample_value=160,
        cr_sample_value=160,
    ),
    Case(
        name="cbcr_ac_m6_9_hi_cbpos_crneg",
        cb_mask=0x6,
        cr_mask=0x9,
        expected_final_slice="0000000141d008086b3af6e97fdaddf77d36fffd",
        expected_cavlc_suppressed_bits=307,
        expected_y_sad=EXPECTED_Y_SAD,
        expected_u_sad=512,
        expected_v_sad=512,
        cb_sample_value=160,
        cr_sample_value=96,
    ),
    Case(
        name="cbcr_ac_m6_9_hi_cbneg_crpos",
        cb_mask=0x6,
        cr_mask=0x9,
        expected_final_slice="0000000141d008086b3af7ebfdf4c7f7bd7efffd",
        expected_cavlc_suppressed_bits=305,
        expected_y_sad=EXPECTED_Y_SAD,
        expected_u_sad=512,
        expected_v_sad=512,
        cb_sample_value=96,
        cr_sample_value=160,
    ),
    Case(
        name="cbcr_ac_m6_9_hi_cbneg_crneg",
        cb_mask=0x6,
        cr_mask=0x9,
        expected_final_slice="0000000141d008086b3afeebffda47ff7d36fffd",
        expected_cavlc_suppressed_bits=304,
        expected_y_sad=EXPECTED_Y_SAD,
        expected_u_sad=512,
        expected_v_sad=512,
        cb_sample_value=96,
        cr_sample_value=96,
    ),
    Case(
        name="cbcr_ac_m9_6_hi",
        cb_mask=0x9,
        cr_mask=0x6,
        expected_final_slice="0000000141d008086b3ab6ef73d6f77f7f36ff7e",
        expected_cavlc_suppressed_bits=308,
        expected_y_sad=EXPECTED_Y_SAD,
        expected_u_sad=512,
        expected_v_sad=512,
        cb_sample_value=160,
        cr_sample_value=160,
    ),
    Case(
        name="cbcr_ac_m9_6_hi_cbpos_crneg",
        cb_mask=0x9,
        cr_mask=0x6,
        expected_final_slice="0000000141d008086b3ab6ef73d6f77f7f35ffee",
        expected_cavlc_suppressed_bits=305,
        expected_y_sad=EXPECTED_Y_SAD,
        expected_u_sad=512,
        expected_v_sad=512,
        cb_sample_value=160,
        cr_sample_value=96,
    ),
    Case(
        name="cbcr_ac_m9_6_hi_cbneg_crpos",
        cb_mask=0x9,
        cr_mask=0x6,
        expected_final_slice="0000000141d008086b3ab6fdf3d6d5f77f36ff7e",
        expected_cavlc_suppressed_bits=307,
        expected_y_sad=EXPECTED_Y_SAD,
        expected_u_sad=512,
        expected_v_sad=512,
        cb_sample_value=96,
        cr_sample_value=160,
    ),
    Case(
        name="cbcr_ac_m9_6_hi_cbneg_crneg",
        cb_mask=0x9,
        cr_mask=0x6,
        expected_final_slice="0000000141d008086b3ab6fdf3d6d5f77f35ffee",
        expected_cavlc_suppressed_bits=304,
        expected_y_sad=EXPECTED_Y_SAD,
        expected_u_sad=512,
        expected_v_sad=512,
        cb_sample_value=96,
        cr_sample_value=96,
    ),
    Case(
        name="cbcr_ac_m7_8_hi",
        cb_mask=0x7,
        cr_mask=0x8,
        expected_final_slice="0000000141d008086b3afefb79d3f5f73ff7f7eeea",
        expected_cavlc_suppressed_bits=295,
        expected_y_sad=EXPECTED_Y_SAD,
        expected_u_sad=768,
        expected_v_sad=256,
        cb_sample_value=160,
        cr_sample_value=160,
    ),
    Case(
        name="cbcr_ac_m8_7_hi",
        cb_mask=0x8,
        cr_mask=0x7,
        expected_final_slice="0000000141d008086b3abeefbffc7f5f7dbfff6dff",
        expected_cavlc_suppressed_bits=295,
        expected_y_sad=EXPECTED_Y_SAD,
        expected_u_sad=256,
        expected_v_sad=768,
        cb_sample_value=160,
        cr_sample_value=160,
    ),
    Case(
        name="cbcr_ac_m7_8_hi_cbpos_crneg",
        cb_mask=0x7,
        cr_mask=0x8,
        expected_final_slice="0000000141d008086b3afefb79d3f5f73ff7f7eeea",
        expected_cavlc_suppressed_bits=295,
        expected_y_sad=EXPECTED_Y_SAD,
        expected_u_sad=768,
        expected_v_sad=256,
        cb_sample_value=160,
        cr_sample_value=96,
    ),
    Case(
        name="cbcr_ac_m7_8_hi_cbneg_crpos",
        cb_mask=0x7,
        cr_mask=0x8,
        expected_final_slice="0000000141d008086b3afefb31d3f5d77ff7ff7eeb",
        expected_cavlc_suppressed_bits=291,
        expected_y_sad=EXPECTED_Y_SAD,
        expected_u_sad=768,
        expected_v_sad=256,
        cb_sample_value=96,
        cr_sample_value=160,
    ),
    Case(
        name="cbcr_ac_m7_8_hi_cbneg_crneg",
        cb_mask=0x7,
        cr_mask=0x8,
        expected_final_slice="0000000141d008086b3afefb31d3f5d77ff7ff7eeb",
        expected_cavlc_suppressed_bits=291,
        expected_y_sad=EXPECTED_Y_SAD,
        expected_u_sad=768,
        expected_v_sad=256,
        cb_sample_value=96,
        cr_sample_value=96,
    ),
    Case(
        name="cbcr_ac_m8_7_hi_cbpos_crneg",
        cb_mask=0x8,
        cr_mask=0x7,
        expected_final_slice="0000000141d008086b3abeefbffc7f5f3dbff7ecff",
        expected_cavlc_suppressed_bits=291,
        expected_y_sad=EXPECTED_Y_SAD,
        expected_u_sad=256,
        expected_v_sad=768,
        cb_sample_value=160,
        cr_sample_value=96,
    ),
    Case(
        name="cbcr_ac_m8_7_hi_cbneg_crpos",
        cb_mask=0x8,
        cr_mask=0x7,
        expected_final_slice="0000000141d008086b3abeedb9fc7f5f7dbfff6dff",
        expected_cavlc_suppressed_bits=295,
        expected_y_sad=EXPECTED_Y_SAD,
        expected_u_sad=256,
        expected_v_sad=768,
        cb_sample_value=96,
        cr_sample_value=160,
    ),
    Case(
        name="cbcr_ac_m8_7_hi_cbneg_crneg",
        cb_mask=0x8,
        cr_mask=0x7,
        expected_final_slice="0000000141d008086b3abeedb9fc7f5f3dbff7ecff",
        expected_cavlc_suppressed_bits=291,
        expected_y_sad=EXPECTED_Y_SAD,
        expected_u_sad=256,
        expected_v_sad=768,
        cb_sample_value=96,
        cr_sample_value=96,
    ),
    Case(
        name="cbcr_ac_m11_4_hi",
        cb_mask=0xB,
        cr_mask=0x4,
        expected_final_slice="0000000141d008086b3abeefb5d7d7f7fd3dff6ced",
        expected_cavlc_suppressed_bits=296,
        expected_y_sad=EXPECTED_Y_SAD,
        expected_u_sad=768,
        expected_v_sad=256,
        cb_sample_value=160,
        cr_sample_value=160,
    ),
    Case(
        name="cbcr_ac_m11_4_hi_cbpos_crneg",
        cb_mask=0xB,
        cr_mask=0x4,
        expected_final_slice="0000000141d008086b3abeefb5d7d7f7fd3dff6ced",
        expected_cavlc_suppressed_bits=294,
        expected_y_sad=EXPECTED_Y_SAD,
        expected_u_sad=768,
        expected_v_sad=256,
        cb_sample_value=160,
        cr_sample_value=96,
    ),
    Case(
        name="cbcr_ac_m11_4_hi_cbneg_crpos",
        cb_mask=0xB,
        cr_mask=0x4,
        expected_final_slice="0000000141d008086b3abeed7fd7d7d77f3dff6fef",
        expected_cavlc_suppressed_bits=294,
        expected_y_sad=EXPECTED_Y_SAD,
        expected_u_sad=768,
        expected_v_sad=256,
        cb_sample_value=96,
        cr_sample_value=160,
    ),
    Case(
        name="cbcr_ac_m11_4_hi_cbneg_crneg",
        cb_mask=0xB,
        cr_mask=0x4,
        expected_final_slice="0000000141d008086b3abeed7fd7d7d77f3dff6fef",
        expected_cavlc_suppressed_bits=292,
        expected_y_sad=EXPECTED_Y_SAD,
        expected_u_sad=768,
        expected_v_sad=256,
        cb_sample_value=96,
        cr_sample_value=96,
    ),
    Case(
        name="cbcr_ac_m4_11_hi",
        cb_mask=0x4,
        cr_mask=0xB,
        expected_final_slice="0000000141d008086b3abeff31f1ef7f7fb4ff7ffbef",
        expected_cavlc_suppressed_bits=296,
        expected_y_sad=EXPECTED_Y_SAD,
        expected_u_sad=256,
        expected_v_sad=768,
        cb_sample_value=160,
        cr_sample_value=160,
    ),
    Case(
        name="cbcr_ac_m4_11_hi_cbpos_crneg",
        cb_mask=0x4,
        cr_mask=0xB,
        expected_final_slice="0000000141d008086b3abeff31f1ef57fdb4ff6febef",
        expected_cavlc_suppressed_bits=294,
        expected_y_sad=EXPECTED_Y_SAD,
        expected_u_sad=256,
        expected_v_sad=768,
        cb_sample_value=160,
        cr_sample_value=96,
    ),
    Case(
        name="cbcr_ac_m4_11_hi_cbneg_crpos",
        cb_mask=0x4,
        cr_mask=0xB,
        expected_final_slice="0000000141d008086b3abee93df1ef7f7fb4ff7ff9e7",
        expected_cavlc_suppressed_bits=294,
        expected_y_sad=EXPECTED_Y_SAD,
        expected_u_sad=256,
        expected_v_sad=768,
        cb_sample_value=96,
        cr_sample_value=160,
    ),
    Case(
        name="cbcr_ac_m4_11_hi_cbneg_crneg",
        cb_mask=0x4,
        cr_mask=0xB,
        expected_final_slice="0000000141d008086b3abee93df1ef57fdb4ff6fe9e7",
        expected_cavlc_suppressed_bits=292,
        expected_y_sad=EXPECTED_Y_SAD,
        expected_u_sad=256,
        expected_v_sad=768,
        cb_sample_value=96,
        cr_sample_value=96,
    ),
    Case(
        name="cbcr_ac_m13_2_hi",
        cb_mask=0xD,
        cr_mask=0x2,
        expected_final_slice="0000000141d008086b3afefb79d7d7f7bfbcff6eef",
        expected_cavlc_suppressed_bits=296,
        expected_y_sad=EXPECTED_Y_SAD,
        expected_u_sad=768,
        expected_v_sad=256,
        cb_sample_value=160,
        cr_sample_value=160,
    ),
    Case(
        name="cbcr_ac_m13_2_hi_cbpos_crneg",
        cb_mask=0xD,
        cr_mask=0x2,
        expected_final_slice="0000000141d008086b3afefb79d7d7f7bfbcff6eef",
        expected_cavlc_suppressed_bits=294,
        expected_y_sad=EXPECTED_Y_SAD,
        expected_u_sad=768,
        expected_v_sad=256,
        cb_sample_value=160,
        cr_sample_value=96,
    ),
    Case(
        name="cbcr_ac_m13_2_hi_cbneg_crpos",
        cb_mask=0xD,
        cr_mask=0x2,
        expected_final_slice="0000000141d008086b3afefb31d7d7d73dbcf7edef",
        expected_cavlc_suppressed_bits=294,
        expected_y_sad=EXPECTED_Y_SAD,
        expected_u_sad=768,
        expected_v_sad=256,
        cb_sample_value=96,
        cr_sample_value=160,
    ),
    Case(
        name="cbcr_ac_m13_2_hi_cbneg_crneg",
        cb_mask=0xD,
        cr_mask=0x2,
        expected_final_slice="0000000141d008086b3afefb31d7d7d73dbcf7edef",
        expected_cavlc_suppressed_bits=292,
        expected_y_sad=EXPECTED_Y_SAD,
        expected_u_sad=768,
        expected_v_sad=256,
        cb_sample_value=96,
        cr_sample_value=96,
    ),
    Case(
        name="cbcr_ac_m2_13_hi",
        cb_mask=0x2,
        cr_mask=0xD,
        expected_final_slice="0000000141d008086b3ab6ed3ff4455f3fbcf76efb15",
        expected_cavlc_suppressed_bits=296,
        expected_y_sad=EXPECTED_Y_SAD,
        expected_u_sad=256,
        expected_v_sad=768,
        cb_sample_value=160,
        cr_sample_value=160,
    ),
    Case(
        name="cbcr_ac_m2_13_hi_cbpos_crneg",
        cb_mask=0x2,
        cr_mask=0xD,
        expected_final_slice="0000000141d008086b3ab6ed3ff4457fbfbcf7fcef15",
        expected_cavlc_suppressed_bits=294,
        expected_y_sad=EXPECTED_Y_SAD,
        expected_u_sad=256,
        expected_v_sad=768,
        cb_sample_value=160,
        cr_sample_value=96,
    ),
    Case(
        name="cbcr_ac_m2_13_hi_cbneg_crpos",
        cb_mask=0x2,
        cr_mask=0xD,
        expected_final_slice="0000000141d008086b3ab6f9bbf4455f3fbcf76efb00",
        expected_cavlc_suppressed_bits=294,
        expected_y_sad=EXPECTED_Y_SAD,
        expected_u_sad=256,
        expected_v_sad=768,
        cb_sample_value=96,
        cr_sample_value=160,
    ),
    Case(
        name="cbcr_ac_m2_13_hi_cbneg_crneg",
        cb_mask=0x2,
        cr_mask=0xD,
        expected_final_slice="0000000141d008086b3ab6f9bbf4457fbfbcf7fced00",
        expected_cavlc_suppressed_bits=292,
        expected_y_sad=EXPECTED_Y_SAD,
        expected_u_sad=256,
        expected_v_sad=768,
        cb_sample_value=96,
        cr_sample_value=96,
    ),
    Case(
        name="cbcr_ac_m3_12",
        cb_mask=0x3,
        cr_mask=0xC,
        expected_final_slice="0000000141d008086b3abfe97ff9",
        expected_cavlc_suppressed_bits=196,
        expected_y_sad=EXPECTED_Y_SAD,
        expected_u_sad=128,
        expected_v_sad=128,
    ),
    Case(
        name="cbcr_ac_m12_3",
        cb_mask=0xC,
        cr_mask=0x3,
        expected_final_slice="0000000141d008086b3ab6ed33f7",
        expected_cavlc_suppressed_bits=196,
        expected_y_sad=EXPECTED_Y_SAD,
        expected_u_sad=128,
        expected_v_sad=128,
    ),
    Case(
        name="cbcr_ac_m5_10",
        cb_mask=0x5,
        cr_mask=0xA,
        expected_final_slice="0000000141d008086b3abfebb1d8",
        expected_cavlc_suppressed_bits=192,
        expected_y_sad=EXPECTED_Y_SAD,
        expected_u_sad=128,
        expected_v_sad=128,
    ),
    Case(
        name="cbcr_ac_m10_5",
        cb_mask=0xA,
        cr_mask=0x5,
        expected_final_slice="0000000141d008086b3abfff31d8",
        expected_cavlc_suppressed_bits=192,
        expected_y_sad=EXPECTED_Y_SAD,
        expected_u_sad=128,
        expected_v_sad=128,
    ),
    Case(
        name="cbcr_ac_m3_12_hi",
        cb_mask=0x3,
        cr_mask=0xC,
        expected_final_slice="0000000141d008086b3af6f9f3d6d5d77f74f7ff",
        expected_cavlc_suppressed_bits=301,
        expected_y_sad=EXPECTED_Y_SAD,
        expected_u_sad=512,
        expected_v_sad=512,
        cb_sample_value=160,
        cr_sample_value=160,
    ),
    Case(
        name="cbcr_ac_m3_12_hi_cbpos_crneg",
        cb_mask=0x3,
        cr_mask=0xC,
        expected_final_slice="0000000141d008086b3af6f9f3d6d5d77f7df77f",
        expected_cavlc_suppressed_bits=298,
        expected_y_sad=EXPECTED_Y_SAD,
        expected_u_sad=512,
        expected_v_sad=512,
        cb_sample_value=160,
        cr_sample_value=96,
    ),
    Case(
        name="cbcr_ac_m3_12_hi_cbneg_crpos",
        cb_mask=0x3,
        cr_mask=0xC,
        expected_final_slice="0000000141d008086b3abfebf3d245577f74f7ff",
        expected_cavlc_suppressed_bits=300,
        expected_y_sad=EXPECTED_Y_SAD,
        expected_u_sad=512,
        expected_v_sad=512,
        cb_sample_value=96,
        cr_sample_value=160,
    ),
    Case(
        name="cbcr_ac_m3_12_hi_cbneg_crneg",
        cb_mask=0x3,
        cr_mask=0xC,
        expected_final_slice="0000000141d008086b3abfebf3d245577f7df77f",
        expected_cavlc_suppressed_bits=297,
        expected_y_sad=EXPECTED_Y_SAD,
        expected_u_sad=512,
        expected_v_sad=512,
        cb_sample_value=96,
        cr_sample_value=96,
    ),
    Case(
        name="cbcr_ac_m12_3_hi",
        cb_mask=0xC,
        cr_mask=0x3,
        expected_final_slice="0000000141d008086b3abffbf9fb775ffdf6fffe",
        expected_cavlc_suppressed_bits=301,
        expected_y_sad=EXPECTED_Y_SAD,
        expected_u_sad=512,
        expected_v_sad=512,
        cb_sample_value=160,
        cr_sample_value=160,
    ),
    Case(
        name="cbcr_ac_m12_3_hi_cbpos_crneg",
        cb_mask=0xC,
        cr_mask=0x3,
        expected_final_slice="0000000141d008086b3abffbf9fb775ffdb4fffe",
        expected_cavlc_suppressed_bits=300,
        expected_y_sad=EXPECTED_Y_SAD,
        expected_u_sad=512,
        expected_v_sad=512,
        cb_sample_value=160,
        cr_sample_value=96,
    ),
    Case(
        name="cbcr_ac_m12_3_hi_cbneg_crpos",
        cb_mask=0xC,
        cr_mask=0x3,
        expected_final_slice="0000000141d008086b3abfebf9f94f7ffdf6fffe",
        expected_cavlc_suppressed_bits=298,
        expected_y_sad=EXPECTED_Y_SAD,
        expected_u_sad=512,
        expected_v_sad=512,
        cb_sample_value=96,
        cr_sample_value=160,
    ),
    Case(
        name="cbcr_ac_m12_3_hi_cbneg_crneg",
        cb_mask=0xC,
        cr_mask=0x3,
        expected_final_slice="0000000141d008086b3abfebf9f94f7ffdb4fffe",
        expected_cavlc_suppressed_bits=297,
        expected_y_sad=EXPECTED_Y_SAD,
        expected_u_sad=512,
        expected_v_sad=512,
        cb_sample_value=96,
        cr_sample_value=96,
    ),
    Case(
        name="cbcr_ac_m5_10_hi",
        cb_mask=0x5,
        cr_mask=0xA,
        expected_final_slice="0000000141d008086b3af6fdf3d6ef57fdfdf7ef",
        expected_cavlc_suppressed_bits=297,
        expected_y_sad=EXPECTED_Y_SAD,
        expected_u_sad=512,
        expected_v_sad=512,
        cb_sample_value=160,
        cr_sample_value=160,
    ),
    Case(
        name="cbcr_ac_m5_10_hi_cbpos_crneg",
        cb_mask=0x5,
        cr_mask=0xA,
        expected_final_slice="0000000141d008086b3af6fdf3d6ef77fd34f77c",
        expected_cavlc_suppressed_bits=294,
        expected_y_sad=EXPECTED_Y_SAD,
        expected_u_sad=512,
        expected_v_sad=512,
        cb_sample_value=160,
        cr_sample_value=96,
    ),
    Case(
        name="cbcr_ac_m5_10_hi_cbneg_crpos",
        cb_mask=0x5,
        cr_mask=0xA,
        expected_final_slice="0000000141d008086b3affedf3d26557fdfdf7ef",
        expected_cavlc_suppressed_bits=296,
        expected_y_sad=EXPECTED_Y_SAD,
        expected_u_sad=512,
        expected_v_sad=512,
        cb_sample_value=96,
        cr_sample_value=160,
    ),
    Case(
        name="cbcr_ac_m5_10_hi_cbneg_crneg",
        cb_mask=0x5,
        cr_mask=0xA,
        expected_final_slice="0000000141d008086b3affedf3d25ff7fd34f77c",
        expected_cavlc_suppressed_bits=293,
        expected_y_sad=EXPECTED_Y_SAD,
        expected_u_sad=512,
        expected_v_sad=512,
        cb_sample_value=96,
        cr_sample_value=96,
    ),
    Case(
        name="cbcr_ac_m10_5_hi",
        cb_mask=0xA,
        cr_mask=0x5,
        expected_final_slice="0000000141d008086b3abefffdf5ff57fdfdf7ef",
        expected_cavlc_suppressed_bits=297,
        expected_y_sad=EXPECTED_Y_SAD,
        expected_u_sad=512,
        expected_v_sad=512,
        cb_sample_value=160,
        cr_sample_value=160,
    ),
    Case(
        name="cbcr_ac_m10_5_hi_cbpos_crneg",
        cb_mask=0xA,
        cr_mask=0x5,
        expected_final_slice="0000000141d008086b3abefffdf5fffffd37fffdff",
        expected_cavlc_suppressed_bits=296,
        expected_y_sad=EXPECTED_Y_SAD,
        expected_u_sad=512,
        expected_v_sad=512,
        cb_sample_value=160,
        cr_sample_value=96,
    ),
    Case(
        name="cbcr_ac_m10_5_hi_cbneg_crpos",
        cb_mask=0xA,
        cr_mask=0x5,
        expected_final_slice="0000000141d008086b3af7fdfdf4c777fdfdf7ef",
        expected_cavlc_suppressed_bits=294,
        expected_y_sad=EXPECTED_Y_SAD,
        expected_u_sad=512,
        expected_v_sad=512,
        cb_sample_value=96,
        cr_sample_value=160,
    ),
    Case(
        name="cbcr_ac_m10_5_hi_cbneg_crneg",
        cb_mask=0xA,
        cr_mask=0x5,
        expected_final_slice="0000000141d008086b3af7fdfdf4c75ffd37fffdfe",
        expected_cavlc_suppressed_bits=293,
        expected_y_sad=EXPECTED_Y_SAD,
        expected_u_sad=512,
        expected_v_sad=512,
        cb_sample_value=96,
        cr_sample_value=96,
    ),
    Case(
        name="cbcr_ac_m14_1_hi",
        cb_mask=0xE,
        cr_mask=0x1,
        expected_final_slice="0000000141d008086b3ab7ebbddfd7f7fdfef7eeff",
        expected_cavlc_suppressed_bits=298,
        expected_y_sad=EXPECTED_Y_SAD,
        expected_u_sad=768,
        expected_v_sad=256,
        cb_sample_value=160,
        cr_sample_value=160,
    ),
    Case(
        name="cbcr_ac_m14_1_hi_cbpos_crneg",
        cb_mask=0xE,
        cr_mask=0x1,
        expected_final_slice="0000000141d008086b3ab7ebbddfd7f7fdfef7eeff",
        expected_cavlc_suppressed_bits=298,
        expected_y_sad=EXPECTED_Y_SAD,
        expected_u_sad=768,
        expected_v_sad=256,
        cb_sample_value=160,
        cr_sample_value=96,
    ),
    Case(
        name="cbcr_ac_m14_1_hi_cbneg_crpos",
        cb_mask=0xE,
        cr_mask=0x1,
        expected_final_slice="0000000141d008086b3ab7e9f9ffd7d77ffeff6eff",
        expected_cavlc_suppressed_bits=294,
        expected_y_sad=EXPECTED_Y_SAD,
        expected_u_sad=768,
        expected_v_sad=256,
        cb_sample_value=96,
        cr_sample_value=160,
    ),
    Case(
        name="cbcr_ac_m14_1_hi_cbneg_crneg",
        cb_mask=0xE,
        cr_mask=0x1,
        expected_final_slice="0000000141d008086b3ab7e9f9ffd7d77ffeff6eff",
        expected_cavlc_suppressed_bits=294,
        expected_y_sad=EXPECTED_Y_SAD,
        expected_u_sad=768,
        expected_v_sad=256,
        cb_sample_value=96,
        cr_sample_value=96,
    ),
    Case(
        name="cbcr_ac_m1_14_hi",
        cb_mask=0x1,
        cr_mask=0xE,
        expected_final_slice="0000000141d008086b3af6f9b5f7d7f7bfbcff6def",
        expected_cavlc_suppressed_bits=298,
        expected_y_sad=EXPECTED_Y_SAD,
        expected_u_sad=256,
        expected_v_sad=768,
        cb_sample_value=160,
        cr_sample_value=160,
    ),
    Case(
        name="cbcr_ac_m1_14_hi_cbpos_crneg",
        cb_mask=0x1,
        cr_mask=0xE,
        expected_final_slice="0000000141d008086b3af6f9b5f7d7d73dbcf7efef",
        expected_cavlc_suppressed_bits=294,
        expected_y_sad=EXPECTED_Y_SAD,
        expected_u_sad=256,
        expected_v_sad=768,
        cb_sample_value=160,
        cr_sample_value=96,
    ),
    Case(
        name="cbcr_ac_m1_14_hi_cbneg_crpos",
        cb_mask=0x1,
        cr_mask=0xE,
        expected_final_slice="0000000141d008086b3af6e9b1f7d7f7bfbcff6def",
        expected_cavlc_suppressed_bits=298,
        expected_y_sad=EXPECTED_Y_SAD,
        expected_u_sad=256,
        expected_v_sad=768,
        cb_sample_value=96,
        cr_sample_value=160,
    ),
    Case(
        name="cbcr_ac_m1_14_hi_cbneg_crneg",
        cb_mask=0x1,
        cr_mask=0xE,
        expected_final_slice="0000000141d008086b3af6e9b1f7d7d73dbcf7efef",
        expected_cavlc_suppressed_bits=294,
        expected_y_sad=EXPECTED_Y_SAD,
        expected_u_sad=256,
        expected_v_sad=768,
        cb_sample_value=96,
        cr_sample_value=96,
    ),
)


def sparse_chroma(mask: int, sample_value: int = 136) -> bytes:
    data: list[int] = []
    for y in range(HEIGHT // 2):
        for x in range(WIDTH // 2):
            block = (y // 4) * 2 + (x // 4)
            if (mask >> block) & 1:
                data.append(sample_value if ((x + y) & 1) else 128)
            else:
                data.append(128)
    return bytes(data)


def make_fixture(case: Case) -> Path:
    data_dir = ROOT / "data"
    data_dir.mkdir(parents=True, exist_ok=True)
    path = data_dir / f"smoke_16x16_2f_cabac_p16x16_luma_sparse_{case.name}_residual.yuv"
    y0 = bytes([64]) * LUMA_SIZE
    flat_chroma = bytes([128]) * CHROMA_SIZE
    y1 = bytes([72]) * LUMA_SIZE
    path.write_bytes(
        y0
        + flat_chroma
        + flat_chroma
        + y1
        + sparse_chroma(case.cb_mask, case.cb_sample_value)
        + sparse_chroma(case.cr_mask, case.cr_sample_value)
    )
    print(f"[INFO] LUMA_SPARSE_CHROMA_RES {case.name} fixture {path.relative_to(ROOT)} size={path.stat().st_size}")
    return path


def build_baseline_sim() -> Path:
    workspace = Path(stage_workspace("h264_cabac_luma_sparse_chroma_residual_"))
    config = BuildConfig(
        width=WIDTH,
        height=HEIGHT,
        bit_depth=8,
        chroma_format_idc=1,
        jobs=int(os.environ.get("BUILD_JOBS", "1")),
        enable_idr_ipcm=1,
        ipcm_sad_threshold=0,
        enable_cabac_p16x16=1,
    )
    sim = Path(build_sim(workspace, config))
    print(f"[INFO] LUMA_SPARSE_CHROMA_RES workspace={workspace} sim={sim}")
    return sim


def run_sim(sim: Path, fixture: Path, case: Case) -> tuple[Path, str]:
    out_dir = ROOT / "output"
    out_dir.mkdir(parents=True, exist_ok=True)
    h264 = out_dir / f"cabac_p16x16_luma_sparse_{case.name}_residual.h264"
    sim_log = out_dir / f"validation_cabac_p16x16_luma_sparse_{case.name}_residual.sim.log"
    with sim_log.open("w", encoding="utf-8") as log:
        subprocess.run(
            [
                str(sim),
                "+frames=2",
                "+timeout=5000000",
                f"+input={fixture}",
                f"+output={h264}",
                "+idr_interval=12",
            ],
            cwd=ROOT,
            stdout=log,
            stderr=subprocess.STDOUT,
            check=True,
        )
    return h264, sim_log.read_text(encoding="utf-8", errors="replace")


def final_slice_hex(stream: bytes) -> str:
    last_start = stream.rfind(b"\x00\x00\x00\x01")
    if last_start < 0:
        raise SystemExit("[FAIL] LUMA_SPARSE_CHROMA_RES missing final Annex-B start code")
    return stream[last_start:].hex()


def decode_raw(h264: Path, case: Case) -> tuple[bytes, str]:
    with tempfile.NamedTemporaryFile(prefix=f"h264_luma_sparse_{case.name}_", suffix=".yuv", delete=False) as raw_tmp:
        raw_path = Path(raw_tmp.name)
    try:
        proc = subprocess.run(
            [
                "ffmpeg",
                "-y",
                "-v",
                "error",
                "-xerror",
                "-i",
                str(h264),
                "-f",
                "rawvideo",
                "-pix_fmt",
                "yuv420p",
                str(raw_path),
            ],
            cwd=ROOT,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            check=False,
        )
        raw = raw_path.read_bytes() if raw_path.exists() else b""
        return raw, proc.stderr.decode("utf-8", "replace")
    finally:
        raw_path.unlink(missing_ok=True)


def check_sim_log(text: str, case: Case) -> None:
    forbidden = "[CABAC_PSUBSET]"
    if forbidden in text:
        raise SystemExit(f"[FAIL] LUMA_SPARSE_CHROMA_RES {case.name} hit CABAC subset guard {forbidden}")
    for needle in (
        "cabac_p16x16_mbs=1",
        "cabac_chroma_mbs=1",
        "cabac_chroma_dc_mbs=0",
        "cabac_chroma_ac_mbs=1",
        f"cabac_chroma_cb_ac_mbs={case.expected_cb_ac_mbs}",
        f"cabac_chroma_cr_ac_mbs={case.expected_cr_ac_mbs}",
        f"cabac_chroma_cb_ac_blocks={case.expected_cb_ac_blocks}",
        f"cabac_chroma_cr_ac_blocks={case.expected_cr_ac_blocks}",
        f"cavlc_suppressed_bits={case.expected_cavlc_suppressed_bits}",
        (
            f"cb_ac_mbs={case.expected_cb_ac_mbs} cr_ac_mbs={case.expected_cr_ac_mbs} "
            f"cb_ac_blocks={case.expected_cb_ac_blocks} cr_ac_blocks={case.expected_cr_ac_blocks}"
        ),
    ):
        if needle not in text:
            raise SystemExit(f"[FAIL] LUMA_SPARSE_CHROMA_RES {case.name} sim log missing {needle}")


def check_decoded_planes(fixture: Path, raw: bytes, case: Case) -> tuple[int, int, int]:
    if len(raw) != EXPECTED_BYTES:
        raise SystemExit(f"[FAIL] LUMA_SPARSE_CHROMA_RES {case.name} decoded {len(raw)}/{EXPECTED_BYTES} bytes")
    src = fixture.read_bytes()
    if raw[:FRAME_SIZE] != src[:FRAME_SIZE]:
        raise SystemExit(f"[FAIL] LUMA_SPARSE_CHROMA_RES {case.name} changed the IDR reference frame")
    frame1 = FRAME_SIZE
    u0 = frame1 + LUMA_SIZE
    v0 = u0 + CHROMA_SIZE
    y_sad = sum(abs(raw[frame1 + i] - src[frame1 + i]) for i in range(LUMA_SIZE))
    u_sad = sum(abs(raw[u0 + i] - src[u0 + i]) for i in range(CHROMA_SIZE))
    v_sad = sum(abs(raw[v0 + i] - src[v0 + i]) for i in range(CHROMA_SIZE))
    expected = (case.expected_y_sad, case.expected_u_sad, case.expected_v_sad)
    actual = (y_sad, u_sad, v_sad)
    if actual != expected:
        raise SystemExit(f"[FAIL] LUMA_SPARSE_CHROMA_RES {case.name} SAD YUV={actual}, expected {expected}")
    u_block_sads = chroma_block_sads(raw, src, u0)
    v_block_sads = chroma_block_sads(raw, src, v0)
    expected_u_block_sad = abs(case.cb_sample_value - 128) * 8
    expected_v_block_sad = abs(case.cr_sample_value - 128) * 8
    expected_u_blocks = tuple(expected_u_block_sad if (case.cb_mask >> block) & 1 else 0 for block in range(4))
    expected_v_blocks = tuple(expected_v_block_sad if (case.cr_mask >> block) & 1 else 0 for block in range(4))
    if u_block_sads != expected_u_blocks or v_block_sads != expected_v_blocks:
        raise SystemExit(
            f"[FAIL] LUMA_SPARSE_CHROMA_RES {case.name} chroma-block SAD drift: "
            f"U={u_block_sads} V={v_block_sads}, expected U={expected_u_blocks} V={expected_v_blocks}"
        )
    return actual


def chroma_block_sads(raw: bytes, src: bytes, plane0: int) -> tuple[int, int, int, int]:
    sads: list[int] = []
    chroma_width = WIDTH // 2
    for block in range(4):
        bx = (block & 1) * 4
        by = (block >> 1) * 4
        sad = 0
        for y in range(4):
            for x in range(4):
                idx = plane0 + (by + y) * chroma_width + bx + x
                sad += abs(raw[idx] - src[idx])
        sads.append(sad)
    return (sads[0], sads[1], sads[2], sads[3])


def run_case(sim: Path, case: Case) -> None:
    fixture = make_fixture(case)
    h264, sim_text = run_sim(sim, fixture, case)
    check_sim_log(sim_text, case)

    final_slice = final_slice_hex(h264.read_bytes())
    if final_slice != case.expected_final_slice:
        raise SystemExit(
            f"[FAIL] LUMA_SPARSE_CHROMA_RES {case.name} final P-slice drifted:\n"
            f"  got      {final_slice}\n"
            f"  expected {case.expected_final_slice}"
        )

    raw, err = decode_raw(h264, case)
    if err.strip():
        raise SystemExit(f"[FAIL] LUMA_SPARSE_CHROMA_RES {case.name} strict FFmpeg log {err.strip()!r}")
    y_sad, u_sad, v_sad = check_decoded_planes(fixture, raw, case)
    print(
        f"[PASS] CABAC P16x16 luma+sparse {case.name} residual smoke strict-decodes "
        f"{len(raw)}/{EXPECTED_BYTES} bytes with cavlc_suppressed_bits={case.expected_cavlc_suppressed_bits}, "
        f"cb_ac_blocks={case.expected_cb_ac_blocks} cr_ac_blocks={case.expected_cr_ac_blocks}, "
        f"Y_SAD={y_sad} U_SAD={u_sad} V_SAD={v_sad}, sparse block locality locked, "
        f"final_slice={final_slice}"
    )


def main() -> int:
    sim = build_baseline_sim()
    for case in CASES:
        run_case(sim, case)
    print("[PASS] CABAC P16x16 luma plus sparse Cb/Cr chroma-AC residual smoke cases, including all single-plane quadrants, same-plane row/column pairs, same-quadrant, row-adjacent both directions, column-adjacent both directions, opposite-diagonal mixed-plane pairs, complementary two-block row/column mixed-plane pairs, default/high-amplitude same-mask row/diagonal controls, default all-but-one same-mask mirrors, high-amplitude same-quadrant pairs, reciprocal high-amplitude right-column/diagonal skew pairs, mirrored high-amplitude three-plus-one edge complements with mixed Cb/Cr signs, the single-right/three-right, middle-left/middle-right, and corner-left/corner-right all-but-one luma mirrors, and the high-amplitude complementary split-row/column +/-32 sign matrix, strict-decode with plane-local counters and per-block chroma locality")
    return 0


if __name__ == "__main__":
    sys.exit(main())
