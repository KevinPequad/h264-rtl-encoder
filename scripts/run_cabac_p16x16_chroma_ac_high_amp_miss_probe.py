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
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from scripts.run_cabac_p16x16_chroma_ac_cross_plane_first_payload_probe import (  # noqa: E402
    EXPECTED_BYTES,
    EXPECTED_HEADER_TAIL,
    FRAME_SIZE,
    assert_planes,
    build_baseline_sim,
    decode_raw,
    final_slice_hex,
    make_fixture,
    run_case,
)

EXPECTED_FIRST_PAYLOAD = 0xBB

# (cb_mask, cr_mask, cb_value, cr_value): (expected_final_slice_hex, ffmpeg signature)
MISS_CASES = {
    (0x2, 0xD, 160, 160): ("0000000141d008086bbbecf7", "bytestream -16"),
    (0x2, 0xD, 96, 160): ("0000000141d008086bbbecf7", "bytestream -16"),
    (0x2, 0xD, 160, 96): ("0000000141d008086bbbccff", "bytestream -26"),
    (0x2, 0xD, 96, 96): ("0000000141d008086bbbccff", "bytestream -26"),
}

# Exact first-payload byte values that make the remaining high-amplitude
# Cb0x2/Cr0xd miss cases strict-decode with byte-identical IDR and expected
# plane-local SAD.  The broad-but-not-universal classes keep this diagnostic
# pointed at CABAC arithmetic/renormalization instead of a literal one-byte fix.
FIRST_PAYLOAD_PASS_RANGES = {
    (0x2, 0xD, 160, 160): (
        (0x00, 0xA6),
        (0xAF, 0xAF),
        (0xB4, 0xB4),
        (0xB8, 0xB8),
        (0xC6, 0xC6),
        (0xCD, 0xCD),
        (0xD5, 0xD5),
        (0xDB, 0xDB),
        (0xDF, 0xDF),
        (0xF0, 0xF0),
        (0xF8, 0xF8),
        (0xFC, 0xFC),
    ),
    (0x2, 0xD, 96, 160): (
        (0x00, 0xA6),
        (0xAF, 0xAF),
        (0xB4, 0xB4),
        (0xB8, 0xB8),
        (0xC6, 0xC6),
        (0xCD, 0xCD),
        (0xD5, 0xD5),
        (0xDB, 0xDB),
        (0xDF, 0xDF),
        (0xF0, 0xF0),
        (0xF8, 0xF8),
        (0xFC, 0xFC),
    ),
    (0x2, 0xD, 160, 96): (
        (0x00, 0xA6),
        (0xAA, 0xAA),
        (0xAE, 0xAE),
        (0xB5, 0xB5),
        (0xB9, 0xB9),
        (0xC6, 0xC6),
        (0xCA, 0xCA),
        (0xCC, 0xCC),
        (0xCF, 0xCF),
        (0xE8, 0xE8),
        (0xF3, 0xF3),
    ),
    (0x2, 0xD, 96, 96): (
        (0x00, 0xA6),
        (0xAA, 0xAA),
        (0xAE, 0xAE),
        (0xB5, 0xB5),
        (0xB9, 0xB9),
        (0xC6, 0xC6),
        (0xCA, 0xCA),
        (0xCC, 0xCC),
        (0xCF, 0xCF),
        (0xE8, 0xE8),
        (0xF3, 0xF3),
    ),
}


def expanded_values(ranges: tuple[tuple[int, int], ...]) -> set[int]:
    values: set[int] = set()
    for start, end in ranges:
        values.update(range(start, end + 1))
    return values


def format_ranges(values: set[int]) -> str:
    ordered = sorted(values)
    chunks: list[tuple[int, int]] = []
    if not ordered:
        return ""
    start = prev = ordered[0]
    for value in ordered[1:]:
        if value == prev + 1:
            prev = value
        else:
            chunks.append((start, prev))
            start = prev = value
    chunks.append((start, prev))
    return ",".join(f"0x{a:02x}" if a == b else f"0x{a:02x}-0x{b:02x}" for a, b in chunks)


def decode_stream(data: bytes) -> tuple[bytes, str]:
    with tempfile.NamedTemporaryFile(prefix="h264_cross_plane_high_amp_miss_", suffix=".h264", delete=False) as h264_tmp:
        h264_tmp.write(data)
        h264_path = Path(h264_tmp.name)
    with tempfile.NamedTemporaryFile(prefix="h264_cross_plane_high_amp_miss_", suffix=".yuv", delete=False) as raw_tmp:
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
                str(h264_path),
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
        h264_path.unlink(missing_ok=True)
        raw_path.unlink(missing_ok=True)


def first_payload_index(stream: bytes, label: str) -> int:
    last_start = stream.rfind(b"\x00\x00\x00\x01")
    if last_start < 0:
        raise SystemExit(f"[FAIL] CROSS_PLANE_HIGH_AMP_MISS {label} missing final Annex-B start code")
    header_tail_idx = last_start + 8
    first_idx = last_start + 9
    if first_idx >= len(stream):
        raise SystemExit(f"[FAIL] CROSS_PLANE_HIGH_AMP_MISS {label} missing first CABAC payload byte")
    if stream[header_tail_idx] != EXPECTED_HEADER_TAIL:
        raise SystemExit(
            f"[FAIL] CROSS_PLANE_HIGH_AMP_MISS {label} header tail 0x{stream[header_tail_idx]:02x}, "
            f"expected 0x{EXPECTED_HEADER_TAIL:02x}"
        )
    if stream[first_idx] != EXPECTED_FIRST_PAYLOAD:
        raise SystemExit(
            f"[FAIL] CROSS_PLANE_HIGH_AMP_MISS {label} first payload 0x{stream[first_idx]:02x}, "
            f"expected 0x{EXPECTED_FIRST_PAYLOAD:02x}"
        )
    return first_idx


def lock_first_payload_pass_range(
    stream: bytes,
    fixture: Path,
    cb_mask: int,
    cr_mask: int,
    cb_value: int,
    cr_value: int,
    label: str,
) -> None:
    first_idx = first_payload_index(stream, label)
    actual: set[int] = set()
    for value in range(256):
        mutated = bytearray(stream)
        mutated[first_idx] = value
        raw, err = decode_stream(bytes(mutated))
        if err.strip() or len(raw) != EXPECTED_BYTES:
            continue
        try:
            assert_planes(cb_mask, cr_mask, fixture, raw, cb_value, cr_value)
        except SystemExit:
            continue
        actual.add(value)

    expected = expanded_values(FIRST_PAYLOAD_PASS_RANGES[(cb_mask, cr_mask, cb_value, cr_value)])
    if actual != expected:
        raise SystemExit(
            f"[FAIL] CROSS_PLANE_HIGH_AMP_MISS {label} first-payload pass range drift: "
            f"got {len(actual)} [{format_ranges(actual)}], expected {len(expected)} [{format_ranges(expected)}]"
        )
    for promoted in (0x75, 0x6B):
        if promoted not in actual:
            raise SystemExit(
                f"[FAIL] CROSS_PLANE_HIGH_AMP_MISS {label} first-payload class lost 0x{promoted:02x}"
            )
    print(
        f"[PASS] CROSS_PLANE_HIGH_AMP_MISS {label} first-payload expected-SAD class locked: "
        f"count={len(actual)} ranges={format_ranges(actual)}"
    )


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
    lock_first_payload_pass_range(stream, fixture, cb_mask, cr_mask, cb_value, cr_value, label)
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
        "strict one-frame FFmpeg miss signatures, byte-identical IDR frames, and "
        "locked first-payload expected-SAD mutation classes."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
