#!/usr/bin/env python3
"""Bytestream-side first-payload diagnostic for high-amplitude Cb0xb/Cr0x4.

The reciprocal Cb-all-but-one / Cr-singleton high-amplitude complement still
short-decodes from the checked-in RTL stream, and the staged split-context probe
rejects simply moving that mask pair onto the existing Cr, Cb, or dual payload
context banks.  This probe keeps the RTL unchanged, mutates only the first CABAC
residual payload byte after the locked P-slice header, and proves the same four
+/-32 cases strict-decode with exact plane-local SAD under a low first-payload
value.  That scopes the next repair to the arithmetic/renormalization state that
produces the first payload byte, not to CBF ordering or literal testbench repair.
"""

from __future__ import annotations

import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from scripts.run_cabac_p16x16_chroma_ac_cross_plane_first_payload_probe import (  # noqa: E402
    EXPECTED_BYTES,
    EXPECTED_HEADER_TAIL,
    FRAME_SIZE,
    LUMA_SIZE,
    CHROMA_SIZE,
    assert_planes,
    build_baseline_sim,
    final_slice_hex,
    make_fixture,
    run_case,
)

CB_MASK = 0xB
CR_MASK = 0x4
SUBSTITUTED_FIRST_PAYLOAD = 0x75

BASELINE_CASES = {
    (160, 160): (0xFE, "0000000141d008086bfedff5", "bytestream -4"),
    (160, 96): (0xFE, "0000000141d008086bfedff5", "bytestream -4"),
    (96, 160): (0xFF, "0000000141d008086bffef75", "corrupt decoded frame"),
    (96, 96): (0xFF, "0000000141d008086bffef75", "corrupt decoded frame"),
}


def decode_raw_bytes(data: bytes) -> tuple[bytes, str]:
    with tempfile.NamedTemporaryFile(prefix="h264_b4_first_payload_sub_", suffix=".h264", delete=False) as h264_tmp:
        h264_tmp.write(data)
        h264_path = Path(h264_tmp.name)
    with tempfile.NamedTemporaryFile(prefix="h264_b4_first_payload_sub_", suffix=".yuv", delete=False) as raw_tmp:
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


def first_payload_index(stream: bytes, label: str, expected_first_payload: int) -> int:
    last_start = stream.rfind(b"\x00\x00\x00\x01")
    if last_start < 0:
        raise SystemExit(f"[FAIL] B4_FIRST_PAYLOAD_SUB {label} missing final Annex-B start code")
    header_tail_idx = last_start + 8
    first_idx = last_start + 9
    if first_idx >= len(stream):
        raise SystemExit(f"[FAIL] B4_FIRST_PAYLOAD_SUB {label} missing first residual payload byte")
    if stream[header_tail_idx] != EXPECTED_HEADER_TAIL:
        raise SystemExit(
            f"[FAIL] B4_FIRST_PAYLOAD_SUB {label} header tail 0x{stream[header_tail_idx]:02x}, "
            f"expected 0x{EXPECTED_HEADER_TAIL:02x}"
        )
    if stream[first_idx] != expected_first_payload:
        raise SystemExit(
            f"[FAIL] B4_FIRST_PAYLOAD_SUB {label} first payload 0x{stream[first_idx]:02x}, "
            f"expected 0x{expected_first_payload:02x}"
        )
    return first_idx


def mutate_first_payload(stream: bytes, first_idx: int) -> bytes:
    mutated = bytearray(stream)
    mutated[first_idx] = SUBSTITUTED_FIRST_PAYLOAD
    return bytes(mutated)


def assert_baseline_idr_only(raw: bytes, err: str, fixture: Path, label: str, expected_signature: str) -> None:
    if len(raw) != FRAME_SIZE or expected_signature not in err:
        raise SystemExit(
            f"[FAIL] B4_FIRST_PAYLOAD_SUB {label} baseline drift: decoded "
            f"{len(raw)}/{EXPECTED_BYTES}, err={err.strip()!r}, expected {expected_signature!r}"
        )
    src = fixture.read_bytes()
    if raw != src[:FRAME_SIZE]:
        raise SystemExit(f"[FAIL] B4_FIRST_PAYLOAD_SUB {label} baseline changed IDR reference")


def check_case(sim: Path, cb_value: int, cr_value: int) -> None:
    expected_first, expected_tail, expected_signature = BASELINE_CASES[(cb_value, cr_value)]
    label = f"cb=0x{CB_MASK:x} cr=0x{CR_MASK:x} cb_value={cb_value} cr_value={cr_value}"
    fixture = make_fixture(CB_MASK, CR_MASK, cb_value, cr_value)
    h264 = run_case(sim, CB_MASK, CR_MASK, fixture, cb_value, cr_value)
    stream = h264.read_bytes()
    tail = final_slice_hex(stream, label)
    if tail != expected_tail:
        raise SystemExit(f"[FAIL] B4_FIRST_PAYLOAD_SUB {label} tail {tail}, expected {expected_tail}")
    first_idx = first_payload_index(stream, label, expected_first)

    baseline_raw, baseline_err = decode_raw_bytes(stream)
    assert_baseline_idr_only(baseline_raw, baseline_err, fixture, label, expected_signature)

    mutated_raw, mutated_err = decode_raw_bytes(mutate_first_payload(stream, first_idx))
    if mutated_err.strip():
        raise SystemExit(f"[FAIL] B4_FIRST_PAYLOAD_SUB {label} substituted FFmpeg log {mutated_err.strip()!r}")
    u_sad, v_sad = assert_planes(CB_MASK, CR_MASK, fixture, mutated_raw, cb_value, cr_value)
    if len(mutated_raw) != EXPECTED_BYTES:
        raise SystemExit(
            f"[FAIL] B4_FIRST_PAYLOAD_SUB {label} substituted decoded {len(mutated_raw)}/{EXPECTED_BYTES}"
        )
    print(
        f"[PASS] B4_FIRST_PAYLOAD_SUB {label}: baseline first=0x{expected_first:02x} "
        f"short/{expected_signature}, substituting first payload "
        f"0x{SUBSTITUTED_FIRST_PAYLOAD:02x} strict-decodes U_SAD={u_sad} V_SAD={v_sad}"
    )


def main() -> int:
    sim = build_baseline_sim()
    for cb_value, cr_value in BASELINE_CASES:
        check_case(sim, cb_value, cr_value)
    print(
        "[PASS] CABAC P16x16 high-amplitude Cb0xb/Cr0x4 first-payload substitution "
        "diagnostic: checked-in RTL streams still short-decode, while changing only "
        "the first residual payload byte to 0x75 strict-decodes all four +/-32 cases "
        "with exact Cb/Cr SAD."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
