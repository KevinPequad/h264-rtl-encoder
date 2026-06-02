#!/usr/bin/env python3
"""Focused high-amplitude same-mask Cb+Cr chroma-AC probe.

The broad cross-plane gate keeps the complete default-amplitude same-mask
lattice strict.  This smaller probe targets the high-amplitude same-mask rows
that are easy to overclaim: it locks the currently strict checker/all-but-one
rows, preserves exact one-frame FFmpeg miss signatures for the remaining
all-but-one rows, and proves those remaining rows are first-payload-byte
sensitive without relying on a literal bytestream patch as a source repair.
"""

from __future__ import annotations

from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from scripts.run_cabac_p16x16_chroma_ac_cross_plane_first_payload_probe import (  # noqa: E402
    EXPECTED_BYTES,
    FRAME_SIZE,
    assert_planes,
    build_baseline_sim,
    decode_raw,
    final_slice_hex,
    make_fixture,
    run_case,
)

# Values 160 and 96 are +32 and -32 around neutral chroma 128.
STRICT_TAILS = {
    (0x5, 0x5, 160, 160): "0000000141d008086b3add",
    (0x5, 0x5, 96, 160): "0000000141d008086b3add",
    (0x5, 0x5, 160, 96): "0000000141d008086b7bfd",
    (0x5, 0x5, 96, 96): "0000000141d008086b7bfd",
    (0x7, 0x7, 160, 160): "0000000141d008086bfbdf77ed77bdffffbffe",
    (0x7, 0x7, 160, 96): "0000000141d008086bfbdf77ed77bbdfdff64e",
    (0xD, 0xD, 160, 160): "0000000141d008086bfadf7d7ede79ffedb7d7",
    (0xD, 0xD, 160, 96): "0000000141d008086bfadf7d7ed69fa7cfbbd7",
    (0xE, 0xE, 96, 160): "0000000141d008086bfbce75777d9feffbf7ba",
}

EXPECTED_MISSES = {
    (0x7, 0x7, 96, 160): (FRAME_SIZE, "bytestream -19", "0000000141d008086bfbed7d7f57bdffffbffe"),
    (0x7, 0x7, 96, 96): (FRAME_SIZE, "bytestream -13", "0000000141d008086bfbed7d7f57bbdfdff64e"),
    (0xB, 0xB, 160, 160): (FRAME_SIZE, "bytestream -15", "0000000141d008086bbbee77fff89cbff9dfd7"),
    (0xB, 0xB, 160, 96): (FRAME_SIZE, "bytestream -13", "0000000141d008086bbbee77fffd1abefd3fd7"),
    (0xB, 0xB, 96, 160): (FRAME_SIZE, "bytestream -19", "0000000141d008086bbbce77bdfd9cbff9dfd7"),
    (0xB, 0xB, 96, 96): (FRAME_SIZE, "bytestream -17", "0000000141d008086bbbce77bded1abefd3fd7"),
    (0xD, 0xD, 96, 160): (FRAME_SIZE, "bytestream -21", "0000000141d008086bfaed7fffff69ffedb7d7"),
    (0xD, 0xD, 96, 96): (FRAME_SIZE, "bytestream -23", "0000000141d008086bfaed7ffff79fa7cfbbd7"),
    (0xE, 0xE, 160, 160): (FRAME_SIZE, "bytestream -9", "0000000141d008086bfbee7df7d89feffbf7ba"),
    (0xE, 0xE, 160, 96): (FRAME_SIZE, "bytestream -11", "0000000141d008086bfbee7df7cd1cfef097ba"),
    (0xE, 0xE, 96, 96): (FRAME_SIZE, "bytestream -7", "0000000141d008086bfbce75777d1cfef097ba"),
}


def case_label(cb_mask: int, cr_mask: int, cb_value: int, cr_value: int) -> str:
    return f"cb=0x{cb_mask:x} cr=0x{cr_mask:x} cb_value={cb_value} cr_value={cr_value}"


def decode_stream(stream: bytes) -> tuple[bytes, str]:
    with tempfile.NamedTemporaryFile(prefix="h264_same_mask_high_amp_", suffix=".h264", delete=False) as h264_tmp:
        h264_tmp.write(stream)
        h264_path = Path(h264_tmp.name)
    with tempfile.NamedTemporaryFile(prefix="h264_same_mask_high_amp_", suffix=".yuv", delete=False) as raw_tmp:
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
        raise SystemExit(f"[FAIL] SAME_MASK_HIGH_AMP_MUTATION {label} missing final Annex-B start code")
    first_idx = last_start + 9
    if first_idx >= len(stream):
        raise SystemExit(f"[FAIL] SAME_MASK_HIGH_AMP_MUTATION {label} missing first residual payload byte")
    return first_idx


def mutate_first_payload(stream: bytes, first_idx: int, value: int) -> bytes:
    mutated = bytearray(stream)
    mutated[first_idx] = value
    return bytes(mutated)


def check_strict(sim: Path, cb_mask: int, cr_mask: int, cb_value: int, cr_value: int, expected_tail: str) -> None:
    fixture = make_fixture(cb_mask, cr_mask, cb_value, cr_value)
    h264 = run_case(sim, cb_mask, cr_mask, fixture, cb_value, cr_value)
    stream = h264.read_bytes()
    label = case_label(cb_mask, cr_mask, cb_value, cr_value)
    tail = final_slice_hex(stream, label)
    if tail != expected_tail:
        raise SystemExit(f"[FAIL] SAME_MASK_HIGH_AMP {label} tail drift {tail}, expected {expected_tail}")
    raw, err = decode_raw(h264)
    if err.strip():
        raise SystemExit(f"[FAIL] SAME_MASK_HIGH_AMP {label} FFmpeg log {err.strip()!r}")
    if len(raw) != EXPECTED_BYTES:
        raise SystemExit(f"[FAIL] SAME_MASK_HIGH_AMP {label} decoded {len(raw)}/{EXPECTED_BYTES}")
    u_sad, v_sad = assert_planes(cb_mask, cr_mask, fixture, raw, cb_value, cr_value)
    print(
        f"[PASS] SAME_MASK_HIGH_AMP {label} strict-decodes "
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
    label = case_label(cb_mask, cr_mask, cb_value, cr_value)
    tail = final_slice_hex(stream, label)
    if tail != expected_tail:
        raise SystemExit(f"[FAIL] SAME_MASK_HIGH_AMP_MISS {label} tail drift {tail}, expected {expected_tail}")
    raw, err = decode_raw(h264)
    if len(raw) != expected_bytes:
        raise SystemExit(
            f"[FAIL] SAME_MASK_HIGH_AMP_MISS {label} decoded {len(raw)}/{EXPECTED_BYTES}, "
            f"expected {expected_bytes}/{EXPECTED_BYTES}"
        )
    if expected_signature not in err:
        raise SystemExit(
            f"[FAIL] SAME_MASK_HIGH_AMP_MISS {label} FFmpeg signature {err.strip()!r}, "
            f"expected to contain {expected_signature!r}"
        )
    src = fixture.read_bytes()
    if raw and raw[:FRAME_SIZE] != src[:FRAME_SIZE]:
        raise SystemExit(f"[FAIL] SAME_MASK_HIGH_AMP_MISS {label} changed IDR reference")
    print(
        f"[PASS] SAME_MASK_HIGH_AMP_MISS {label} remains scoped to "
        f"{len(raw)}/{EXPECTED_BYTES} decoded bytes, signature={expected_signature!r}, tail={tail}"
    )

    first_idx = first_payload_index(stream, label)
    base_value = stream[first_idx]
    for mutation_label, value in (
        ("bit7", base_value ^ 0x80),
        ("0x75", 0x75),
        ("0x6b", 0x6B),
    ):
        mutated_raw, mutated_err = decode_stream(mutate_first_payload(stream, first_idx, value))
        if mutated_err.strip():
            raise SystemExit(
                f"[FAIL] SAME_MASK_HIGH_AMP_MUTATION {label} {mutation_label} "
                f"0x{base_value:02x}->0x{value:02x} FFmpeg log {mutated_err.strip()!r}"
            )
        u_sad, v_sad = assert_planes(cb_mask, cr_mask, fixture, mutated_raw, cb_value, cr_value)
        print(
            f"[PASS] SAME_MASK_HIGH_AMP_MUTATION {label} {mutation_label} "
            f"0x{base_value:02x}->0x{value:02x} promotes to "
            f"{len(mutated_raw)}/{EXPECTED_BYTES} U_SAD={u_sad} V_SAD={v_sad}"
        )


def main() -> int:
    sim = build_baseline_sim()
    for (cb_mask, cr_mask, cb_value, cr_value), tail in STRICT_TAILS.items():
        check_strict(sim, cb_mask, cr_mask, cb_value, cr_value, tail)
    for (cb_mask, cr_mask, cb_value, cr_value), (expected_bytes, expected_signature, tail) in EXPECTED_MISSES.items():
        check_expected_miss(sim, cb_mask, cr_mask, cb_value, cr_value, expected_bytes, expected_signature, tail)
    print(
        "[PASS] CABAC P16x16 high-amplitude same-mask Cb+Cr chroma-AC probe "
        "locks the promoted Cb0x5/Cr0x5 sign matrix, Cb-positive Cb0x7/Cr0x7 "
        "rows, plus strict Cb0xd/Cr0xd and Cb0xe/Cr0xe rows, while preserving exact one-frame miss signatures "
        "for the remaining all-but-one same-mask rows and proving bit7/0x75/0x6b first-payload "
        "mutations promote those rows with exact plane-local SAD"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
