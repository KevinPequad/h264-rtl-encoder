#!/usr/bin/env python3
"""Reject the broad CBF-walk repair for high-amplitude checker Cb+Cr AC.

The scoped plane-local CBF walk fixed specific high-amplitude complement lanes,
but the remaining complementary-checker Cr-negative misses are not repaired by
simply adding the whole `Cb0x5/Cr0xA` / `Cb0xA/Cr0x5` families to that path.
This staged probe patches only an isolated workspace and proves that widening
that selector would regress an already-strict Cr-positive checker lane.
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from scripts.rtl_runner import BuildConfig, build_sim, stage_workspace  # noqa: E402
from scripts.run_cabac_p16x16_chroma_ac_cross_plane_first_payload_probe import (  # noqa: E402
    check_expected_miss,
    decode_raw,
    final_slice_hex,
    make_fixture,
    run_case,
)

OLD_SELECTOR = """                  ((cabac_chroma_ac_cb_plane_nz_mask() == 4'h6) &&
                   (cabac_chroma_ac_cr_plane_nz_mask() == 4'h9) &&
                   !cabac_chroma_ac_cr_plane_has_negative()) ||
                  ((cabac_chroma_ac_cb_plane_nz_mask() == 4'h9) &&
                   (cabac_chroma_ac_cr_plane_nz_mask() == 4'h6))))) begin"""

WIDE_CHECKER_SELECTOR = """                  ((cabac_chroma_ac_cb_plane_nz_mask() == 4'h6) &&
                   (cabac_chroma_ac_cr_plane_nz_mask() == 4'h9) &&
                   !cabac_chroma_ac_cr_plane_has_negative()) ||
                  ((cabac_chroma_ac_cb_plane_nz_mask() == 4'h9) &&
                   (cabac_chroma_ac_cr_plane_nz_mask() == 4'h6)) ||
                  (cabac_chroma_ac_cr_plane_has_negative() &&
                   (((cabac_chroma_ac_cb_plane_nz_mask() == 4'h5) &&
                     (cabac_chroma_ac_cr_plane_nz_mask() == 4'ha)) ||
                    ((cabac_chroma_ac_cb_plane_nz_mask() == 4'ha) &&
                     (cabac_chroma_ac_cr_plane_nz_mask() == 4'h5))))))) begin"""

# The canonical source strict-decodes this Cr-positive checker lane with this
# tail.  The staged broad-CBF-walk patch mutates the final slice to the rejected
# tail below before decoding quality is even considered.
CANONICAL_STRICT_TAIL = "0000000141d008086b7fff"
REJECTED_WIDE_CBF_TAIL = "0000000141d008086bbecf"

# The same staged selector widening also fails to promote representative
# Cr-negative checker misses; keep these locked so future repair work does not
# retest this already-rejected selector path.
UNCHANGED_CR_NEGATIVE_MISSES = {
    (0x5, 0xA, 160, 96): (384, "bytestream -23", "0000000141d008086bbbff"),
    (0xA, 0x5, 160, 96): (384, "bytestream -15", "0000000141d008086bbfef"),
}


def build_wide_cbf_sim() -> Path:
    workspace = Path(stage_workspace("h264_checker_cbf_reject_"))
    bitstream = workspace / "rtl" / "h264_bitstream.v"
    text = bitstream.read_text(encoding="utf-8")
    if OLD_SELECTOR not in text:
        raise SystemExit("[FAIL] CHECKER_CBF_REJECT staged selector anchor missing")
    bitstream.write_text(text.replace(OLD_SELECTOR, WIDE_CHECKER_SELECTOR, 1), encoding="utf-8")
    config = BuildConfig(
        width=16,
        height=16,
        bit_depth=8,
        chroma_format_idc=1,
        jobs=int(os.environ.get("BUILD_JOBS", "1")),
        enable_idr_ipcm=1,
        ipcm_sad_threshold=0,
        enable_cabac_p16x16=1,
    )
    sim = Path(build_sim(workspace, config))
    print(f"[INFO] CHECKER_CBF_REJECT workspace={workspace} sim={sim}")
    return sim


def main() -> int:
    sim = build_wide_cbf_sim()
    cb_mask = 0x5
    cr_mask = 0xA
    cb_value = 160
    cr_value = 160
    fixture = make_fixture(cb_mask, cr_mask, cb_value, cr_value)
    h264 = run_case(sim, cb_mask, cr_mask, fixture, cb_value, cr_value)
    stream = h264.read_bytes()
    label = f"cb=0x{cb_mask:x} cr=0x{cr_mask:x} cb_value={cb_value} cr_value={cr_value}"
    tail = final_slice_hex(stream, label)
    if tail == CANONICAL_STRICT_TAIL:
        raise SystemExit(
            "[FAIL] CHECKER_CBF_REJECT broad checker CBF walk unexpectedly preserved "
            f"the canonical strict tail {tail}"
        )
    if tail != REJECTED_WIDE_CBF_TAIL:
        raise SystemExit(
            f"[FAIL] CHECKER_CBF_REJECT staged tail drift {tail}, "
            f"expected rejected tail {REJECTED_WIDE_CBF_TAIL}"
        )
    raw, err = decode_raw(h264)
    err_sig = err.strip().replace("\n", " | ") or "<none>"
    print(
        "[PASS] CHECKER_CBF_REJECT broad checker CBF-walk candidate regresses "
        f"the Cr-positive strict control: decoded={len(raw)} bytes, "
        f"tail={tail}, canonical_tail={CANONICAL_STRICT_TAIL}, ffmpeg={err_sig!r}"
    )
    for (cb_mask, cr_mask, cb_value, cr_value), (expected_bytes, expected_signature, expected_tail) in (
        UNCHANGED_CR_NEGATIVE_MISSES.items()
    ):
        check_expected_miss(
            sim,
            cb_mask,
            cr_mask,
            cb_value,
            cr_value,
            expected_bytes,
            expected_signature,
            expected_tail,
        )
    print(
        "[PASS] CABAC P16x16 checker high-amplitude Cr-negative repair target "
        "stays on CABAC arithmetic/renormalization or a narrower selector, not the "
        "Cr-negative-gated Cb0x5/Cr0xA + Cb0xA/Cr0x5 plane-local CBF walk"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
