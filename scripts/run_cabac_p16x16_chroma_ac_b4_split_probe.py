#!/usr/bin/env python3
"""Reject simple split-context extensions for high-amplitude Cb0xb/Cr0x4.

The promoted high-amplitude cross-plane path currently scopes a separate Cr
payload context bank only for the Cb-singleton/Cr-all-but-one masks that were
repaired in the source.  This staged diagnostic patches temporary workspaces to
try the reciprocal Cb-all-but-one/Cr-singleton `0xb/0x4` mask through the
Cr-side, Cb-side, and both-plane payload-bank extensions, then proves the four
+/-32 sign combinations still short-decode.  That keeps the next repair search
from repeating these too-simple context-bank extensions.
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
    decode_raw,
    final_slice_hex,
    make_fixture,
    run_case,
)

CB_MASK = 0xB
CR_MASK = 0x4

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
                ((cabac_chroma_ac_cb_plane_nz_mask() == 4'hb) &&
                 (cabac_chroma_ac_cr_plane_nz_mask() == 4'h4));
"""

SOURCE_PAYLOAD_CTX_COND = "((cabac_res_block_idx >= CABAC_CHROMA_AC_BLOCKS_PER_PLANE) && cabac_chroma_ac_split_plane_ctx())"

STAGED_CB_PAYLOAD_CTX_COND = """(((cabac_res_block_idx >= CABAC_CHROMA_AC_BLOCKS_PER_PLANE) &&
                                           cabac_chroma_ac_split_plane_ctx() &&
                                           !((cabac_chroma_ac_cb_plane_nz_mask() == 4'hb) &&
                                             (cabac_chroma_ac_cr_plane_nz_mask() == 4'h4))) ||
                                          ((cabac_res_block_idx < CABAC_CHROMA_AC_BLOCKS_PER_PLANE) &&
                                           (cabac_chroma_ac_cb_plane_nz_mask() == 4'hb) &&
                                           (cabac_chroma_ac_cr_plane_nz_mask() == 4'h4)))"""

STAGED_DUAL_PAYLOAD_CTX_COND = "(cabac_chroma_ac_split_plane_ctx())"

# Exact final-slice tails observed after applying only each staged extension.
# All cases still produce a one-frame FFmpeg decode miss.
EXPECTED_MISSES = {
    "cr_payload_split": {
        (160, 160): ("0000000141d008086bfedffd73", "bytestream -3"),
        (160, 96): ("0000000141d008086bfedffd73", "bytestream -3"),
        (96, 160): ("0000000141d008086bffef7df2", "corrupt decoded frame"),
        (96, 96): ("0000000141d008086bffef7df2", "corrupt decoded frame"),
    },
    "cb_payload_split": {
        (160, 160): ("0000000141d008086bfacdf5f7", "bytestream -11"),
        (160, 96): ("0000000141d008086bfacdf5f7", "bytestream -11"),
        (96, 160): ("0000000141d008086bfafe77f7", "bytestream -23"),
        (96, 96): ("0000000141d008086bfafe77f7", "bytestream -23"),
    },
    "dual_payload_split": {
        (160, 160): ("0000000141d008086bfacdf577f4", "corrupt decoded frame"),
        (160, 96): ("0000000141d008086bfacdf577f4", "corrupt decoded frame"),
        (96, 160): ("0000000141d008086bfafe77f75d", "corrupt decoded frame"),
        (96, 96): ("0000000141d008086bfafe77f75d", "corrupt decoded frame"),
    },
}


def build_staged_sim(variant: str) -> Path:
    os.environ["PATH"] = "/home/chudpc/.local/verilator-5.020/bin:" + os.environ.get("PATH", "")
    workspace = stage_workspace(f"h264_cabac_b4_{variant}_probe_")
    rtl = Path(workspace) / "rtl" / "h264_bitstream.v"
    text = rtl.read_text(encoding="utf-8")
    if SOURCE_SPLIT_CTX not in text:
        raise SystemExit("[FAIL] B4_SPLIT staged patch anchor missing")
    text = text.replace(SOURCE_SPLIT_CTX, STAGED_SPLIT_CTX)
    if variant == "cb_payload_split":
        if SOURCE_PAYLOAD_CTX_COND not in text:
            raise SystemExit("[FAIL] B4_SPLIT staged payload-context anchor missing")
        text = text.replace(SOURCE_PAYLOAD_CTX_COND, STAGED_CB_PAYLOAD_CTX_COND)
    elif variant == "dual_payload_split":
        if SOURCE_PAYLOAD_CTX_COND not in text:
            raise SystemExit("[FAIL] B4_SPLIT staged payload-context anchor missing")
        text = text.replace(SOURCE_PAYLOAD_CTX_COND, STAGED_DUAL_PAYLOAD_CTX_COND)
    elif variant != "cr_payload_split":
        raise SystemExit(f"[FAIL] B4_SPLIT unknown staged variant {variant!r}")
    rtl.write_text(text, encoding="utf-8")
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
    print(f"[INFO] B4_SPLIT variant={variant} workspace={workspace} sim={sim}")
    return sim


def check_variant(variant: str) -> None:
    sim = build_staged_sim(variant)
    for (cb_value, cr_value), (expected_tail, expected_signature) in EXPECTED_MISSES[variant].items():
        label = f"cb=0x{CB_MASK:x} cr=0x{CR_MASK:x} cb_value={cb_value} cr_value={cr_value}"
        fixture = make_fixture(CB_MASK, CR_MASK, cb_value, cr_value)
        h264 = run_case(sim, CB_MASK, CR_MASK, fixture, cb_value, cr_value)
        tail = final_slice_hex(h264.read_bytes(), label)
        if tail != expected_tail:
            raise SystemExit(f"[FAIL] B4_SPLIT {label} tail {tail}, expected {expected_tail}")
        raw, err = decode_raw(h264)
        if len(raw) != FRAME_SIZE or expected_signature not in err:
            raise SystemExit(
                f"[FAIL] B4_SPLIT {label} expected staged split-context miss "
                f"{FRAME_SIZE}/{EXPECTED_BYTES} with {expected_signature!r}, got "
                f"{len(raw)}/{EXPECTED_BYTES} err={err.strip()!r}"
            )
        print(
            f"[PASS] B4_SPLIT {variant} {label}: staged split-context extension still short-decodes "
            f"{len(raw)}/{EXPECTED_BYTES}, tail={tail}, signature={expected_signature!r}"
        )


def main() -> int:
    for variant in EXPECTED_MISSES:
        check_variant(variant)
    print(
        "[PASS] CABAC P16x16 high-amplitude Cb0xb/Cr0x4 diagnostic rejects the naive "
        "Cr-side, Cb-side, and both-plane split-context extensions: all four +/-32 reciprocal "
        "complement cases remain one-frame FFmpeg misses"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
