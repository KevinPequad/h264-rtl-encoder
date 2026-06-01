#!/usr/bin/env python3
"""Debug smoke for the scoped Cr payload context split fixing high-amplitude complements.

This keeps a lightweight DEBUG_CABAC_P16X16 guard after the old high-amplitude
miss was promoted: the targeted Cb-singleton / Cr-all-but-one cases must strict-
decode and show Cr residual payload context selects in the staged high-bit bank,
while the reciprocal already-green Cb0xd/Cr0x2 control stays on the historical
shared payload bank.
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

OUT_DIR = ROOT / "output" / "cabac_high_amp_trace_probe"

CASES: dict[str, dict[str, Any]] = {
    "shared_cb1_cre_160_160": {"cb_mask": 0x1, "cr_mask": 0xE, "cb_value": 160, "cr_value": 160, "tail": "0000000141d008086b3bcdfd", "split": False},
    "shared_cb1_cre_096_160": {"cb_mask": 0x1, "cr_mask": 0xE, "cb_value": 96, "cr_value": 160, "tail": "0000000141d008086b3bcdfd", "split": False},
    "shared_cb1_cre_160_096": {"cb_mask": 0x1, "cr_mask": 0xE, "cb_value": 160, "cr_value": 96, "tail": "0000000141d008086b3add75", "split": False},
    "shared_cb1_cre_096_096": {"cb_mask": 0x1, "cr_mask": 0xE, "cb_value": 96, "cr_value": 96, "tail": "0000000141d008086b3add75", "split": False},
    "promoted_cb2_crd_160_160": {"cb_mask": 0x2, "cr_mask": 0xD, "cb_value": 160, "cr_value": 160, "tail": "0000000141d008086b3aec7fe6", "split": True},
    "promoted_cb2_crd_096_160": {"cb_mask": 0x2, "cr_mask": 0xD, "cb_value": 96, "cr_value": 160, "tail": "0000000141d008086b3aec7f7c", "split": True},
    "promoted_cb2_crd_160_096": {"cb_mask": 0x2, "cr_mask": 0xD, "cb_value": 160, "cr_value": 96, "tail": "0000000141d008086b3adefda6", "split": True},
    "promoted_cb2_crd_096_096": {"cb_mask": 0x2, "cr_mask": 0xD, "cb_value": 96, "cr_value": 96, "tail": "0000000141d008086b3adefdfc", "split": True},
    "promoted_cb4_crb_160_160": {"cb_mask": 0x4, "cr_mask": 0xB, "cb_value": 160, "cr_value": 160, "tail": "0000000141d008086b3bcf7fbf", "split": True},
    "promoted_cb4_crb_096_160": {"cb_mask": 0x4, "cr_mask": 0xB, "cb_value": 96, "cr_value": 160, "tail": "0000000141d008086b3bcf7f7f", "split": True},
    "promoted_cb4_crb_160_096": {"cb_mask": 0x4, "cr_mask": 0xB, "cb_value": 160, "cr_value": 96, "tail": "0000000141d008086b3becf5bf", "split": True},
    "promoted_cb4_crb_096_096": {"cb_mask": 0x4, "cr_mask": 0xB, "cb_value": 96, "cr_value": 96, "tail": "0000000141d008086b3becf57f", "split": True},
    "shared_cb8_cr7_160_160": {"cb_mask": 0x8, "cr_mask": 0x7, "cb_value": 160, "cr_value": 160, "tail": "0000000141d008086b7fcdff", "split": False},
    "shared_cb8_cr7_096_160": {"cb_mask": 0x8, "cr_mask": 0x7, "cb_value": 96, "cr_value": 160, "tail": "0000000141d008086b7fcdff", "split": False},
    "shared_cb8_cr7_160_096": {"cb_mask": 0x8, "cr_mask": 0x7, "cb_value": 160, "cr_value": 96, "tail": "0000000141d008086b7eddf7", "split": False},
    "shared_cb8_cr7_096_096": {"cb_mask": 0x8, "cr_mask": 0x7, "cb_value": 96, "cr_value": 96, "tail": "0000000141d008086b7eddf7", "split": False},
    "reciprocal_cbe_cr1_160_160": {"cb_mask": 0xE, "cr_mask": 0x1, "cb_value": 160, "cr_value": 160, "tail": "0000000141d008086b7edd7ff6", "split": False},
    "reciprocal_cbe_cr1_096_160": {"cb_mask": 0xE, "cr_mask": 0x1, "cb_value": 96, "cr_value": 160, "tail": "0000000141d008086b7fecfff7", "split": False},
    "reciprocal_cbe_cr1_160_096": {"cb_mask": 0xE, "cr_mask": 0x1, "cb_value": 160, "cr_value": 96, "tail": "0000000141d008086b7edd7ff6", "split": False},
    "reciprocal_cbe_cr1_096_096": {"cb_mask": 0xE, "cr_mask": 0x1, "cb_value": 96, "cr_value": 96, "tail": "0000000141d008086b7fecfff7", "split": False},
    "reciprocal_cbd_cr2_160_160": {"cb_mask": 0xD, "cr_mask": 0x2, "cb_value": 160, "cr_value": 160, "tail": "0000000141d008086b3addf5", "split": False},
    "reciprocal_cbd_cr2_096_160": {"cb_mask": 0xD, "cr_mask": 0x2, "cb_value": 96, "cr_value": 160, "tail": "0000000141d008086b3bed75", "split": False},
    "reciprocal_cbd_cr2_160_096": {"cb_mask": 0xD, "cr_mask": 0x2, "cb_value": 160, "cr_value": 96, "tail": "0000000141d008086b3addf5", "split": False},
    "reciprocal_cbd_cr2_096_096": {"cb_mask": 0xD, "cr_mask": 0x2, "cb_value": 96, "cr_value": 96, "tail": "0000000141d008086b3bed75", "split": False},
    "reciprocal_cb7_cr8_160_160": {"cb_mask": 0x7, "cr_mask": 0x8, "cb_value": 160, "cr_value": 160, "tail": "0000000141d008086b7eddf5ff", "split": False},
    "reciprocal_cb7_cr8_096_160": {"cb_mask": 0x7, "cr_mask": 0x8, "cb_value": 96, "cr_value": 160, "tail": "0000000141d008086b7bce757f", "split": False},
    "reciprocal_cb7_cr8_160_096": {"cb_mask": 0x7, "cr_mask": 0x8, "cb_value": 160, "cr_value": 96, "tail": "0000000141d008086b7eddf5ff", "split": False},
    "reciprocal_cb7_cr8_096_096": {"cb_mask": 0x7, "cr_mask": 0x8, "cb_value": 96, "cr_value": 96, "tail": "0000000141d008086b7bce757f", "split": False},
}


def build_debug_sim() -> Path:
    workspace = Path(stage_workspace("h264_cabac_high_amp_trace_"))
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
    print(f"[INFO] HIGH_AMP_TRACE workspace={workspace} sim={sim}")
    return sim


def run_rtl_case(sim: Path, name: str, spec: dict[str, Any]) -> tuple[Path, Path, str]:
    fixture = make_fixture(int(spec["cb_mask"]), int(spec["cr_mask"]), int(spec["cb_value"]), int(spec["cr_value"]))
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    h264 = OUT_DIR / f"{name}.h264"
    sim_log = OUT_DIR / f"{name}.sim.log"
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


def high_payload_ctx_summary(text: str) -> list[tuple[int, int, int, int]]:
    """Return (block, kind, selector, count) rows for split high-bank payload contexts."""
    counts: dict[tuple[int, int, int], int] = {}
    for line in text.splitlines():
        if "[CABACCTX]" not in line or "cat=2" not in line:
            continue
        m = re.search(r"blk=(\d+).*kind=(22|23|24) sel=(\d+)", line)
        if not m:
            continue
        block = int(m.group(1))
        kind = int(m.group(2))
        selector = int(m.group(3))
        if selector >= 16:
            key = (block, kind, selector)
            counts[key] = counts.get(key, 0) + 1
    return [(block, kind, selector, count) for (block, kind, selector), count in sorted(counts.items())]


def check_case(sim: Path, name: str, spec: dict[str, Any]) -> None:
    fixture, h264, text = run_rtl_case(sim, name, spec)
    stream = h264.read_bytes()
    tail = final_slice_hex(stream, name)
    if tail != spec["tail"]:
        raise SystemExit(f"[FAIL] HIGH_AMP_TRACE {name} tail {tail}, expected {spec['tail']}")
    raw, err = decode_raw(h264)
    if err.strip():
        raise SystemExit(f"[FAIL] HIGH_AMP_TRACE {name} expected strict FFmpeg, got {err.strip()!r}")
    if len(raw) != EXPECTED_BYTES:
        raise SystemExit(f"[FAIL] HIGH_AMP_TRACE {name} decoded {len(raw)}/{EXPECTED_BYTES} bytes")
    assert_planes(int(spec["cb_mask"]), int(spec["cr_mask"]), fixture, raw, int(spec["cb_value"]), int(spec["cr_value"]))
    selects = payload_ctx_selects(text)
    saw_split_bank = any(sel >= 16 for sel in selects)
    if bool(spec["split"]) != saw_split_bank:
        raise SystemExit(
            f"[FAIL] HIGH_AMP_TRACE {name} split-bank visibility {saw_split_bank}, "
            f"expected {spec['split']}; selects={selects[:24]}"
        )
    high_summary = high_payload_ctx_summary(text)
    expected_high_summary = (
        [(4 + idx, 24, 17, 5) for idx in range(4) if (int(spec["cr_mask"]) >> idx) & 1]
        if bool(spec["split"])
        else []
    )
    if high_summary != expected_high_summary:
        raise SystemExit(
            f"[FAIL] HIGH_AMP_TRACE {name} high-bank payload context summary "
            f"{high_summary}, expected {expected_high_summary}"
        )
    print(
        f"[PASS] HIGH_AMP_TRACE {name}: strict two-frame decode tail={tail}, "
        f"split_bank={saw_split_bank}, high_payload_ctx={high_summary}, "
        f"payload_ctx_selects_sample={selects[:12]}"
    )


def main() -> int:
    sim = build_debug_sim()
    for name, spec in CASES.items():
        check_case(sim, name, spec)
    print(
        "[PASS] CABAC P16x16 high-amplitude chroma-AC trace probe: former Cb0x2/Cr0xd "
        "and Cb0x4/Cr0xb miss families strict-decode through the scoped Cr payload "
        "context bank while the mixed-sign Cb0x1/Cr0xe, Cb0x8/Cr0x7, and reciprocal "
        "Cb0xe/Cr0x1, Cb0xd/Cr0x2, and Cb0x7/Cr0x8 controls remain shared."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
