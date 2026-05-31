#!/usr/bin/env python3
"""Probe whether waiting for CABAC terminate(1) output promotes sparse Cb AC.

This diagnostic patches only a staged RTL workspace.  The current Cb-only sparse
chroma-AC blocker has a tempting byte-tail hypothesis: the bitstream writer's
CABAC terminate(1) state advances after one cycle even when the arithmetic core
flush output is not visible until the next cycle.  This probe waits for either
CABAC output bits or cabac_done in that staged workspace and verifies that the
remaining failing sparse Cb masks still do not strict-decode, while known passing
controls stay green.
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
    0x1: "bytestream -24",
    0x2: "bytestream -22",
    0xC: "bytestream -15",
}


def make_fixture(mask: int) -> Path:
    y0 = bytes([64]) * (WIDTH * HEIGHT)
    y1 = bytes([64]) * (WIDTH * HEIGHT)
    flat_chroma = bytes([128]) * ((WIDTH // 2) * (HEIGHT // 2))
    cb = []
    for y in range(HEIGHT // 2):
        for x in range(WIDTH // 2):
            block = (1 if x >= 4 else 0) + (2 if y >= 4 else 0)
            cb.append(136 if ((mask >> block) & 1 and ((x + y) % 2)) else 128)
    out = ROOT / "data" / f"smoke_16x16_2f_cabac_p16x16_chroma_residual_cb_ac_terminate_wait_mask_{mask:x}.yuv"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_bytes(y0 + flat_chroma + flat_chroma + y1 + bytes(cb) + flat_chroma)
    print(f"[INFO] terminate-wait mask=0x{mask:x} fixture {out.relative_to(ROOT)} size={out.stat().st_size}")
    return out


def patch_terminate_wait(workspace: Path) -> None:
    path = workspace / "rtl" / "h264_bitstream.v"
    text = path.read_text(encoding="utf-8")
    old = """                            6'd20: begin
                                if (cabac_bits_overflow) begin
                                    `ifndef SYNTHESIS
                                    $fatal(1, \"[CABAC_PSKIP] CABAC terminate(1) bit overflow\");
                                    `endif
                                    end
                                cabac_slice_active <= 1'b0;
                                if (DEBUG_CABAC_P16X16)
                                    $display(\"[CABACTERM] mb=%0d count=%0d bits=%024x bit_cnt=%0d ari_low=%0h ari_range=%0d ari_queue=%0d ari_outstanding=%0d ari_pending=%0d ari_pbyte=%0h\",
                                             cabac_mb_counter, cabac_bits_count, cabac_bits_out[127:32], bit_cnt,
                                             cabac_debug_low, cabac_debug_range, cabac_debug_queue,
                                             cabac_debug_outstanding, cabac_debug_pending_valid, cabac_debug_pending_byte);
                                if (cabac_bits_valid) begin
                                    cabac_debug_header_bits();
                                    bit_buf <= bit_buf | ((cabac_bits_out[127:32]) >> bit_cnt[6:0]);
                                    bit_cnt <= bit_cnt + {1'b0, cabac_bits_count[6:0]};
                                    state <= S_EMIT;
                                    return_state <= S_TRAIL;
                                end
                                sub <= 6'd21;
                            end"""
    new = """                            6'd20: begin
                                if (cabac_bits_overflow) begin
                                    `ifndef SYNTHESIS
                                    $fatal(1, \"[CABAC_PSKIP] CABAC terminate(1) bit overflow\");
                                    `endif
                                    end
                                cabac_slice_active <= 1'b0;
                                if (DEBUG_CABAC_P16X16)
                                    $display(\"[CABACTERM] mb=%0d count=%0d bits=%024x bit_cnt=%0d ari_low=%0h ari_range=%0d ari_queue=%0d ari_outstanding=%0d ari_pending=%0d ari_pbyte=%0h\",
                                             cabac_mb_counter, cabac_bits_count, cabac_bits_out[127:32], bit_cnt,
                                             cabac_debug_low, cabac_debug_range, cabac_debug_queue,
                                             cabac_debug_outstanding, cabac_debug_pending_valid, cabac_debug_pending_byte);
                                if (cabac_bits_valid) begin
                                    cabac_debug_header_bits();
                                    bit_buf <= bit_buf | ((cabac_bits_out[127:32]) >> bit_cnt[6:0]);
                                    bit_cnt <= bit_cnt + {1'b0, cabac_bits_count[6:0]};
                                    state <= S_EMIT;
                                    return_state <= S_TRAIL;
                                    sub <= 6'd21;
                                end else if (cabac_done) begin
                                    sub <= 6'd21;
                                end
                            end"""
    if old not in text:
        raise RuntimeError("terminate-wait probe patch anchor not found; update the staged patch for current terminate debug instrumentation")
    path.write_text(text.replace(old, new), encoding="utf-8")


def run_case(sim: Path, mask: int, input_path: Path) -> int:
    out_dir = ROOT / "output" / "cabac_chroma_cb_ac_terminate_wait_probe"
    out_dir.mkdir(parents=True, exist_ok=True)
    h264 = out_dir / f"mask_{mask:x}.h264"
    sim_log = out_dir / f"mask_{mask:x}.sim.log"
    ffmpeg_log = out_dir / f"mask_{mask:x}.ffmpeg.log"
    raw_path = Path(tempfile.mktemp(prefix=f"h264_term_wait_mask_{mask:x}_", suffix=".yuv"))

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
    checks = ["cabac_p16x16_mbs=1", "cb_ac_mbs=1", "cr_ac_mbs=0", f"cb_ac_blocks={expected_blocks}", "cr_ac_blocks=0"]
    for needle in checks:
        if needle not in sim_text:
            raise SystemExit(f"[FAIL] terminate-wait mask=0x{mask:x} sim log missing {needle}")

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
            raise SystemExit(f"[FAIL] terminate-wait mask=0x{mask:x} decoded {actual_bytes}/{EXPECTED_BYTES}, expected strict-pass control")
        print(f"[PASS] terminate-wait mask=0x{mask:x} strict-pass control remains full {actual_bytes}/{EXPECTED_BYTES}")
    else:
        expected_signature = EXPECTED_SHORT_SIGNATURES[mask]
        ff_text = ffmpeg_log.read_text(errors="ignore")
        if actual_bytes != FRAME_SIZE or expected_signature not in ff_text:
            raise SystemExit(
                f"[FAIL] terminate-wait mask=0x{mask:x} expected isolated {FRAME_SIZE}/{EXPECTED_BYTES} miss "
                f"with {expected_signature!r}, got {actual_bytes}/{EXPECTED_BYTES}: {ff_text.strip()!r}"
            )
        print(
            f"[PASS] terminate-wait mask=0x{mask:x} still short-decodes {actual_bytes}/{EXPECTED_BYTES} "
            f"with shifted FFmpeg signature {expected_signature}"
        )
    raw_path.unlink(missing_ok=True)
    return actual_bytes


def main() -> int:
    os.environ["PATH"] = "/home/chudpc/.local/verilator-5.020/bin:" + os.environ.get("PATH", "")
    fixtures = {mask: make_fixture(mask) for mask in MASKS}
    workspace = stage_workspace("h264_cabac_term_wait_probe_")
    patch_terminate_wait(workspace)
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
        "[PASS] CABAC terminate(1) wait probe rejected: waiting for staged flush output changes failing-mask "
        "signatures but does not promote sparse Cb AC to full 768/768 decode; strict controls remain green"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
