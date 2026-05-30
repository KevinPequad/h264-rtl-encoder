#!/usr/bin/env python3
"""Probe whether sharing CABAC chroma-AC CBF state fixes sparse Cb AC.

This is intentionally diagnostic: it patches only a staged RTL workspace, never
this checkout.  The current blocker is sparse Cb-only chroma AC top-row masks;
this probe locks that a tempting Cb/Cr CBF-state merge does not promote those
masks and also regresses an already-strict bottom-row sparse Cb control.
"""

from __future__ import annotations

import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from scripts.rtl_runner import BuildConfig, build_sim, stage_workspace

FRAME_SIZE = 16 * 16 * 3 // 2
EXPECTED_BYTES = FRAME_SIZE * 2


def make_fixture(mask: int) -> Path:
    width = height = 16
    y0 = bytes([64]) * (width * height)
    y1 = bytes([64]) * (width * height)
    flat_chroma = bytes([128]) * ((width // 2) * (height // 2))
    cb = []
    for y in range(height // 2):
        for x in range(width // 2):
            block = (1 if x >= 4 else 0) + (2 if y >= 4 else 0)
            cb.append(136 if ((mask >> block) & 1 and ((x + y) % 2)) else 128)
    out = ROOT / "data" / f"smoke_16x16_2f_cabac_p16x16_chroma_residual_cb_ac_shared_cbf_mask_{mask:x}.yuv"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_bytes(y0 + flat_chroma + flat_chroma + y1 + bytes(cb) + flat_chroma)
    print(f"[INFO] shared-CBF mask=0x{mask:x} fixture {out.relative_to(ROOT)} size={out.stat().st_size}")
    return out


def patch_shared_cbf(workspace: Path) -> None:
    path = workspace / "rtl" / "h264_bitstream.v"
    text = path.read_text(encoding="utf-8")
    replacements = [
        (
            """                    CABAC_CTX_RES_CHRAC_CBF: begin\n                        if (cabac_pending_ctx_sel[2])\n                            cabac_res_chroma_ac_cr_cbf_ctx_state[cabac_pending_ctx_sel[1:0]] <= cabac_ctx_state_out;\n                        else\n                            cabac_res_chroma_ac_cbf_ctx_state[cabac_pending_ctx_sel[1:0]] <= cabac_ctx_state_out;\n                    end""",
            """                    CABAC_CTX_RES_CHRAC_CBF: begin\n                        cabac_res_chroma_ac_cbf_ctx_state[cabac_pending_ctx_sel[1:0]] <= cabac_ctx_state_out;\n                    end""",
        ),
        (
            """                                        if (cabac_res_block_idx >= CABAC_CHROMA_AC_BLOCKS_PER_PLANE)\n                                            cabac_ctx_state_in <= cabac_res_chroma_ac_cr_cbf_ctx_state[cabac_res_chroma_ac_cbf_ctx_sel_for(cabac_res_block_idx)];\n                                        else\n                                            cabac_ctx_state_in <= cabac_res_chroma_ac_cbf_ctx_state[cabac_res_chroma_ac_cbf_ctx_sel_for(cabac_res_block_idx)];""",
            """                                        cabac_ctx_state_in <= cabac_res_chroma_ac_cbf_ctx_state[cabac_res_chroma_ac_cbf_ctx_sel_for(cabac_res_block_idx)];""",
        ),
        (
            """                                            if (cabac_res_block_idx >= CABAC_CHROMA_AC_BLOCKS_PER_PLANE)\n                                                cabac_ctx_state_in <= cabac_res_chroma_ac_cr_cbf_ctx_state[cabac_res_bin_ctx_idx[1:0] - 2'd1];\n                                            else\n                                                cabac_ctx_state_in <= cabac_res_chroma_ac_cbf_ctx_state[cabac_res_bin_ctx_idx[1:0] - 2'd1];""",
            """                                            cabac_ctx_state_in <= cabac_res_chroma_ac_cbf_ctx_state[cabac_res_bin_ctx_idx[1:0] - 2'd1];""",
        ),
    ]
    for old, new in replacements:
        if old not in text:
            raise RuntimeError("shared-CBF probe patch anchor not found")
        text = text.replace(old, new)
    path.write_text(text, encoding="utf-8")


def run_case(sim: Path, mask: int, input_path: Path, expected_signature: str) -> tuple[int, str]:
    out_dir = ROOT / "output" / "cabac_chroma_ac_shared_cbf_probe"
    out_dir.mkdir(parents=True, exist_ok=True)
    h264 = out_dir / f"mask_{mask:x}.h264"
    sim_log = out_dir / f"mask_{mask:x}.sim.log"
    ffmpeg_log = out_dir / f"mask_{mask:x}.ffmpeg.log"
    raw_path = Path(tempfile.mktemp(prefix=f"h264_shared_cbf_mask_{mask:x}_", suffix=".yuv"))
    with sim_log.open("w", encoding="utf-8") as log:
        subprocess.run(
            [str(sim), "+frames=2", "+timeout=5000000", f"+input={input_path}", f"+output={h264}", "+idr_interval=12"],
            stdout=log,
            stderr=subprocess.STDOUT,
            check=True,
        )
    with ffmpeg_log.open("w", encoding="utf-8") as log:
        subprocess.run(
            ["ffmpeg", "-y", "-v", "error", "-xerror", "-i", str(h264), "-f", "rawvideo", "-pix_fmt", "yuv420p", str(raw_path)],
            stdout=log,
            stderr=subprocess.STDOUT,
            check=False,
        )
    actual_bytes = raw_path.stat().st_size if raw_path.exists() else 0
    raw_path.unlink(missing_ok=True)
    ff_text = ffmpeg_log.read_text(encoding="utf-8", errors="replace")
    if actual_bytes != FRAME_SIZE:
        raise SystemExit(f"[FAIL] shared-CBF mask=0x{mask:x} decoded {actual_bytes}/{EXPECTED_BYTES} bytes, expected isolated one-frame miss")
    if expected_signature not in ff_text:
        raise SystemExit(
            f"[FAIL] shared-CBF mask=0x{mask:x} FFmpeg log did not include {expected_signature!r}: {ff_text.strip()!r}"
        )
    return actual_bytes, expected_signature


def main() -> int:
    os.environ["PATH"] = "/home/chudpc/.local/verilator-5.020/bin:" + os.environ.get("PATH", "")
    fixtures = {mask: make_fixture(mask) for mask in (0x1, 0x2, 0x4)}
    workspace = stage_workspace("h264_cabac_shared_chrac_cbf_")
    patch_shared_cbf(workspace)
    sim = build_sim(
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
    expected = {0x1: "bytestream -19", 0x2: "bytestream -21", 0x4: "bytestream -6"}
    for mask, signature in expected.items():
        actual, sig = run_case(sim, mask, fixtures[mask], signature)
        note = "top-row still not promoted" if mask in (0x1, 0x2) else "bottom-left strict-pass regresses"
        print(f"[PASS] shared-CBF mask=0x{mask:x} {note}: one-frame miss {actual}/{EXPECTED_BYTES}, FFmpeg signature {sig}")
    print("[PASS] CABAC sparse Cb AC blocker is not solved by merging Cb/Cr chroma-AC CBF context state; top-row singles remain short and an existing bottom-row sparse Cb strict-pass regresses")
    return 0


if __name__ == "__main__":
    sys.exit(main())
