#!/usr/bin/env python3
"""First-payload value sweep for high-amplitude reciprocal Cb0xb/Cr0x4.

The B4 split-context diagnostics reject the simple Cr/Cb/both-plane payload-bank
extensions, while the first-payload substitution probe shows that changing only
the first CABAC residual payload byte promotes all four +/-32 endpoint streams.
This bounded sweep keeps the RTL stream unchanged except for that one byte and
locks the exact byte-value classes that strict-decode with the expected Cb/Cr
SAD.  It is diagnostic evidence for the CABAC arithmetic/renormalization
boundary, not a bytestream patching path.
"""

from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from scripts.run_cabac_p16x16_chroma_ac_b4_first_payload_substitution_probe import (  # noqa: E402
    BASELINE_CASES,
    CB_MASK,
    CR_MASK,
    decode_raw_bytes,
    first_payload_index,
)
from scripts.run_cabac_p16x16_chroma_ac_cross_plane_first_payload_probe import (  # noqa: E402
    EXPECTED_BYTES,
    assert_planes,
    build_baseline_sim,
    final_slice_hex,
    make_fixture,
    run_case,
)

KNOWN_PROMOTED = {0x6B, 0x75}

PASS_RANGES = {
    (160, 160): "0x00-0xa6,0xc5-0xc6,0xd2,0xed,0xef,0xf4-0xf5",
    (160, 96): "0x00-0xa6,0xc5-0xc6,0xd2,0xed,0xef,0xf4-0xf5",
    (96, 160): "0x00-0xa6,0xac,0xaf,0xb4,0xb8,0xc5,0xcd-0xce,0xd5,0xe8,0xeb,0xfc",
    (96, 96): "0x00-0xa6,0xac,0xaf,0xb4,0xb8,0xc5,0xcd-0xce,0xd5,0xe8,0xeb,0xfc",
}

PASS_COUNTS = {
    (160, 160): 174,
    (160, 96): 174,
    (96, 160): 178,
    (96, 96): 178,
}


def is_expected_decode(raw: bytes, err: str, fixture: Path, cb_value: int, cr_value: int) -> bool:
    if err.strip() or len(raw) != EXPECTED_BYTES:
        return False
    try:
        assert_planes(CB_MASK, CR_MASK, fixture, raw, cb_value, cr_value)
    except SystemExit:
        return False
    return True


def compact_ranges(values: list[int]) -> str:
    if not values:
        return ""
    ranges: list[str] = []
    start = prev = values[0]
    for value in values[1:]:
        if value == prev + 1:
            prev = value
            continue
        ranges.append(f"0x{start:02x}" if start == prev else f"0x{start:02x}-0x{prev:02x}")
        start = prev = value
    ranges.append(f"0x{start:02x}" if start == prev else f"0x{start:02x}-0x{prev:02x}")
    return ",".join(ranges)


def check_case(sim: Path, cb_value: int, cr_value: int) -> None:
    expected_first, expected_tail, expected_signature = BASELINE_CASES[(cb_value, cr_value)]
    label = f"cb=0x{CB_MASK:x} cr=0x{CR_MASK:x} cb_value={cb_value} cr_value={cr_value}"
    fixture = make_fixture(CB_MASK, CR_MASK, cb_value, cr_value)
    h264 = run_case(sim, CB_MASK, CR_MASK, fixture, cb_value, cr_value)
    stream = h264.read_bytes()
    tail = final_slice_hex(stream, label)
    if tail != expected_tail:
        raise SystemExit(f"[FAIL] B4_FIRST_PAYLOAD_VALUE {label} tail {tail}, expected {expected_tail}")
    first_idx = first_payload_index(stream, label, expected_first)

    pass_values: list[int] = []
    for value in range(256):
        mutated = bytearray(stream)
        mutated[first_idx] = value
        raw, err = decode_raw_bytes(bytes(mutated))
        if is_expected_decode(raw, err, fixture, cb_value, cr_value):
            pass_values.append(value)

    actual_ranges = compact_ranges(pass_values)
    expected_ranges = PASS_RANGES[(cb_value, cr_value)]
    if actual_ranges != expected_ranges:
        raise SystemExit(
            f"[FAIL] B4_FIRST_PAYLOAD_VALUE {label} pass-ranges drifted:\n"
            f"  got      {actual_ranges}\n"
            f"  expected {expected_ranges}"
        )
    expected_count = PASS_COUNTS[(cb_value, cr_value)]
    if len(pass_values) != expected_count:
        raise SystemExit(
            f"[FAIL] B4_FIRST_PAYLOAD_VALUE {label} pass-count {len(pass_values)}, "
            f"expected {expected_count}: {actual_ranges}"
        )

    pass_set = set(pass_values)
    if expected_first in pass_set:
        raise SystemExit(
            f"[FAIL] B4_FIRST_PAYLOAD_VALUE {label} baseline first payload 0x{expected_first:02x} "
            "unexpectedly strict-decodes"
        )
    if not KNOWN_PROMOTED.issubset(pass_set):
        raise SystemExit(
            f"[FAIL] B4_FIRST_PAYLOAD_VALUE {label} lost known promoted values "
            f"{sorted(KNOWN_PROMOTED - pass_set)}"
        )

    print(
        f"[PASS] B4_FIRST_PAYLOAD_VALUE {label}: baseline first=0x{expected_first:02x} "
        f"short/{expected_signature}, pass_count={len(pass_values)} ranges={actual_ranges}"
    )


def main() -> int:
    sim = build_baseline_sim()
    for cb_value, cr_value in BASELINE_CASES:
        check_case(sim, cb_value, cr_value)
    print(
        "[PASS] CABAC P16x16 high-amplitude Cb0xb/Cr0x4 first-payload value sweep "
        "locks exact promoted byte classes for all four +/-32 endpoints; baseline "
        "0xfe/0xff remains outside the strict-decode class while 0x6b/0x75 stay promoted."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
