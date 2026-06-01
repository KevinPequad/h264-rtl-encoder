#!/usr/bin/env python3
"""Bounded high-amplitude complementary-checker Cb+Cr chroma-AC sign probe.

The broad cross-plane gate keeps the promoted low/default-amplitude checker
complements (`Cb0x5/Cr0xA` and `Cb0xA/Cr0x5`) strict.  This focused probe locks
the current high-amplitude +/-32 sign partition so the remaining arithmetic
repair target is explicit: Cr-positive directions strict-decode, while
Cr-negative directions still short-decode from the RTL-produced stream.
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
    check_expected_miss,
    decode_raw,
    final_slice_hex,
    make_fixture,
    run_case,
)

# Full high-amplitude sign matrix for complementary checker masks.  Values 160
# and 96 are +32 and -32 around neutral chroma 128.
STRICT_TAILS = {
    (0x5, 0xA, 160, 160): "0000000141d008086b7fff",
    (0x5, 0xA, 96, 160): "0000000141d008086b7fff",
    (0xA, 0x5, 160, 160): "0000000141d008086b7bef",
    (0xA, 0x5, 96, 160): "0000000141d008086b7bef",
}

EXPECTED_MISSES = {
    (0x5, 0xA, 160, 96): (384, "bytestream -23", "0000000141d008086bbbff"),
    (0x5, 0xA, 96, 96): (384, "bytestream -23", "0000000141d008086bbbff"),
    (0xA, 0x5, 160, 96): (384, "bytestream -15", "0000000141d008086bbfef"),
    (0xA, 0x5, 96, 96): (384, "bytestream -15", "0000000141d008086bbfef"),
}


def check_strict(sim: Path, cb_mask: int, cr_mask: int, cb_value: int, cr_value: int, expected_tail: str) -> None:
    fixture = make_fixture(cb_mask, cr_mask, cb_value, cr_value)
    h264 = run_case(sim, cb_mask, cr_mask, fixture, cb_value, cr_value)
    stream = h264.read_bytes()
    label = f"cb=0x{cb_mask:x} cr=0x{cr_mask:x} cb_value={cb_value} cr_value={cr_value}"
    tail = final_slice_hex(stream, label)
    if tail != expected_tail:
        raise SystemExit(
            f"[FAIL] CHECKER_HIGH_AMP_SIGN {label} tail drift {tail}, expected {expected_tail}"
        )
    raw, err = decode_raw(h264)
    if err.strip():
        raise SystemExit(f"[FAIL] CHECKER_HIGH_AMP_SIGN {label} FFmpeg log {err.strip()!r}")
    if len(raw) != EXPECTED_BYTES:
        raise SystemExit(
            f"[FAIL] CHECKER_HIGH_AMP_SIGN {label} decoded {len(raw)}/{EXPECTED_BYTES}"
        )
    u_sad, v_sad = assert_planes(cb_mask, cr_mask, fixture, raw, cb_value, cr_value)
    print(
        f"[PASS] CHECKER_HIGH_AMP_SIGN {label} strict-decodes "
        f"{len(raw)}/{EXPECTED_BYTES} U_SAD={u_sad} V_SAD={v_sad} tail={tail}"
    )


def main() -> int:
    sim = build_baseline_sim()
    for (cb_mask, cr_mask, cb_value, cr_value), tail in STRICT_TAILS.items():
        check_strict(sim, cb_mask, cr_mask, cb_value, cr_value, tail)
    for (cb_mask, cr_mask, cb_value, cr_value), (expected_bytes, expected_signature, tail) in EXPECTED_MISSES.items():
        check_expected_miss(
            sim,
            cb_mask,
            cr_mask,
            cb_value,
            cr_value,
            expected_bytes,
            expected_signature,
            tail,
        )
    print(
        "[PASS] CABAC P16x16 complementary-checker high-amplitude sign probe "
        "locks Cr-positive strict-decode lanes and Cr-negative expected-miss "
        "lanes for Cb0x5/Cr0xA and Cb0xA/Cr0x5"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
