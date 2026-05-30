#!/usr/bin/env python3
"""Probe whether unary coeff_abs_level_remaining promotes sparse Cb AC.

This diagnostic patches only a staged RTL workspace.  The Cb-only sparse
chroma-AC blocker is sensitive to residual payload/arithmetic state, so this
probe replaces the current fixed-binary residual level suffix scaffold with a
small H.264-style unary stop-bit suffix in the staged copy and verifies that it
is not sufficient to promote representative failing masks, while strict controls
stay green.
"""

from __future__ import annotations

import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from scripts.rtl_runner import BuildConfig, build_sim, stage_workspace  # noqa: E402

WIDTH = HEIGHT = 16
FRAME_SIZE = WIDTH * HEIGHT * 3 // 2
EXPECTED_BYTES = FRAME_SIZE * 2
MASKS = (0x1, 0x2, 0x3, 0x4, 0xC)
EXPECTED_FULL = {0x3, 0x4}
EXPECTED_SHORT_SIGNATURES = {
    0x1: "bytestream -19",
    0x2: "bytestream -21",
    0xC: "bytestream -18",
}


def make_fixture(mask: int) -> Path:
    y0 = bytes([64]) * (WIDTH * HEIGHT)
    y1 = bytes([64]) * (WIDTH * HEIGHT)
    flat_chroma = bytes([128]) * ((WIDTH // 2) * (HEIGHT // 2))
    cb = []
    for y in range(HEIGHT // 2):
        for x in range(WIDTH // 2):
            block = (1 if x >= 4 else 0) + (2 if y >= 4 else 0)
            cb.append(136 if ((mask >> block) & 1 and ((x + y) & 1)) else 128)
    out = ROOT / "data" / f"smoke_16x16_2f_cabac_p16x16_chroma_residual_cb_ac_level_suffix_mask_{mask:x}.yuv"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_bytes(y0 + flat_chroma + flat_chroma + y1 + bytes(cb) + flat_chroma)
    print(f"[INFO] level-suffix mask=0x{mask:x} fixture {out.relative_to(ROOT)} size={out.stat().st_size}")
    return out


def patch_level_suffix(workspace: Path) -> None:
    path = workspace / "rtl" / "h264_cabac_residual4x4_bins.v"
    text = path.read_text(encoding="utf-8")
    old_func = """    function automatic [3:0] suffix_len_for;
        input [COEFF_W-1:0] value;
        reg [COEFF_W-1:0] tmp;
        integer i;
        begin
            // Minimal unary-prefix + fixed binary suffix scaffold for
            // coeff_abs_level_minus1 values greater than 2. The first two bins
            // (greater-than-one and greater-than-two) are regular-context bins;
            // remaining payload is bypass. This is intentionally simple and
            // deterministic for integration bring-up. Keep the length detector
            // bounded/synthesis-friendly; do not use a data-dependent while loop.
            tmp = (value > {{(COEFF_W-2){1'b0}}, 2'd2}) ? (value - {{(COEFF_W-2){1'b0}}, 2'd3}) : {COEFF_W{1'b0}};
            suffix_len_for = 4'd0;
            for (i = 0; i < COEFF_W; i = i + 1) begin
                if (tmp[i])
                    suffix_len_for = i[3:0] + 4'd1;
            end
        end
    endfunction
"""
    new_func = """    function automatic [3:0] suffix_len_for;
        input [COEFF_W-1:0] value;
        reg [COEFF_W-1:0] tmp;
        begin
            // Staged probe: unary coeff_abs_level_remaining for small symbols,
            // codeNum=(level_abs-3), encoded as codeNum one-bits plus a stop zero.
            tmp = (value > {{(COEFF_W-2){1'b0}}, 2'd2}) ? (value - {{(COEFF_W-2){1'b0}}, 2'd3}) : {COEFF_W{1'b0}};
            suffix_len_for = tmp[3:0] + 4'd1;
        end
    endfunction
"""
    old_emit = """                            emit_bin(suffix_value[suffix_bits_total - 4'd1 - suffix_bit_idx], 1'b1, 9'd0);
"""
    new_emit = """                            emit_bin((suffix_bit_idx < suffix_value[3:0]) ? 1'b1 : 1'b0, 1'b1, 9'd0);
"""
    if old_func not in text or old_emit not in text:
        raise RuntimeError("level-suffix probe patch anchor not found")
    text = text.replace(old_func, new_func).replace(old_emit, new_emit)
    path.write_text(text, encoding="utf-8")


def run_case(sim: Path, mask: int, input_path: Path) -> None:
    out_dir = ROOT / "output" / "cabac_chroma_cb_ac_level_suffix_probe"
    out_dir.mkdir(parents=True, exist_ok=True)
    h264 = out_dir / f"mask_{mask:x}.h264"
    sim_log = out_dir / f"mask_{mask:x}.sim.log"
    ffmpeg_log = out_dir / f"mask_{mask:x}.ffmpeg.log"
    raw_path = Path(tempfile.mktemp(prefix=f"h264_level_suffix_mask_{mask:x}_", suffix=".yuv"))

    with sim_log.open("w", encoding="utf-8") as log:
        subprocess.run(
            [str(sim), "+frames=2", "+timeout=5000000", f"+input={input_path}", f"+output={h264}", "+idr_interval=12"],
            cwd=ROOT,
            stdout=log,
            stderr=subprocess.STDOUT,
            check=True,
        )
    sim_text = sim_log.read_text(errors="ignore")
    expected_blocks = bin(mask).count("1")
    for needle in ("cabac_p16x16_mbs=1", "cb_ac_mbs=1", "cr_ac_mbs=0", f"cb_ac_blocks={expected_blocks}", "cr_ac_blocks=0"):
        if needle not in sim_text:
            raise SystemExit(f"[FAIL] level-suffix mask=0x{mask:x} sim log missing {needle}")

    with ffmpeg_log.open("w", encoding="utf-8") as log:
        subprocess.run(
            ["ffmpeg", "-y", "-v", "error", "-xerror", "-i", str(h264), "-f", "rawvideo", "-pix_fmt", "yuv420p", str(raw_path)],
            cwd=ROOT,
            stdout=log,
            stderr=subprocess.STDOUT,
            check=False,
        )
    actual_bytes = raw_path.stat().st_size if raw_path.exists() else 0

    if mask in EXPECTED_FULL:
        if actual_bytes != EXPECTED_BYTES:
            raise SystemExit(f"[FAIL] level-suffix mask=0x{mask:x} decoded {actual_bytes}/{EXPECTED_BYTES}, expected strict-pass control")
        print(f"[PASS] level-suffix mask=0x{mask:x} strict-pass control remains full {actual_bytes}/{EXPECTED_BYTES}")
    else:
        expected_signature = EXPECTED_SHORT_SIGNATURES[mask]
        ff_text = ffmpeg_log.read_text(errors="ignore")
        if actual_bytes != FRAME_SIZE or expected_signature not in ff_text:
            raise SystemExit(
                f"[FAIL] level-suffix mask=0x{mask:x} expected isolated {FRAME_SIZE}/{EXPECTED_BYTES} miss "
                f"with {expected_signature!r}, got {actual_bytes}/{EXPECTED_BYTES}: {ff_text.strip()!r}"
            )
        print(f"[PASS] level-suffix mask=0x{mask:x} still short-decodes {actual_bytes}/{EXPECTED_BYTES} with FFmpeg signature {expected_signature}")
    raw_path.unlink(missing_ok=True)


def main() -> int:
    os.environ["PATH"] = "/home/chudpc/.local/verilator-5.020/bin:" + os.environ.get("PATH", "")
    fixtures = {mask: make_fixture(mask) for mask in MASKS}
    workspace = stage_workspace("h264_cabac_level_suffix_probe_")
    patch_level_suffix(workspace)
    sim = Path(
        build_sim(
            workspace,
            BuildConfig(
                width=WIDTH,
                height=HEIGHT,
                bit_depth=8,
                chroma_format_idc=1,
                jobs=int(os.environ.get("BUILD_JOBS", "1")),
                enable_idr_ipcm=1,
                ipcm_sad_threshold=0,
                enable_cabac_p16x16=1,
            ),
        )
    )
    for mask in MASKS:
        run_case(sim, mask, fixtures[mask])
    print(
        "[PASS] CABAC Cb AC level-suffix probe rejected: staged unary stop-bit level suffix does not promote "
        "representative sparse Cb AC masks to full 768/768 decode; strict controls remain green"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
