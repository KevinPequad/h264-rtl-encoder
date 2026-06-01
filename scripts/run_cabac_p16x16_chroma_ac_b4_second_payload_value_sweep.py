#!/usr/bin/env python3
"""Second-payload value sweep for high-amplitude reciprocal Cb0xb/Cr0x4.

The first-payload value sweep shows that many single-byte substitutions of the
first residual payload byte can promote the remaining Cb-all-but-one / Cr-
singleton high-amplitude complement.  This companion sweep mutates only the
next CABAC residual payload byte after the locked first byte.  No second-byte
value strict-decodes the four +/-32 endpoint streams with expected Cb/Cr SAD,
which keeps the next source repair focused on the earlier arithmetic/
renormalization/output-byte state rather than a later single-byte tail patch.
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
from scripts.run_cabac_p16x16_chroma_ac_b4_first_payload_value_sweep import (  # noqa: E402
    compact_ranges,
    is_expected_decode,
)
from scripts.run_cabac_p16x16_chroma_ac_cross_plane_first_payload_probe import (  # noqa: E402
    build_baseline_sim,
    final_slice_hex,
    make_fixture,
    run_case,
)

BASELINE_SECOND_PAYLOADS = {
    (160, 160): 0xDF,
    (160, 96): 0xDF,
    (96, 160): 0xEF,
    (96, 96): 0xEF,
}

PASS_RANGES = {
    (160, 160): "",
    (160, 96): "",
    (96, 160): "",
    (96, 96): "",
}

PASS_COUNTS = {
    (160, 160): 0,
    (160, 96): 0,
    (96, 160): 0,
    (96, 96): 0,
}


def check_case(sim: Path, cb_value: int, cr_value: int) -> None:
    expected_first, expected_tail, expected_signature = BASELINE_CASES[(cb_value, cr_value)]
    expected_second = BASELINE_SECOND_PAYLOADS[(cb_value, cr_value)]
    label = f"cb=0x{CB_MASK:x} cr=0x{CR_MASK:x} cb_value={cb_value} cr_value={cr_value}"
    fixture = make_fixture(CB_MASK, CR_MASK, cb_value, cr_value)
    h264 = run_case(sim, CB_MASK, CR_MASK, fixture, cb_value, cr_value)
    stream = h264.read_bytes()
    tail = final_slice_hex(stream, label)
    if tail != expected_tail:
        raise SystemExit(f"[FAIL] B4_SECOND_PAYLOAD_VALUE {label} tail {tail}, expected {expected_tail}")
    first_idx = first_payload_index(stream, label, expected_first)
    second_idx = first_idx + 1
    if second_idx >= len(stream):
        raise SystemExit(f"[FAIL] B4_SECOND_PAYLOAD_VALUE {label} missing second residual payload byte")
    if stream[second_idx] != expected_second:
        raise SystemExit(
            f"[FAIL] B4_SECOND_PAYLOAD_VALUE {label} second payload 0x{stream[second_idx]:02x}, "
            f"expected 0x{expected_second:02x}"
        )

    pass_values: list[int] = []
    for value in range(256):
        mutated = bytearray(stream)
        mutated[second_idx] = value
        raw, err = decode_raw_bytes(bytes(mutated))
        if is_expected_decode(raw, err, fixture, cb_value, cr_value):
            pass_values.append(value)

    actual_ranges = compact_ranges(pass_values)
    expected_ranges = PASS_RANGES[(cb_value, cr_value)]
    if actual_ranges != expected_ranges:
        raise SystemExit(
            f"[FAIL] B4_SECOND_PAYLOAD_VALUE {label} pass-ranges drifted:\n"
            f"  got      {actual_ranges}\n"
            f"  expected {expected_ranges}"
        )
    expected_count = PASS_COUNTS[(cb_value, cr_value)]
    if len(pass_values) != expected_count:
        raise SystemExit(
            f"[FAIL] B4_SECOND_PAYLOAD_VALUE {label} pass-count {len(pass_values)}, "
            f"expected {expected_count}: {actual_ranges}"
        )

    print(
        f"[PASS] B4_SECOND_PAYLOAD_VALUE {label}: baseline first=0x{expected_first:02x} "
        f"second=0x{expected_second:02x} short/{expected_signature}, "
        f"single-second-byte pass_count={len(pass_values)} ranges={actual_ranges!r}"
    )


def main() -> int:
    sim = build_baseline_sim()
    for cb_value, cr_value in BASELINE_CASES:
        check_case(sim, cb_value, cr_value)
    print(
        "[PASS] CABAC P16x16 high-amplitude Cb0xb/Cr0x4 second-payload value sweep "
        "locks an empty strict-decode class for all four +/-32 endpoints; mutating only "
        "0xdf/0xef cannot repair the remaining reciprocal complement."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
