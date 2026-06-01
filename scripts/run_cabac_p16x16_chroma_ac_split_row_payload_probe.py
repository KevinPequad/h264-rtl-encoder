#!/usr/bin/env python3
"""Lock the remaining split-row Cb0x3/Cr0xc payload-bank miss.

The cross-plane chroma-AC gate intentionally leaves the high-amplitude
Cb0x3/Cr0xc positive-Cb/negative-Cr split-row directions as one-frame FFmpeg
misses.  This diagnostic keeps the source baseline exact and also rejects the
naive repair of adding that mask pair to the existing Cr-side split payload
context bank: the staged build moves the miss from bytestream -19 to -18, but
still decodes only the IDR frame.  Keeping that failed hypothesis executable
prevents future cron slices from re-trying the same context-bank extension.
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from scripts.rtl_runner import BuildConfig, build_sim, stage_workspace  # noqa: E402
from scripts.run_cabac_p16x16_chroma_ac_cross_plane_first_payload_probe import (  # noqa: E402
    EXPECTED_BYTES,
    FRAME_SIZE,
    build_baseline_sim,
    decode_raw,
    final_slice_hex,
    make_fixture,
    run_case,
)

CB_MASK = 0x3
CR_MASK = 0xC

SOURCE_SPLIT_CTX = """            cabac_chroma_ac_split_plane_ctx =
                ((cabac_chroma_ac_cb_plane_nz_mask() == 4'h2) &&
                 (cabac_chroma_ac_cr_plane_nz_mask() == 4'hd)) ||
                ((cabac_chroma_ac_cb_plane_nz_mask() == 4'h4) &&
                 (cabac_chroma_ac_cr_plane_nz_mask() == 4'hb));
"""

STAGED_SPLIT_CTX = """            cabac_chroma_ac_split_plane_ctx =
                ((cabac_chroma_ac_cb_plane_nz_mask() == 4'h2) &&
                 (cabac_chroma_ac_cr_plane_nz_mask() == 4'hd)) ||
                ((cabac_chroma_ac_cb_plane_nz_mask() == 4'h4) &&
                 (cabac_chroma_ac_cr_plane_nz_mask() == 4'hb)) ||
                ((cabac_chroma_ac_cb_plane_nz_mask() == 4'h3) &&
                 (cabac_chroma_ac_cr_plane_nz_mask() == 4'hc));
"""

EXPECTED_BASELINE_MISSES = {
    (160, 96): ("0000000141d008086bbacd", "bytestream -19"),
    (96, 96): ("0000000141d008086bbacd", "bytestream -19"),
}

EXPECTED_STAGED_MISSES = {
    (160, 96): ("0000000141d008086bfafe5f", "bytestream -18"),
    (96, 96): ("0000000141d008086bfafe5f", "bytestream -18"),
}


def check_miss(sim: Path, phase: str, cb_value: int, cr_value: int, expected_tail: str, expected_signature: str) -> None:
    label = f"cb=0x{CB_MASK:x} cr=0x{CR_MASK:x} cb_value={cb_value} cr_value={cr_value}"
    fixture = make_fixture(CB_MASK, CR_MASK, cb_value, cr_value)
    h264 = run_case(sim, CB_MASK, CR_MASK, fixture, cb_value, cr_value)
    tail = final_slice_hex(h264.read_bytes(), label)
    if tail != expected_tail:
        raise SystemExit(f"[FAIL] SPLIT_ROW_PAYLOAD {phase} {label} tail {tail}, expected {expected_tail}")
    raw, err = decode_raw(h264)
    if len(raw) != FRAME_SIZE or expected_signature not in err:
        raise SystemExit(
            f"[FAIL] SPLIT_ROW_PAYLOAD {phase} {label} expected one-frame miss "
            f"{FRAME_SIZE}/{EXPECTED_BYTES} with {expected_signature!r}, got "
            f"{len(raw)}/{EXPECTED_BYTES} err={err.strip()!r}"
        )
    print(
        f"[PASS] SPLIT_ROW_PAYLOAD {phase} {label}: remains scoped to "
        f"{len(raw)}/{EXPECTED_BYTES}, tail={tail}, signature={expected_signature!r}"
    )


def build_staged_cr_payload_split_sim() -> Path:
    os.environ["PATH"] = "/home/chudpc/.local/verilator-5.020/bin:" + os.environ.get("PATH", "")
    workspace = stage_workspace("h264_cabac_split_row_cr_payload_probe_")
    rtl = Path(workspace) / "rtl" / "h264_bitstream.v"
    text = rtl.read_text(encoding="utf-8")
    if SOURCE_SPLIT_CTX not in text:
        raise SystemExit("[FAIL] SPLIT_ROW_PAYLOAD staged split-context anchor missing")
    rtl.write_text(text.replace(SOURCE_SPLIT_CTX, STAGED_SPLIT_CTX), encoding="utf-8")
    sim = Path(
        build_sim(
            workspace,
            BuildConfig(
                width=16,
                height=16,
                bit_depth=8,
                chroma_format_idc=1,
                jobs=int(os.environ.get("BUILD_JOBS", "1")),
                enable_idr_ipcm=1,
                ipcm_sad_threshold=0,
                enable_cabac_p16x16=1,
            ),
        )
    )
    print(f"[INFO] SPLIT_ROW_PAYLOAD staged_cr_payload workspace={workspace} sim={sim}")
    return sim


def main() -> int:
    baseline_sim = build_baseline_sim()
    for (cb_value, cr_value), (expected_tail, expected_signature) in EXPECTED_BASELINE_MISSES.items():
        check_miss(baseline_sim, "baseline", cb_value, cr_value, expected_tail, expected_signature)

    staged_sim = build_staged_cr_payload_split_sim()
    for (cb_value, cr_value), (expected_tail, expected_signature) in EXPECTED_STAGED_MISSES.items():
        check_miss(staged_sim, "staged_cr_payload_split", cb_value, cr_value, expected_tail, expected_signature)

    print(
        "[PASS] CABAC P16x16 split-row Cb0x3/Cr0xc payload diagnostic locks "
        "the baseline positive-Cb/negative-Cr bytestream -19 misses and rejects "
        "the naive Cr-side split payload-bank extension, which remains a one-frame "
        "bytestream -18 miss."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
