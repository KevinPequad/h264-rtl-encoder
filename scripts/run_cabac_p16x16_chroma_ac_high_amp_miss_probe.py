#!/usr/bin/env python3
"""Promotion gate for the former high-amplitude Cb0x2/Cr0xd chroma-AC miss.

The Cb singleton + Cr all-but-one high-amplitude complement used to short-decode
under the shared chroma-AC residual payload context bank.  The RTL now scopes a
separate Cr payload context bank to this mask pair; keep the exact promoted
strict-decode tails and plane-local SAD locked so the old negative probe cannot
silently regress.
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
    (0x2, 0xD, 160, 160): "0000000141d008086b3aec7fe6",
    (0x2, 0xD, 96, 160): "0000000141d008086b3aec7f7c",
    (0x2, 0xD, 160, 96): "0000000141d008086b3adefda6",
    (0x2, 0xD, 96, 96): "0000000141d008086b3adefdfc",
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
        "former Cb0x2/Cr0xd +/-32 complement misses now strict-decode with exact final-slice tails."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
