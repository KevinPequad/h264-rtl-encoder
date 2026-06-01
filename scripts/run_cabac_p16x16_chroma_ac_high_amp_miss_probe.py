#!/usr/bin/env python3
"""Lock the remaining high-amplitude Cb/Cr 0x2/0xd chroma-AC miss signatures.

The promoted cross-plane chroma-AC gate covers low-amplitude 0x2/0xd and the
reciprocal high-amplitude 0xd/0x2 cases.  The Cb singleton + Cr all-but-one
0x2/0xd high-amplitude lane is still a narrow arithmetic/context miss.  Keep a
small negative probe around the exact generated tails and FFmpeg signatures so
the next RTL repair can promote these cases without losing the current failure
shape.
"""

from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from scripts.run_cabac_p16x16_chroma_ac_cross_plane_first_payload_probe import (  # noqa: E402
    EXPECTED_BYTES,
    FRAME_SIZE,
    build_baseline_sim,
    decode_raw,
    final_slice_hex,
    make_fixture,
    run_case,
)

# (cb_mask, cr_mask, cb_value, cr_value): (expected_final_slice_hex, ffmpeg signature)
MISS_CASES = {
    (0x2, 0xD, 160, 160): ("0000000141d008086bbbecf7", "bytestream -16"),
    (0x2, 0xD, 96, 160): ("0000000141d008086bbbecf7", "bytestream -16"),
    (0x2, 0xD, 160, 96): ("0000000141d008086bbbccff", "bytestream -26"),
    (0x2, 0xD, 96, 96): ("0000000141d008086bbbccff", "bytestream -26"),
}


def check_miss_case(
    sim: Path,
    cb_mask: int,
    cr_mask: int,
    cb_value: int,
    cr_value: int,
    expected_tail: str,
    expected_signature: str,
) -> None:
    fixture = make_fixture(cb_mask, cr_mask, cb_value, cr_value)
    h264 = run_case(sim, cb_mask, cr_mask, fixture, cb_value, cr_value)
    stream = h264.read_bytes()
    label = f"cb=0x{cb_mask:x} cr=0x{cr_mask:x} cb_value={cb_value} cr_value={cr_value}"
    tail = final_slice_hex(stream, label)
    if tail != expected_tail:
        raise SystemExit(
            f"[FAIL] CROSS_PLANE_HIGH_AMP_MISS {label} tail drift {tail}, expected {expected_tail}"
        )

    raw, err = decode_raw(h264)
    err_text = err.strip()
    if len(raw) != FRAME_SIZE or expected_signature not in err_text:
        raise SystemExit(
            f"[FAIL] CROSS_PLANE_HIGH_AMP_MISS {label} signature drift: "
            f"decoded={len(raw)}/{EXPECTED_BYTES} err={err_text!r}, expected {expected_signature!r}"
        )
    src = fixture.read_bytes()
    if raw != src[:FRAME_SIZE]:
        raise SystemExit(f"[FAIL] CROSS_PLANE_HIGH_AMP_MISS {label} changed IDR reference frame")
    print(
        f"[PASS] CROSS_PLANE_HIGH_AMP_MISS {label} remains bounded one-frame miss: "
        f"decoded={len(raw)}/{EXPECTED_BYTES} signature={expected_signature} tail={tail}"
    )


def main() -> int:
    sim = build_baseline_sim()
    for (cb_mask, cr_mask, cb_value, cr_value), (tail, signature) in MISS_CASES.items():
        check_miss_case(sim, cb_mask, cr_mask, cb_value, cr_value, tail, signature)
    print(
        "[PASS] CABAC P16x16 cross-plane high-amplitude chroma-AC miss probe: "
        "Cb/Cr 0x2/0xd +/-32 complement cases keep exact final-slice tails, "
        "strict one-frame FFmpeg miss signatures, and byte-identical IDR frames."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
