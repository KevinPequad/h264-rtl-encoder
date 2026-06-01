#!/usr/bin/env python3
"""Trace-contrast gate for the high-amplitude Cb0xb/Cr0x4 repair.

The B4 reciprocal Cb-all-but-one / Cr-singleton lane used to short-decode on the
shared payload bank.  The source repair is intentionally narrower than the older
payload-bank experiments: only that mask pair switches its chroma-AC coded-block-
flag walk to literal plane-local neighbours.  This DEBUG_CABAC gate keeps the
B4 family strict-decodable with exact tails while also retaining the existing
Cb0x4/Cr0xb mirror strict-decode split-bank guard.
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
from scripts.run_cabac_p16x16_chroma_ac_cross_plane_first_payload_probe import (  # noqa: E402
    EXPECTED_BYTES,
    assert_planes,
    decode_raw,
    final_slice_hex,
    make_fixture,
)

OUT_DIR = ROOT / "output" / "cabac_b4_trace_contrast_probe"
B4_CB_MASK = 0xB
B4_CR_MASK = 0x4
MIRROR_CB_MASK = 0x4
MIRROR_CR_MASK = 0xB

B4_TAILS: dict[tuple[int, int], str] = {
    (160, 160): "0000000141d008086b7fcf7f7b",
    (160, 96): "0000000141d008086b7fcf7f7b",
    (96, 160): "0000000141d008086b7edef7fa",
    (96, 96): "0000000141d008086b7edef7fa",
}

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
EXPECTED_B4_CBF_SELECTS = [0, 1, 2, 2, 4, 4, 4, 5]


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


def cbf_ctx_selects(text: str) -> list[int]:
    selects: list[int] = []
    for line in text.splitlines():
        if "[CABACCTX]" not in line or "cat=2" not in line:
            continue
        m = re.search(r"kind=21 sel=(\d+)", line)
        if m:
            selects.append(int(m.group(1)))
    return selects


def split_payload_blocks(text: str) -> list[int]:
    blocks: set[int] = set()
    for line in text.splitlines():
        if "[CABACCTX]" not in line or "cat=2" not in line:
            continue
        m = re.search(r"blk=(\d+) kind=(22|23|24) sel=(\d+)", line)
        if m and int(m.group(3)) >= 16:
            blocks.add(int(m.group(1)))
    return sorted(blocks)


def high_payload_ctx_summary(text: str) -> list[tuple[int, int, int, int]]:
    """Return (block, kind, selector, count) rows for split high-bank payload contexts."""
    counts: dict[tuple[int, int, int], int] = {}
    for line in text.splitlines():
        if "[CABACCTX]" not in line or "cat=2" not in line:
            continue
        m = re.search(r"blk=(\d+) kind=(22|23|24) sel=(\d+)", line)
        if not m:
            continue
        block = int(m.group(1))
        kind = int(m.group(2))
        selector = int(m.group(3))
        if selector >= 16:
            key = (block, kind, selector)
            counts[key] = counts.get(key, 0) + 1
    return [(block, kind, selector, count) for (block, kind, selector), count in sorted(counts.items())]


def coded_chroma_ac_blocks(text: str) -> list[int]:
    coded: list[int] = []
    for line in text.splitlines():
        if "[CABACRES]" not in line or "cat=2" not in line:
            continue
        m = re.search(r"blk=(\d+) ctx=(10[1-4]) val=(\d+) bypass=0 coeff=0", line)
        if m and int(m.group(3)) == 1:
            coded.append(int(m.group(1)))
    return coded


def check_case(
    sim: Path,
    label: str,
    cb_mask: int,
    cr_mask: int,
    cb_value: int,
    cr_value: int,
    expected_tail: str,
    expect_split_blocks: list[int],
    expected_high_summary: list[tuple[int, int, int, int]],
    expected_cbf_selects: list[int] | None = None,
) -> None:
    case_label = f"{label} cb=0x{cb_mask:x} cr=0x{cr_mask:x} cb_value={cb_value} cr_value={cr_value}"
    fixture, h264, text = run_debug_case(sim, label.lower(), cb_mask, cr_mask, cb_value, cr_value)
    stream = h264.read_bytes()
    tail = final_slice_hex(stream, case_label)
    if tail != expected_tail:
        raise SystemExit(f"[FAIL] B4_TRACE_CONTRAST {case_label} tail {tail}, expected {expected_tail}")
    raw, err = decode_raw(h264)
    if err.strip():
        raise SystemExit(f"[FAIL] B4_TRACE_CONTRAST {case_label} expected strict FFmpeg, got {err.strip()!r}")
    if len(raw) != EXPECTED_BYTES:
        raise SystemExit(f"[FAIL] B4_TRACE_CONTRAST {case_label} decoded {len(raw)}/{EXPECTED_BYTES} bytes")
    u_sad, v_sad = assert_planes(cb_mask, cr_mask, fixture, raw, cb_value, cr_value)

    blocks = coded_chroma_ac_blocks(text)
    expected_blocks = EXPECTED_CODED_BLOCKS[(cb_mask, cr_mask)]
    if blocks != expected_blocks:
        raise SystemExit(f"[FAIL] B4_TRACE_CONTRAST {case_label} coded blocks {blocks}, expected {expected_blocks}")
    split_blocks = split_payload_blocks(text)
    if split_blocks != expect_split_blocks:
        raise SystemExit(
            f"[FAIL] B4_TRACE_CONTRAST {case_label} split payload blocks {split_blocks}, expected {expect_split_blocks}"
        )
    high_summary = high_payload_ctx_summary(text)
    if high_summary != expected_high_summary:
        raise SystemExit(
            f"[FAIL] B4_TRACE_CONTRAST {case_label} high-bank payload context summary "
            f"{high_summary}, expected {expected_high_summary}"
        )
    if expected_cbf_selects is not None:
        selects = cbf_ctx_selects(text)
        if selects != expected_cbf_selects:
            raise SystemExit(f"[FAIL] B4_TRACE_CONTRAST {case_label} CBF selects {selects}, expected {expected_cbf_selects}")
    print(
        f"[PASS] B4_TRACE_CONTRAST {case_label}: strict two-frame decode, "
        f"coded_blocks={blocks}, split_blocks={split_blocks}, high_payload_ctx={high_summary}, "
        f"U_SAD={u_sad} V_SAD={v_sad}, tail={tail}"
    )


def main() -> int:
    sim = build_debug_sim()
    for cb_value, cr_value in B4_TAILS:
        check_case(
            sim,
            "B4",
            B4_CB_MASK,
            B4_CR_MASK,
            cb_value,
            cr_value,
            B4_TAILS[(cb_value, cr_value)],
            expect_split_blocks=[],
            expected_high_summary=[],
            expected_cbf_selects=EXPECTED_B4_CBF_SELECTS,
        )
        check_case(
            sim,
            "MIRROR",
            MIRROR_CB_MASK,
            MIRROR_CR_MASK,
            cb_value,
            cr_value,
            MIRROR_TAILS[(cb_value, cr_value)],
            expect_split_blocks=[4, 5, 7],
            expected_high_summary=[(4, 24, 17, 5), (5, 24, 17, 5), (7, 24, 17, 5)],
        )
    print(
        "[PASS] CABAC P16x16 high-amplitude B4 trace contrast: Cb0xb/Cr0x4 now "
        "strict-decodes through the scoped plane-local CBF walk without using the split "
        "payload bank, while the Cb0x4/Cr0xb mirror remains strict on the split bank."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
