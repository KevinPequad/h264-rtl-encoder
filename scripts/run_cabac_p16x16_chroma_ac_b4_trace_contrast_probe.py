#!/usr/bin/env python3
"""Trace-contrast probe for the open high-amplitude Cb0xb/Cr0x4 miss.

The checked-in source has promoted the mirror high-amplitude complement
Cb0x4/Cr0xb through the scoped split payload-context bank, while the reciprocal
Cb0xb/Cr0x4 family still short-decodes and prior staged split variants did not
repair it.  This bounded DEBUG_CABAC probe runs both families side by side and
locks the useful contrast for the next source repair: both sides walk the
expected chroma-AC coded-block masks, the mirror family strict-decodes through
the split bank, and the B4 reciprocal stays on the shared bank with the exact
first-payload/tail/FFmpeg short-decode signatures.
"""

from __future__ import annotations

import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from scripts.rtl_runner import BuildConfig, build_sim, stage_workspace  # noqa: E402
from scripts.run_cabac_p16x16_chroma_ac_b4_first_payload_substitution_probe import (  # noqa: E402
    BASELINE_CASES as B4_BASELINE_CASES,
    CB_MASK as B4_CB_MASK,
    CR_MASK as B4_CR_MASK,
    assert_baseline_idr_only,
    decode_raw_bytes,
    first_payload_index,
)
from scripts.run_cabac_p16x16_chroma_ac_cross_plane_first_payload_probe import (  # noqa: E402
    EXPECTED_BYTES,
    assert_planes,
    decode_raw,
    final_slice_hex,
    make_fixture,
)

OUT_DIR = ROOT / "output" / "cabac_b4_trace_contrast_probe"
MIRROR_CB_MASK = 0x4
MIRROR_CR_MASK = 0xB

MIRROR_TAILS: dict[tuple[int, int], str] = {
    (160, 160): "0000000141d008086b3bcf7fbf",
    (96, 160): "0000000141d008086b3bcf7f7f",
    (160, 96): "0000000141d008086b3becf5bf",
    (96, 96): "0000000141d008086b3becf57f",
}

EXPECTED_CODED_BLOCKS: dict[tuple[int, int], list[int]] = {
    (B4_CB_MASK, B4_CR_MASK): [0, 1, 3, 6],
    (MIRROR_CB_MASK, MIRROR_CR_MASK): [2, 4, 5, 7],
}


def build_debug_sim() -> Path:
    workspace = Path(stage_workspace("h264_b4_trace_contrast_"))
    config = BuildConfig(
        width=16,
        height=16,
        bit_depth=8,
        chroma_format_idc=1,
        jobs=int(os.environ.get("BUILD_JOBS", "1")),
        enable_idr_ipcm=1,
        ipcm_sad_threshold=0,
        enable_cabac_p16x16=1,
        debug_cabac_p16x16=1,
    )
    sim = Path(build_sim(workspace, config))
    print(f"[INFO] B4_TRACE_CONTRAST workspace={workspace} sim={sim}")
    return sim


def run_debug_case(sim: Path, label: str, cb_mask: int, cr_mask: int, cb_value: int, cr_value: int) -> tuple[Path, Path, str]:
    fixture = make_fixture(cb_mask, cr_mask, cb_value, cr_value)
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    stem = f"{label}_cb{cb_mask:x}_cr{cr_mask:x}_cbv{cb_value}_crv{cr_value}"
    h264 = OUT_DIR / f"{stem}.h264"
    sim_log = OUT_DIR / f"{stem}.sim.log"
    with sim_log.open("w", encoding="utf-8") as log:
        subprocess.run(
            [str(sim), "+frames=2", "+timeout=5000000", f"+input={fixture}", f"+output={h264}", "+idr_interval=12"],
            stdout=log,
            stderr=subprocess.STDOUT,
            check=True,
        )
    return fixture, h264, sim_log.read_text(encoding="utf-8", errors="replace")


def payload_ctx_selects(text: str) -> list[int]:
    selects: list[int] = []
    for line in text.splitlines():
        if "[CABACCTX]" not in line or "cat=2" not in line:
            continue
        m = re.search(r"kind=(22|23|24) sel=(\d+)", line)
        if m:
            selects.append(int(m.group(2)))
    return selects


def coded_chroma_ac_blocks(text: str) -> list[int]:
    coded: list[int] = []
    for line in text.splitlines():
        if "[CABACRES]" not in line or "cat=2" not in line:
            continue
        # The first residual event per chroma-AC block is its coded_block_flag.
        # Keep this tied to the ctx101-104 family, coeff=0, and bypass=0 so the
        # probe only tracks CBF ownership rather than later sig/last/level bins.
        m = re.search(r"blk=(\d+) ctx=(10[1-4]) val=(\d+) bypass=0 coeff=0", line)
        if m and int(m.group(3)) == 1:
            coded.append(int(m.group(1)))
    return coded


def check_b4_case(sim: Path, cb_value: int, cr_value: int) -> None:
    expected_first, expected_tail, expected_signature = B4_BASELINE_CASES[(cb_value, cr_value)]
    label = f"B4 cb=0x{B4_CB_MASK:x} cr=0x{B4_CR_MASK:x} cb_value={cb_value} cr_value={cr_value}"
    fixture, h264, text = run_debug_case(sim, "b4_open", B4_CB_MASK, B4_CR_MASK, cb_value, cr_value)
    stream = h264.read_bytes()
    tail = final_slice_hex(stream, label)
    if tail != expected_tail:
        raise SystemExit(f"[FAIL] B4_TRACE_CONTRAST {label} tail {tail}, expected {expected_tail}")
    first_payload_index(stream, label, expected_first)
    raw, err = decode_raw_bytes(stream)
    assert_baseline_idr_only(raw, err, fixture, label, expected_signature)

    blocks = coded_chroma_ac_blocks(text)
    expected_blocks = EXPECTED_CODED_BLOCKS[(B4_CB_MASK, B4_CR_MASK)]
    if blocks != expected_blocks:
        raise SystemExit(f"[FAIL] B4_TRACE_CONTRAST {label} coded blocks {blocks}, expected {expected_blocks}")
    selects = payload_ctx_selects(text)
    if any(sel >= 16 for sel in selects):
        raise SystemExit(f"[FAIL] B4_TRACE_CONTRAST {label} unexpectedly used split payload bank: {selects}")
    print(
        f"[PASS] B4_TRACE_CONTRAST {label}: shared-bank short/{expected_signature}, "
        f"first_payload=0x{expected_first:02x}, coded_blocks={blocks}, tail={tail}"
    )


def check_mirror_case(sim: Path, cb_value: int, cr_value: int) -> None:
    label = f"MIRROR cb=0x{MIRROR_CB_MASK:x} cr=0x{MIRROR_CR_MASK:x} cb_value={cb_value} cr_value={cr_value}"
    fixture, h264, text = run_debug_case(sim, "mirror_green", MIRROR_CB_MASK, MIRROR_CR_MASK, cb_value, cr_value)
    stream = h264.read_bytes()
    tail = final_slice_hex(stream, label)
    expected_tail = MIRROR_TAILS[(cb_value, cr_value)]
    if tail != expected_tail:
        raise SystemExit(f"[FAIL] B4_TRACE_CONTRAST {label} tail {tail}, expected {expected_tail}")
    raw, err = decode_raw(h264)
    if err.strip():
        raise SystemExit(f"[FAIL] B4_TRACE_CONTRAST {label} expected strict FFmpeg, got {err.strip()!r}")
    if len(raw) != EXPECTED_BYTES:
        raise SystemExit(f"[FAIL] B4_TRACE_CONTRAST {label} decoded {len(raw)}/{EXPECTED_BYTES} bytes")
    u_sad, v_sad = assert_planes(MIRROR_CB_MASK, MIRROR_CR_MASK, fixture, raw, cb_value, cr_value)

    blocks = coded_chroma_ac_blocks(text)
    expected_blocks = EXPECTED_CODED_BLOCKS[(MIRROR_CB_MASK, MIRROR_CR_MASK)]
    if blocks != expected_blocks:
        raise SystemExit(f"[FAIL] B4_TRACE_CONTRAST {label} coded blocks {blocks}, expected {expected_blocks}")
    selects = payload_ctx_selects(text)
    if not any(sel >= 16 for sel in selects):
        raise SystemExit(f"[FAIL] B4_TRACE_CONTRAST {label} did not expose split payload bank: {selects}")
    print(
        f"[PASS] B4_TRACE_CONTRAST {label}: split-bank strict decode, "
        f"coded_blocks={blocks}, U_SAD={u_sad} V_SAD={v_sad}, tail={tail}"
    )


def main() -> int:
    sim = build_debug_sim()
    for cb_value, cr_value in B4_BASELINE_CASES:
        check_b4_case(sim, cb_value, cr_value)
        check_mirror_case(sim, cb_value, cr_value)
    print(
        "[PASS] CABAC P16x16 high-amplitude B4 trace contrast: open Cb0xb/Cr0x4 "
        "streams still short-decode on the shared payload bank with the expected "
        "coded-block mask, while the Cb0x4/Cr0xb mirror strict-decodes through the "
        "split payload bank with the mirror coded-block mask."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
