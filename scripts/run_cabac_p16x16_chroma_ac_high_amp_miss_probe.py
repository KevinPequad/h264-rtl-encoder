#!/usr/bin/env python3
"""Promotion gate for high-amplitude Cb/Cr chroma-AC complement guards.

The Cb singleton + Cr all-but-one high-amplitude complements used to short-decode
under the shared chroma-AC residual payload context bank.  The RTL now scopes a
separate Cr payload context bank to those target mask pairs, and the Cb0xb/Cr0x4
reciprocal has a narrow CBF-neighbour repair. Keep the exact promoted
strict-decode tails and plane-local SAD locked so the old negative probes cannot
silently regress into a different quadrant or direction.
"""

from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from scripts.run_cabac_p16x16_chroma_ac_cross_plane_first_payload_probe import (  # noqa: E402
    EXPECTED_BYTES,
    assert_planes,
    build_baseline_sim,
    decode_raw,
    final_slice_hex,
    make_fixture,
    run_case,
)

PROMOTED_CASES = {
    (0x1, 0xE, 160, 160): "0000000141d008086b3bcdfd",
    (0x1, 0xE, 96, 160): "0000000141d008086b3bcdfd",
    (0x1, 0xE, 160, 96): "0000000141d008086b3add75",
    (0x1, 0xE, 96, 96): "0000000141d008086b3add75",
    (0x2, 0xD, 160, 160): "0000000141d008086b3aec7fe6",
    (0x2, 0xD, 96, 160): "0000000141d008086b3aec7f7c",
    (0x2, 0xD, 160, 96): "0000000141d008086b3adefda6",
    (0x2, 0xD, 96, 96): "0000000141d008086b3adefdfc",
    (0x4, 0xB, 160, 160): "0000000141d008086b3bcf7fbf",
    (0x4, 0xB, 96, 160): "0000000141d008086b3bcf7f7f",
    (0x4, 0xB, 160, 96): "0000000141d008086b3becf5bf",
    (0x4, 0xB, 96, 96): "0000000141d008086b3becf57f",
    (0xB, 0x4, 160, 160): "0000000141d008086b7fcf7f7b",
    (0xB, 0x4, 160, 96): "0000000141d008086b7fcf7f7b",
    (0xB, 0x4, 96, 160): "0000000141d008086b7edef7fa",
    (0xB, 0x4, 96, 96): "0000000141d008086b7edef7fa",
    (0x8, 0x7, 160, 160): "0000000141d008086b7fcdff",
    (0x8, 0x7, 96, 160): "0000000141d008086b7fcdff",
    (0x8, 0x7, 160, 96): "0000000141d008086b7eddf7",
    (0x8, 0x7, 96, 96): "0000000141d008086b7eddf7",
    (0xE, 0x1, 160, 160): "0000000141d008086b7edd7ff6",
    (0xE, 0x1, 160, 96): "0000000141d008086b7edd7ff6",
    (0xE, 0x1, 96, 160): "0000000141d008086b7fecfff7",
    (0xE, 0x1, 96, 96): "0000000141d008086b7fecfff7",
    (0xD, 0x2, 160, 160): "0000000141d008086b3addf5",
    (0xD, 0x2, 160, 96): "0000000141d008086b3addf5",
    (0xD, 0x2, 96, 160): "0000000141d008086b3bed75",
    (0xD, 0x2, 96, 96): "0000000141d008086b3bed75",
    (0x7, 0x8, 160, 160): "0000000141d008086b7eddf5ff",
    (0x7, 0x8, 160, 96): "0000000141d008086b7eddf5ff",
    (0x7, 0x8, 96, 160): "0000000141d008086b7bce757f",
    (0x7, 0x8, 96, 96): "0000000141d008086b7bce757f",
}


def main() -> int:
    sim = build_baseline_sim()
    for (cb_mask, cr_mask, cb_value, cr_value), expected_tail in PROMOTED_CASES.items():
        label = f"cb=0x{cb_mask:x} cr=0x{cr_mask:x} cb_value={cb_value} cr_value={cr_value}"
        fixture = make_fixture(cb_mask, cr_mask, cb_value, cr_value)
        h264 = run_case(sim, cb_mask, cr_mask, fixture, cb_value, cr_value)
        stream = h264.read_bytes()
        tail = final_slice_hex(stream, label)
        if tail != expected_tail:
            raise SystemExit(f"[FAIL] CROSS_PLANE_HIGH_AMP_PROMOTION {label} tail {tail}, expected {expected_tail}")
        raw, err = decode_raw(h264)
        if err.strip():
            raise SystemExit(f"[FAIL] CROSS_PLANE_HIGH_AMP_PROMOTION {label} expected strict FFmpeg, got {err.strip()!r}")
        if len(raw) != EXPECTED_BYTES:
            raise SystemExit(
                f"[FAIL] CROSS_PLANE_HIGH_AMP_PROMOTION {label} decoded {len(raw)}/{EXPECTED_BYTES} bytes"
            )
        assert_planes(cb_mask, cr_mask, fixture, raw, cb_value, cr_value)
        print(
            f"[PASS] CROSS_PLANE_HIGH_AMP_PROMOTION {label}: strict two-frame decode, "
            f"tail={tail}, expected U/V SAD locked"
        )
    print(
        "[PASS] CABAC P16x16 cross-plane high-amplitude chroma-AC promotion gate: "
        "Cb singleton / Cr all-but-one +/-32 quadrant complements and reciprocal "
        "all-but-one / singleton shared-bank controls strict-decode with exact "
        "final-slice tails, including former shared-context misses."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
