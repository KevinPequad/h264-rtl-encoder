#!/usr/bin/env python3
"""Representative post-queue-init cross-plane chroma-AC strict-decode gate.

The checked-in CABAC core now uses the `cod_i_queue=-7` initializer.  Single-
plane Cb/Cr mask probes promote the complete nonzero 2x2 AC mask lattice; this
bounded mixed-plane gate makes sure representative Cb+Cr combinations also
strict-decode from the generated RTL stream with exact plane-local SAD instead
of relying on the older first-payload bytestream-substitution diagnostics.
"""

from __future__ import annotations

import os
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from scripts.rtl_runner import BuildConfig, build_sim, stage_workspace

WIDTH = HEIGHT = 16
FRAME_SIZE = WIDTH * HEIGHT * 3 // 2
LUMA_SIZE = WIDTH * HEIGHT
CHROMA_SIZE = WIDTH * HEIGHT // 4
EXPECTED_BYTES = FRAME_SIZE * 2
EXPECTED_HEADER_TAIL = 0x6B

# Representative cross-plane cases: sparse/sparse top-row, diagonal, split-row,
# a sparse Cb singleton plus two-block Cr row/column mix,
# sparse singleton mirror gaps, orthogonal axis-pair, one-vs-two-block row/axis pairs,
# bottom/top mirror pairs, bottom-row cross-corners,
# reciprocal diagonal singletons,
# sparse-Cb plus dense-Cr / dense-Cb plus sparse-Cr right-column and bottom-row
# controls, dense-Cr, dense-Cb, same-diagonal dense, complementary checker,
# asymmetric three-block, its reciprocal mirror, extra two-/three-block skew pairs,
# two-block off-diagonal, diagonal-skew, edge-adjacent reciprocal pairs, and
# checker/three-block cross-row complements,
# high-amplitude skew-pair sign partitions,
# asymmetric three-plus-one complements, default-amplitude singleton/three-block
# row-complement gaps, three-block reciprocal complements,
# all-but-one reciprocal complements including same-quadrant and adjacent
# singleton mirrors, the complete default-amplitude same-mask Cb/Cr lattice,
# and dense-both controls.  This is
# deliberately smaller than the full 15x15 lattice
# so the cron gate stays
# bounded while still covering the combinations that used to expose short-decode
# and wrong-plane quality failures before the `cod_i_queue=-7` promotion.
TAILS = {
    (0x1, 0x1): "0000000141d008086b3acbb8b517a9",
    (0x1, 0x2): "0000000141d008086b3acbb8b517b2",
    (0x1, 0x3): "0000000141d008086b3acc099da545ea4651",
    (0x1, 0x4): "0000000141d008086b3acbb8b51790",
    (0x1, 0x5): "0000000141d008086b3acc10be3269ea4654",
    (0x1, 0x6): "0000000141d008086b3acc0d9d1934f65924",
    (0x1, 0x8): "0000000141d008086b3acbb8b517a6",
    (0x1, 0x9): "0000000141d008086b3acc0d611934f5232b32",
    (0x1, 0xA): "0000000141d008086b3acc11363269ecb24a",
    (0x1, 0xC): "0000000141d008086b3acc0a2ea545e43924",
    (0x1, 0xD): "0000000141d008086b3acbf3269a7a91953e1d",
    (0x1, 0xE): "0000000141d008086b3acbf3269a7b2c9214bf",
    (0x2, 0x1): "0000000141d008086b3acbeb2d4098",
    (0x2, 0x2): "0000000141d008086b3acbeb2d409d",
    (0x2, 0x3): "0000000141d008086b3acc09a95b50261328",
    (0x2, 0x4): "0000000141d008086b3acbeb2d408a",
    (0x2, 0x5): "0000000141d008086b3acc10c842e8a71d253e",
    (0x2, 0x6): "0000000141d008086b3acc0da221745404ca",
    (0x2, 0x7): "0000000141d008086b3acbf5cad40984ca22ba",
    (0x2, 0x8): "0000000141d008086b3acbeb2d4097",
    (0x2, 0x9): "0000000141d008086b3acc0d662174538e92cc",
    (0x2, 0xA): "0000000141d008086b3acc114042e8a80995",
    (0x2, 0xC): "0000000141d008086b3acc0a3a5b50228892",
    (0x3, 0x1): "0000000141d008086b3acc61364743b092af",
    (0x3, 0x2): "0000000141d008086b3acc61364743b092b0",
    (0x3, 0x3): "0000000141d008086b3acc614c11ff50ec24abcc54",
    (0x3, 0x4): "0000000141d008086b3acc61364743b092aa",
    (0x3, 0x5): "0000000141d008086b3acc614deaff50ec24abcc56",
    (0x3, 0x6): "0000000141d008086b3acc614d1b6fa87612560a3a",
    (0x3, 0x7): "0000000141d008086b3acc614660267b092af3153900",
    (0x3, 0x8): "0000000141d008086b3acc61364743b092ae",
    (0x4, 0x1): "0000000141d008086b3acbdfe134e8",
    (0x4, 0x2): "0000000141d008086b3acbdfe134f0",
    (0x4, 0x3): "0000000141d008086b3acc09a6884d3a3a48",
    (0x4, 0x4): "0000000141d008086b3acbdfe134d3",
    (0x4, 0x5): "0000000141d008086b3acc10c5dda820832a",
    (0x4, 0x6): "0000000141d008086b3acc0da0eed410dc92",
    (0x5, 0x5): "0000000141d008086b3acc6f8c40ff5158a92c2c76",
    (0x5, 0x1): "0000000141d008086b3acc6f78d26962a4b0",
    (0x5, 0x2): "0000000141d008086b3acc6f78d26962a4b1",
    (0x5, 0x3): "0000000141d008086b3acc6f8a4eff5158a92c2c75",
    (0x5, 0x4): "0000000141d008086b3acc6f78d26962a4ad",
    (0x5, 0x6): "0000000141d008086b3acc6f8b636fa8ac54963915",
    (0x6, 0x1): "0000000141d008086b3acc693d717438412c72",
    (0x6, 0x2): "0000000141d008086b3acc693d717438412c96",
    (0x6, 0x3): "0000000141d008086b3acc6941211369fac656391500",
    (0x6, 0x5): "0000000141d008086b3acc69421b1369fac656391500",
    (0x6, 0x6): "0000000141d008086b3acc6941af25899e104b258e00",
    (0x6, 0x9): "0000000141d008086b3acc6941a435899e104b1c8a00",
    (0x6, 0xA): "0000000141d008086b3acc69422e0369fac6564b1d00",
    (0x9, 0x3): "0000000141d008086b3acc68c91f7fa8bed612b08a00",
    (0x9, 0xA): "0000000141d008086b3acc68ca2c6fa8bed612bbf500",
    (0x9, 0x6): "0000000141d008086b3acc68c9ae34745f6b095dfa00",
    (0x9, 0x9): "0000000141d008086b3acc68c9a344745f6b09584500",
    (0x3, 0x9): "0000000141d008086b3acc614d087fa8761255e62b00",
    (0xA, 0x6): "0000000141d008086b3acc707b65036a06ac2577ea00",
    (0xA, 0x9): "0000000141d008086b3acc707b52136a06ac25611500",
    (0xA, 0xB): "0000000141d008086b3acc70754bb5035612b08a9c0000",
    (0xB, 0xC): "0000000141d008086b3acc381659f43b092be455f100",
    (0xB, 0xA): "0000000141d008086b3acc38800753f7d92be4564d0000",
    (0xC, 0xC): "0000000141d008086b3acc626e3a52133cb094a23a",
    (0xC, 0xA): "0000000141d008086b3acc62701352133cb095dfab",
    (0xA, 0xC): "0000000141d008086b3acc707a7806d40d584a511d",
    (0xC, 0xB): "0000000141d008086b3acc6268ea84cf2c256115390000",
    (0xA, 0xA): "0000000141d008086b3acc707c6a06d40d584aefd500",
    (0x5, 0xA): "0000000141d008086b3acc6f8c66df5158a92c722b",
    (0xA, 0x5): "0000000141d008086b3acc707c4426d40d584ac22b",
    (0x7, 0xB): "0000000141d008086b3acc36849d0ec2488aacde0d00000300",
    (0xB, 0x7): "0000000141d008086b3acc36849d0ec24af9158f060000",
    (0x3, 0xC): "0000000141d008086b3acc614c3ad97438412009d5",
    (0xC, 0x3): "0000000141d008086b3acc626e1472133cb0958454",
    (0x5, 0xC): "0000000141d008086b3acc6f8a74df5158a92b61bf",
    (0xC, 0x5): "0000000141d008086b3acc626fed72133cb0958456",
    (0xA, 0x3): "0000000141d008086b3acc707a5226d40d584ac22a",
    (0x3, 0xA): "0000000141d008086b3acc614e10df50ec24ac1476",
    (0x3, 0xB): "0000000141d008086b3acc614660267b092af315390000",
    (0x6, 0xC): "0000000141d008086b3acc6941340369fac655f00a",
    (0xC, 0x6): "0000000141d008086b3acc626f1ca9099e584aefd5",
    (0x1, 0xF): "0000000141d008086b3acbf59d7451ccca22bad74d",
    (0x2, 0xF): "0000000141d008086b3acbf4ded3f999944575ae9b",
    (0x4, 0xF): "0000000141d008086b3acbf452ba2e8e9222bad74d",
    (0x8, 0xF): "0000000141d008086b3acbf3e7134c83288aeb5d37",
    (0x8, 0x1): "0000000141d008086b3acbe70e2699",
    (0x8, 0x2): "0000000141d008086b3acbe70e269b",
    (0x8, 0x3): "0000000141d008086b3acc09a85389a6419445",
    (0x4, 0x8): "0000000141d008086b3acbdfe134e5",
    (0x8, 0x4): "0000000141d008086b3acbe70e2692",
    (0x8, 0x5): "0000000141d008086b3acc10c77f89a641953e",
    (0x9, 0x1): "0000000141d008086b3acc68c06934fb584ac2",
    (0xA, 0x1): "0000000141d008086b3acc7072e2e8b20cab08",
    (0xC, 0x1): "0000000141d008086b3acc626291a872c256",
    (0xF, 0x1): "0000000141d008086b3acc332499ec2488aa9fedd3",
    (0xF, 0x2): "0000000141d008086b3acc332499ec2488aa9fedd7",
    (0xF, 0x4): "0000000141d008086b3acc332499ec2488aa9fedc0",
    (0xF, 0x8): "0000000141d008086b3acc332499ec2488aa9fedce",
    (0xF, 0xF): "0000000141d008086b7acc",
    (0x1, 0x7): "0000000141d008086b3acbf3269a7a91944575",
    (0x7, 0x1): "0000000141d008086b3acc332499ec2488aacd",
    (0x7, 0x7): "0000000141d008086b3acc36849d0ec2488aacde0d0000",
    (0x7, 0x8): "0000000141d008086b3acc332499ec2488aacd",
    (0x8, 0x7): "0000000141d008086b3acbf588e2699065115d",
    (0x8, 0x8): "0000000141d008086b3acbe70e269878",
    (0x1, 0xB): "0000000141d008086b3acbf3269a7a91944576",
    (0xB, 0x1): "0000000141d008086b3acc332499ec24af9158f0",
    (0x2, 0xB): "0000000141d008086b3acbf5cad40984ca22bb59",
    (0xB, 0x2): "0000000141d008086b3acc332499ec24af9159",
    (0xE, 0x1): "0000000141d008086b3acc3602d3f58ca1b3b4",
    (0xB, 0x4): "0000000141d008086b3acc35d57438412366ab",
    (0x4, 0xB): "0000000141d008086b3acbf516134e874fdcaa2d",
    (0xD, 0x2): "0000000141d008086b3acc33249a58a9214bf7",
    (0x2, 0xD): "0000000141d008086b3acbf5cad4097c4d2ada7d",
    (0xE, 0x2): "0000000141d008086b3acc3602d3f58ca1b3b5",
    (0x2, 0xE): "0000000141d008086b3acbf5cad409d6890a5f",
    (0xE, 0x4): "0000000141d008086b3acc3602d3f58ca1b3b3",
    (0x4, 0xE): "0000000141d008086b3acbf516134f04ca14bf",
    (0xD, 0xE): "0000000141d008086b3acc36849d158a9214bf7b590000",
    (0xE, 0xD): "0000000141d008086b3acc36b8ad3f58ca1b3b4eb300000300",
    (0x7, 0xD): "0000000141d008086b3acc36849d0ec2488aacde0d0000",
    (0xD, 0x7): "0000000141d008086b3acc36849d158a9214bf77060000",
    (0x7, 0xE): "0000000141d008086b3acc36849d0ec2488aace6b30000",
    (0xE, 0x7): "0000000141d008086b3acc36b8ad3f58ca1b3b4eb30000",
    (0xB, 0xB): "0000000141d008086b3acc36849d0ec24af9158f0600000300",
    (0xB, 0xD): "0000000141d008086b3acc36849d0ec24af9158f0600000300",
    (0xD, 0xD): "0000000141d008086b3acc36849d158a9214bf770600000300",
    (0xD, 0xB): "0000000141d008086b3acc36849d158a9214bf770600000300",
    (0xE, 0xE): "0000000141d008086b3acc36b8ad3f58ca1b3b57060000",
}

# Cross-plane high-amplitude guards.  The mask lattice above uses value 136
# (one checkerboard block contributes SAD=64).  Single-plane amplitude probes
# cover Cb-only/Cr-only value 160, but a combined Cb+Cr macroblock also needs a
# bounded guard because it shares residual level/sign contexts across both
# planes.  Keep this to targeted positive/mixed-sign Cb/Cr samples, plus
# high-amplitude three-plus-one-block and all-but-one/singleton complement
# guards.  For the former miss families, lock the complete +/-32 sign matrix
# that the promotion gate already proved so the representative cross-plane gate
# covers every targeted complement polarity without running the full 15x15 mask
# lattice.
AMPLITUDE_TAILS = {
    (0x5, 0xA, 160, 136): "0000000141d008086b",
    (0x5, 0xA, 136, 160): "0000000141d008086b",
    (0x5, 0xA, 160, 160): "0000000141d008086b7fff",
    (0x5, 0xA, 96, 136): "0000000141d008086b",
    (0x5, 0xA, 136, 96): "0000000141d008086b",
    (0xA, 0x5, 96, 136): "0000000141d008086b3acc6e110591f10a4804a1da00000300",
    (0xA, 0x5, 136, 96): "0000000141d008086b",
    (0xA, 0x5, 160, 136): "0000000141d008086b3acc6e451591f10a562921da00000300",
    (0xA, 0x5, 136, 160): "0000000141d008086b",
    (0xA, 0x5, 160, 160): "0000000141d008086b7bef",
    (0x3, 0x5, 96, 96): "0000000141d008086b7bfd",
    (0x3, 0x5, 160, 160): "0000000141d008086b3add",
    (0x3, 0x5, 160, 96): "0000000141d008086b7bfd",
    (0x3, 0x5, 96, 160): "0000000141d008086b3add",
    (0x5, 0x3, 160, 160): "0000000141d008086bbaff",
    (0x5, 0x3, 96, 96): "0000000141d008086b3eff",
    (0x5, 0x3, 160, 96): "0000000141d008086b3eff",
    (0x5, 0x3, 96, 160): "0000000141d008086bbaff",
    (0xC, 0x3, 160, 96): "0000000141d008086b3eff",
    (0xC, 0x3, 96, 96): "0000000141d008086b3eff",
    (0x6, 0x9, 96, 96): "0000000141d008086b7bfeef",
    (0x6, 0x9, 96, 160): "0000000141d008086b7ffeef",
    (0x6, 0x9, 160, 96): "0000000141d008086b7bfeef",
    (0x6, 0x9, 160, 160): "0000000141d008086b7ffeef",
    (0x9, 0x6, 160, 96): "0000000141d008086b3fdd7e",
    (0x9, 0x6, 96, 96): "0000000141d008086b3fdd7e",
    (0x9, 0x6, 160, 160): "0000000141d008086b7bef7e",
    (0x9, 0x6, 96, 160): "0000000141d008086b7bef7e",
    (0x5, 0x5, 160, 160): "0000000141d008086b3add",
    (0x5, 0x5, 96, 160): "0000000141d008086b3add",
    (0x5, 0x5, 160, 96): "0000000141d008086b7bfd",
    (0x5, 0x5, 96, 96): "0000000141d008086b7bfd",
    (0xC, 0x3, 96, 160): "0000000141d008086bbaff",
    (0xC, 0x3, 160, 160): "0000000141d008086bbaff",
    (0x3, 0xC, 160, 160): "0000000141d008086b3ffe",
    (0x3, 0xC, 96, 160): "0000000141d008086b3ffe",
    (0x3, 0xC, 160, 96): "0000000141d008086b7ede",
    (0x3, 0xC, 96, 96): "0000000141d008086b7ede",
    (0x2, 0xF, 160, 96): "0000000141d008086b3aff7dbfbe",
    (0x1, 0xE, 160, 160): "0000000141d008086b3bcdfd",
    (0x1, 0xE, 96, 160): "0000000141d008086b3bcdfd",
    (0x1, 0xE, 160, 96): "0000000141d008086b3add75",
    (0x1, 0xE, 96, 96): "0000000141d008086b3add75",
    (0xE, 0x1, 160, 160): "0000000141d008086b7edd7ff6",
    (0xE, 0x1, 96, 160): "0000000141d008086b7fecfff7",
    (0xE, 0x1, 160, 96): "0000000141d008086b7edd7ff6",
    (0xE, 0x1, 96, 96): "0000000141d008086b7fecfff7",
    (0xD, 0x2, 160, 160): "0000000141d008086b3addf5",
    (0xD, 0x2, 96, 160): "0000000141d008086b3bed75",
    (0xD, 0x2, 160, 96): "0000000141d008086b3addf5",
    (0xD, 0x2, 96, 96): "0000000141d008086b3bed75",
    (0x2, 0xD, 160, 160): "0000000141d008086b3aec7fe6",
    (0x2, 0xD, 96, 160): "0000000141d008086b3aec7f7c",
    (0x2, 0xD, 160, 96): "0000000141d008086b3adefda6",
    (0x2, 0xD, 96, 96): "0000000141d008086b3adefdfc",
    (0xB, 0x4, 160, 160): "0000000141d008086b7fcf7f7b",
    (0xB, 0x4, 96, 160): "0000000141d008086b7edef7fa",
    (0xB, 0x4, 160, 96): "0000000141d008086b7fcf7f7b",
    (0xB, 0x4, 96, 96): "0000000141d008086b7edef7fa",
    (0x4, 0xB, 160, 160): "0000000141d008086b3bcf7fbf",
    (0x4, 0xB, 96, 160): "0000000141d008086b3bcf7f7f",
    (0x4, 0xB, 160, 96): "0000000141d008086b3becf5bf",
    (0x4, 0xB, 96, 96): "0000000141d008086b3becf57f",
    (0x7, 0x8, 160, 160): "0000000141d008086b7eddf5ff",
    (0x7, 0x8, 96, 160): "0000000141d008086b7bce757f",
    (0x7, 0x8, 160, 96): "0000000141d008086b7eddf5ff",
    (0x7, 0x8, 96, 96): "0000000141d008086b7bce757f",
    (0x8, 0x7, 160, 160): "0000000141d008086b7fcdff",
    (0x8, 0x7, 96, 160): "0000000141d008086b7fcdff",
    (0x8, 0x7, 160, 96): "0000000141d008086b7eddf7",
    (0x8, 0x7, 96, 96): "0000000141d008086b7eddf7",
}

# Split-row Cb0x3/Cr0xC and adjacent skew-pair high-amplitude polarity coverage
# are promoted by the scoped plane-local CBF walk in h264_bitstream.v.  Keep the
# skew-pair expected-miss harness present but empty so the audit can distinguish
# those closed directions from unrelated bounded negative controls.
EXPECTED_MISSES = {}

# High-amplitude same-mask checker coverage used to short-decode after only the
# IDR frame; keep the promoted +/-32 sign matrix in AMPLITUDE_TAILS so it cannot
# drift back to the old one-frame bytestream -23 miss.
SAME_MASK_EXPECTED_MISSES = {}


def checker_chroma(mask: int, value: int = 136) -> bytes:
    out = []
    for y in range(HEIGHT // 2):
        for x in range(WIDTH // 2):
            block = (1 if x >= 4 else 0) + (2 if y >= 4 else 0)
            out.append(value if ((mask >> block) & 1 and ((x + y) % 2)) else 128)
    return bytes(out)


def make_fixture(cb_mask: int, cr_mask: int, cb_value: int = 136, cr_value: int = 136) -> Path:
    y0 = bytes([64]) * LUMA_SIZE
    y1 = bytes([64]) * LUMA_SIZE
    flat = bytes([128]) * CHROMA_SIZE
    data_dir = ROOT / "data"
    data_dir.mkdir(parents=True, exist_ok=True)
    value_suffix = "" if (cb_value == 136 and cr_value == 136) else f"_cbv{cb_value}_crv{cr_value}"
    path = data_dir / (
        "smoke_16x16_2f_cabac_p16x16_chroma_residual_"
        f"cbcr_ac_first_payload_cross_cb{cb_mask:x}_cr{cr_mask:x}{value_suffix}.yuv"
    )
    path.write_bytes(
        y0 + flat + flat + y1 + checker_chroma(cb_mask, cb_value) + checker_chroma(cr_mask, cr_value)
    )
    print(
        f"[INFO] CROSS_PLANE_AC cb=0x{cb_mask:x} cr=0x{cr_mask:x} "
        f"cb_value={cb_value} cr_value={cr_value} "
        f"fixture {path} size={path.stat().st_size}"
    )
    return path


def decode_raw(h264: Path) -> tuple[bytes, str]:
    with tempfile.NamedTemporaryFile(prefix="h264_cross_plane_ac_", suffix=".yuv", delete=False) as raw_tmp:
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
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            check=False,
        )
        raw = raw_path.read_bytes() if raw_path.exists() else b""
        return raw, proc.stderr.decode("utf-8", "replace")
    finally:
        raw_path.unlink(missing_ok=True)


def build_baseline_sim() -> Path:
    workspace = Path(stage_workspace("h264_cabac_cross_plane_ac_"))
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
    print(f"[INFO] CROSS_PLANE_AC workspace={workspace} sim={sim}")
    return sim


def final_slice_hex(stream: bytes, label: str) -> str:
    last_start = stream.rfind(b"\x00\x00\x00\x01")
    if last_start < 0:
        raise SystemExit(f"[FAIL] CROSS_PLANE_AC {label} missing final Annex-B start code")
    header_tail_idx = last_start + 8
    if header_tail_idx >= len(stream):
        raise SystemExit(f"[FAIL] CROSS_PLANE_AC {label} final slice too short")
    if stream[header_tail_idx] != EXPECTED_HEADER_TAIL:
        raise SystemExit(
            f"[FAIL] CROSS_PLANE_AC {label} header tail 0x{stream[header_tail_idx]:02x}, "
            f"expected 0x{EXPECTED_HEADER_TAIL:02x}"
        )
    return stream[last_start:].hex()


def run_case(sim: Path, cb_mask: int, cr_mask: int, fixture: Path, cb_value: int = 136, cr_value: int = 136) -> Path:
    out_dir = ROOT / "output" / "cabac_cross_plane_ac_probe"
    out_dir.mkdir(parents=True, exist_ok=True)
    value_suffix = "" if (cb_value == 136 and cr_value == 136) else f"_cbv{cb_value}_crv{cr_value}"
    case_name = f"cb{cb_mask:x}_cr{cr_mask:x}{value_suffix}"
    h264 = out_dir / f"{case_name}.h264"
    sim_log = out_dir / f"{case_name}.sim.log"
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
    sim_text = sim_log.read_text(encoding="utf-8", errors="replace")
    for needle in (
        "cabac_p16x16_mbs=1",
        "cb_ac_mbs=1",
        "cr_ac_mbs=1",
        f"cb_ac_blocks={cb_mask.bit_count()}",
        f"cr_ac_blocks={cr_mask.bit_count()}",
    ):
        if needle not in sim_text:
            raise SystemExit(f"[FAIL] CROSS_PLANE_AC cb=0x{cb_mask:x} cr=0x{cr_mask:x} sim log missing {needle}")
    if "cavlc_suppressed_bits=" not in sim_text:
        raise SystemExit(f"[FAIL] CROSS_PLANE_AC cb=0x{cb_mask:x} cr=0x{cr_mask:x} did not suppress legacy CAVLC")
    return h264


def assert_planes(
    cb_mask: int,
    cr_mask: int,
    fixture: Path,
    raw: bytes,
    cb_value: int = 136,
    cr_value: int = 136,
) -> tuple[int, int]:
    if len(raw) != EXPECTED_BYTES:
        raise SystemExit(
            f"[FAIL] CROSS_PLANE_AC cb=0x{cb_mask:x} cr=0x{cr_mask:x} decoded {len(raw)}/{EXPECTED_BYTES}"
        )
    src = fixture.read_bytes()
    if raw[:FRAME_SIZE] != src[:FRAME_SIZE]:
        raise SystemExit(f"[FAIL] CROSS_PLANE_AC cb=0x{cb_mask:x} cr=0x{cr_mask:x} changed IDR reference")
    u0 = FRAME_SIZE + LUMA_SIZE
    v0 = u0 + CHROMA_SIZE
    u_sad = sum(abs(raw[u0 + i] - src[u0 + i]) for i in range(CHROMA_SIZE))
    v_sad = sum(abs(raw[v0 + i] - src[v0 + i]) for i in range(CHROMA_SIZE))
    expected_u = cb_mask.bit_count() * 8 * abs(cb_value - 128)
    expected_v = cr_mask.bit_count() * 8 * abs(cr_value - 128)
    if u_sad != expected_u or v_sad != expected_v:
        raise SystemExit(
            f"[FAIL] CROSS_PLANE_AC cb=0x{cb_mask:x} cr=0x{cr_mask:x} "
            f"SAD U={u_sad} V={v_sad}, expected U={expected_u} V={expected_v}"
        )
    return u_sad, v_sad


def check_case(
    sim: Path,
    cb_mask: int,
    cr_mask: int,
    expected_tail: str,
    cb_value: int = 136,
    cr_value: int = 136,
) -> None:
    fixture = make_fixture(cb_mask, cr_mask, cb_value, cr_value)
    h264 = run_case(sim, cb_mask, cr_mask, fixture, cb_value, cr_value)
    stream = h264.read_bytes()
    label = f"cb=0x{cb_mask:x} cr=0x{cr_mask:x} cb_value={cb_value} cr_value={cr_value}"
    tail = final_slice_hex(stream, label)
    if tail != expected_tail:
        raise SystemExit(
            f"[FAIL] CROSS_PLANE_AC {label} tail drift {tail}, expected {expected_tail}"
        )
    raw, err = decode_raw(h264)
    if err.strip():
        raise SystemExit(f"[FAIL] CROSS_PLANE_AC {label} FFmpeg log {err.strip()!r}")
    u_sad, v_sad = assert_planes(cb_mask, cr_mask, fixture, raw, cb_value, cr_value)
    print(
        f"[PASS] CROSS_PLANE_AC cb=0x{cb_mask:x} cr=0x{cr_mask:x} "
        f"cb_value={cb_value} cr_value={cr_value} strict-decodes "
        f"{len(raw)}/{EXPECTED_BYTES} U_SAD={u_sad} V_SAD={v_sad} tail={tail}"
    )


def check_expected_miss(
    sim: Path,
    cb_mask: int,
    cr_mask: int,
    cb_value: int,
    cr_value: int,
    expected_bytes: int,
    expected_signature: str,
    expected_tail: str,
) -> None:
    fixture = make_fixture(cb_mask, cr_mask, cb_value, cr_value)
    h264 = run_case(sim, cb_mask, cr_mask, fixture, cb_value, cr_value)
    stream = h264.read_bytes()
    label = f"cb=0x{cb_mask:x} cr=0x{cr_mask:x} cb_value={cb_value} cr_value={cr_value}"
    tail = final_slice_hex(stream, label)
    if tail != expected_tail:
        raise SystemExit(
            f"[FAIL] CROSS_PLANE_AC_EXPECTED_MISS {label} tail drift {tail}, expected {expected_tail}"
        )
    raw, err = decode_raw(h264)
    if len(raw) != expected_bytes:
        raise SystemExit(
            f"[FAIL] CROSS_PLANE_AC_EXPECTED_MISS {label} decoded {len(raw)}/{EXPECTED_BYTES}, "
            f"expected {expected_bytes}/{EXPECTED_BYTES}"
        )
    if expected_signature not in err:
        raise SystemExit(
            f"[FAIL] CROSS_PLANE_AC_EXPECTED_MISS {label} FFmpeg signature {err.strip()!r}, "
            f"expected to contain {expected_signature!r}"
        )
    src = fixture.read_bytes()
    if raw and raw[:FRAME_SIZE] != src[:FRAME_SIZE]:
        raise SystemExit(f"[FAIL] CROSS_PLANE_AC_EXPECTED_MISS {label} changed IDR reference")
    print(
        f"[PASS] CROSS_PLANE_AC_EXPECTED_MISS {label} remains scoped to "
        f"{len(raw)}/{EXPECTED_BYTES} decoded bytes, signature={expected_signature!r}, tail={tail}"
    )


def main() -> int:
    sim = build_baseline_sim()
    for (cb_mask, cr_mask), tail in TAILS.items():
        check_case(sim, cb_mask, cr_mask, tail)
    for (cb_mask, cr_mask, cb_value, cr_value), tail in AMPLITUDE_TAILS.items():
        check_case(sim, cb_mask, cr_mask, tail, cb_value, cr_value)
    for (cb_mask, cr_mask, cb_value, cr_value), (expected_bytes, expected_signature, tail) in EXPECTED_MISSES.items():
        check_expected_miss(sim, cb_mask, cr_mask, cb_value, cr_value, expected_bytes, expected_signature, tail)
    for (cb_mask, cr_mask, cb_value, cr_value), (expected_bytes, expected_signature, tail) in SAME_MASK_EXPECTED_MISSES.items():
        check_expected_miss(sim, cb_mask, cr_mask, cb_value, cr_value, expected_bytes, expected_signature, tail)
    print(
        "[PASS] CABAC P16x16 cross-plane chroma-AC gate promoted: representative "
        "sparse/sparse, mirror, split-row, bottom-row cross-corner, "
        "sparse singleton mirror gaps, "
        "sparse Cb singleton plus two-block Cr row/column mix, "
        "orthogonal axis-pair, reciprocal diagonal singleton, "
        "one-vs-two-block row/axis pairs, "
        "sparse+dense right-column/bottom-row, same-diagonal dense, "
        "complementary checker, "
        "asymmetric three-block plus reciprocal mirror, extra two-/three-block skew pairs, "
        "two-block off-diagonal, diagonal-skew, edge-adjacent reciprocal pairs, "
        "checker/three-block cross-row complements, dense-Cb, dense-Cr, "
        "high-amplitude skew-pair sign partitions, "
        "asymmetric three-plus-one complements, default-amplitude singleton/three-block "
        "row-complement gaps, three-block reciprocal complements, "
        "all-but-one reciprocal complements, "
        "same-quadrant all-but-one/singleton mirrors, "
        "the complete default-amplitude same-mask Cb/Cr lattice, "
        "and dense-both Cb+Cr AC masks "
        "plus positive, reciprocal, mixed-sign, asymmetric complement, "
        "complete +/-32 sign matrices for the targeted all-but-one/singleton "
        "complement mirror families and the high-amplitude same-mask checker "
        "including the full Cb0x3/Cr0xC split-row sign matrix "
        "high-amplitude Cb/Cr guards strict-decode two frames with exact plane-local SAD under the "
        "checked-in -7 CABAC queue initializer, with no remaining skew-pair "
        "high-amplitude expected-miss directions and with the high-amplitude "
        "same-mask checker promoted in this bounded gate"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
