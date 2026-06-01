#!/usr/bin/env python3
"""Payload-boundary probe for high-amplitude reciprocal Cb0xb/Cr0x4.

The B4 first-payload sweep proves the first residual payload byte has broad
strict-decode equivalence classes, while the second- and third-payload sweeps
prove that mutating those later bytes has an empty strict expected-SAD repair
class.  This bounded probe locks the corresponding stream boundary: the current
RTL emits exactly three bytes after the CABAC P-slice header tail for all four
+/-32 endpoint streams, so there is no fourth generated payload byte to sweep.
That keeps the next source repair focused on the arithmetic/renormalization
state that produces the first payload byte rather than on a later bytestream
patch.
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
    assert_baseline_idr_only,
    decode_raw_bytes,
    first_payload_index,
)
from scripts.run_cabac_p16x16_chroma_ac_b4_second_payload_value_sweep import (  # noqa: E402
    BASELINE_SECOND_PAYLOADS,
)
from scripts.run_cabac_p16x16_chroma_ac_b4_third_payload_value_sweep import (  # noqa: E402
    BASELINE_THIRD_PAYLOADS,
)
from scripts.run_cabac_p16x16_chroma_ac_cross_plane_first_payload_probe import (  # noqa: E402
    build_baseline_sim,
    final_slice_hex,
    make_fixture,
    run_case,
)

PAYLOAD_BYTES_AFTER_HEADER = 3


def check_case(sim: Path, cb_value: int, cr_value: int) -> None:
    expected_first, expected_tail, expected_signature = BASELINE_CASES[(cb_value, cr_value)]
    expected_second = BASELINE_SECOND_PAYLOADS[(cb_value, cr_value)]
    expected_third = BASELINE_THIRD_PAYLOADS[(cb_value, cr_value)]
    label = f"cb=0x{CB_MASK:x} cr=0x{CR_MASK:x} cb_value={cb_value} cr_value={cr_value}"

    fixture = make_fixture(CB_MASK, CR_MASK, cb_value, cr_value)
    h264 = run_case(sim, CB_MASK, CR_MASK, fixture, cb_value, cr_value)
    stream = h264.read_bytes()
    tail = final_slice_hex(stream, label)
    if tail != expected_tail:
        raise SystemExit(f"[FAIL] B4_PAYLOAD_BOUNDARY {label} tail {tail}, expected {expected_tail}")

    first_idx = first_payload_index(stream, label, expected_first)
    second_idx = first_idx + 1
    third_idx = first_idx + 2
    fourth_idx = first_idx + 3
    final_payload_len = len(stream) - first_idx
    if final_payload_len != PAYLOAD_BYTES_AFTER_HEADER:
        raise SystemExit(
            f"[FAIL] B4_PAYLOAD_BOUNDARY {label} payload length {final_payload_len}, "
            f"expected exactly {PAYLOAD_BYTES_AFTER_HEADER} bytes after the CABAC header tail"
        )
    if fourth_idx != len(stream):
        raise SystemExit(
            f"[FAIL] B4_PAYLOAD_BOUNDARY {label} has unexpected byte 0x{stream[fourth_idx]:02x} "
            "at the would-be fourth payload index"
        )
    if stream[second_idx] != expected_second:
        raise SystemExit(
            f"[FAIL] B4_PAYLOAD_BOUNDARY {label} second payload 0x{stream[second_idx]:02x}, "
            f"expected 0x{expected_second:02x}"
        )
    if stream[third_idx] != expected_third:
        raise SystemExit(
            f"[FAIL] B4_PAYLOAD_BOUNDARY {label} third payload 0x{stream[third_idx]:02x}, "
            f"expected 0x{expected_third:02x}"
        )

    baseline_raw, baseline_err = decode_raw_bytes(stream)
    assert_baseline_idr_only(baseline_raw, baseline_err, fixture, label, expected_signature)
    print(
        f"[PASS] B4_PAYLOAD_BOUNDARY {label}: final-slice tail={tail} "
        f"payload_bytes=[0x{expected_first:02x},0x{expected_second:02x},0x{expected_third:02x}] "
        f"no_fourth_payload=True baseline_short={expected_signature!r}"
    )


def main() -> int:
    sim = build_baseline_sim()
    for cb_value, cr_value in BASELINE_CASES:
        check_case(sim, cb_value, cr_value)
    print(
        "[PASS] CABAC P16x16 high-amplitude Cb0xb/Cr0x4 payload-boundary probe "
        "locks exactly three post-header CABAC payload bytes for all four +/-32 endpoints; "
        "there is no generated fourth payload byte to sweep, so repair remains scoped to "
        "earlier arithmetic/renormalization state."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
