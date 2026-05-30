#!/usr/bin/env python3
"""Staged CABAC residual context-writeback latency probe for sparse Cb AC.

This intentionally patches only a temporary rtl_runner workspace. It inserts a
residual-bin handoff bubble so h264_bitstream waits for the CABAC core context
writeback before accepting the next residual bin, then checks whether that
latency hypothesis promotes the remaining sparse Cb-only chroma-AC masks.
"""

from __future__ import annotations

from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from scripts.rtl_runner import BuildConfig, build_sim, stage_workspace

WIDTH = HEIGHT = 16
FRAME_SIZE = WIDTH * HEIGHT * 3 // 2
EXPECTED_BYTES = FRAME_SIZE * 2
CHROMA_SIZE = WIDTH * HEIGHT // 4
MASKS = (0x1, 0x2, 0x3, 0x4, 0x8, 0xC)
EXPECTED = {
    0x1: (FRAME_SIZE, "bytestream -19"),
    0x2: (FRAME_SIZE, "bytestream -21"),
    # The staged bubble regresses the otherwise-green top-pair control. Keep
    # this locked so the hypothesis cannot be mistaken for a repair.
    0x3: (FRAME_SIZE, "bytestream -8"),
    0x4: (EXPECTED_BYTES, ""),
    0x8: (EXPECTED_BYTES, ""),
    0xC: (FRAME_SIZE, "bytestream -12"),
}


def fixture_for_mask(mask: int) -> Path:
    flat = bytes([128]) * CHROMA_SIZE
    y0 = bytes([64]) * (WIDTH * HEIGHT)
    y1 = bytes([64]) * (WIDTH * HEIGHT)
    cb = bytes(
        136
        if (((mask >> ((y // 4) * 2 + (x // 4))) & 1) and ((x + y) & 1))
        else 128
        for y in range(HEIGHT // 2)
        for x in range(WIDTH // 2)
    )
    out_dir = Path("data")
    out_dir.mkdir(parents=True, exist_ok=True)
    out = out_dir / f"smoke_16x16_2f_cabac_p16x16_chroma_residual_cb_ac_ctx_latency_mask_{mask:x}.yuv"
    out.write_bytes(y0 + flat + flat + y1 + cb + flat)
    print(f"[INFO] CB_AC_CTX_LATENCY mask=0x{mask:x} fixture {out} size={out.stat().st_size}")
    return out


def patch_workspace(workspace: Path) -> None:
    rtl = workspace / "rtl" / "h264_bitstream.v"
    text = rtl.read_text(encoding="utf-8")
    marker = "    wire        cabac_res_bin_done;\n"
    insert = (
        "    wire        cabac_res_bin_done;\n"
        "    wire        cabac_res_writer_ready;\n\n"
        "    assign cabac_res_writer_ready = cabac_bin_ready && !cabac_bin_valid && !cabac_ctx_state_wr;\n"
    )
    if marker not in text:
        raise SystemExit("[FAIL] CB_AC_CTX_LATENCY could not find residual bin_done wire")
    text = text.replace(marker, insert, 1)

    old_ready = (
        "        .bin_valid(cabac_res_bin_valid),\n"
        "        .bin_ready(cabac_bin_ready),\n"
        "        .bin_value(cabac_res_bin_value),\n"
    )
    new_ready = (
        "        .bin_valid(cabac_res_bin_valid),\n"
        "        .bin_ready(cabac_res_writer_ready),\n"
        "        .bin_value(cabac_res_bin_value),\n"
    )
    if old_ready not in text:
        raise SystemExit("[FAIL] CB_AC_CTX_LATENCY could not find residual bin_ready hookup")
    text = text.replace(old_ready, new_ready, 1)

    old_emit = "                        if (cabac_res_bin_valid) begin\n"
    new_emit = "                        if (cabac_res_bin_valid && cabac_res_writer_ready) begin\n"
    if text.count(old_emit) != 1:
        raise SystemExit(f"[FAIL] CB_AC_CTX_LATENCY expected one residual emit guard, found {text.count(old_emit)}")
    text = text.replace(old_emit, new_emit, 1)
    rtl.write_text(text, encoding="utf-8")


def decoded_bytes(path: Path, raw: Path, ffmpeg_log: Path) -> int:
    with ffmpeg_log.open("w", encoding="utf-8") as log:
        subprocess.run(
            ["ffmpeg", "-y", "-v", "error", "-xerror", "-i", str(path), "-f", "rawvideo", "-pix_fmt", "yuv420p", str(raw)],
            stdout=log,
            stderr=subprocess.STDOUT,
            check=False,
        )
    return raw.stat().st_size if raw.exists() else 0


def main() -> int:
    fixtures = {mask: fixture_for_mask(mask) for mask in MASKS}
    workspace = stage_workspace("h264_cabac_cb_ac_ctx_latency_probe_")
    patch_workspace(workspace)
    sim = build_sim(
        workspace,
        BuildConfig(
            width=WIDTH,
            height=HEIGHT,
            bit_depth=8,
            chroma_format_idc=1,
            jobs=1,
            enable_idr_ipcm=1,
            ipcm_sad_threshold=0,
            enable_cabac_p16x16=1,
            debug_cabac_p16x16=1,
        ),
    )
    print(f"[INFO] CB_AC_CTX_LATENCY staged workspace {workspace}")

    out_dir = Path("output") / "cabac_cb_ac_ctx_latency_probe"
    out_dir.mkdir(parents=True, exist_ok=True)
    for mask in MASKS:
        h264 = out_dir / f"mask_{mask:x}.h264"
        sim_log = out_dir / f"mask_{mask:x}.sim.log"
        ffmpeg_log = out_dir / f"mask_{mask:x}.ffmpeg.log"
        raw = Path(f"/tmp/h264_cabac_cb_ac_ctx_latency_mask_{mask:x}.raw.yuv")
        raw.unlink(missing_ok=True)

        with sim_log.open("w", encoding="utf-8") as log:
            subprocess.run(
                [str(sim), "+frames=2", "+timeout=7000000", f"+input={Path.cwd() / fixtures[mask]}", f"+output={Path.cwd() / h264}", "+idr_interval=12"],
                stdout=log,
                stderr=subprocess.STDOUT,
                check=True,
            )
        sim_text = sim_log.read_text(encoding="utf-8", errors="replace")
        expected_blocks = int.bit_count(mask)
        for needle in (
            "cabac_p16x16_mbs=1",
            "cb_ac_mbs=1",
            "cr_ac_mbs=0",
            f"cb_ac_blocks={expected_blocks}",
            "cr_ac_blocks=0",
        ):
            if needle not in sim_text:
                raise SystemExit(f"[FAIL] CB_AC_CTX_LATENCY mask=0x{mask:x} sim log missing {needle}")

        got_bytes = decoded_bytes(h264, raw, ffmpeg_log)
        expected_size, signature = EXPECTED[mask]
        ff_text = ffmpeg_log.read_text(encoding="utf-8", errors="replace")
        if got_bytes != expected_size:
            raise SystemExit(
                f"[FAIL] CB_AC_CTX_LATENCY mask=0x{mask:x} decoded {got_bytes}/{EXPECTED_BYTES}, expected {expected_size}/{EXPECTED_BYTES}"
            )
        if signature:
            if signature not in ff_text:
                got_sig = re.search(r"bytestream -\d+", ff_text)
                raise SystemExit(
                    f"[FAIL] CB_AC_CTX_LATENCY mask=0x{mask:x} expected FFmpeg signature {signature!r}, "
                    f"got {(got_sig.group(0) if got_sig else ff_text.strip())!r}"
                )
            print(
                f"[PASS] CB_AC_CTX_LATENCY mask=0x{mask:x} staged handoff bubble still short-decodes "
                f"{got_bytes}/{EXPECTED_BYTES} with {signature}"
            )
        else:
            if ff_text.strip():
                raise SystemExit(f"[FAIL] CB_AC_CTX_LATENCY mask=0x{mask:x} expected clean FFmpeg log, got {ff_text.strip()!r}")
            src = fixtures[mask].read_bytes()
            dec = raw.read_bytes()
            u0 = FRAME_SIZE + WIDTH * HEIGHT
            v0 = u0 + CHROMA_SIZE
            u_sad = sum(abs(dec[u0 + i] - src[u0 + i]) for i in range(CHROMA_SIZE))
            v_sad = sum(abs(dec[v0 + i] - src[v0 + i]) for i in range(CHROMA_SIZE))
            if u_sad == 0 or v_sad != 0:
                raise SystemExit(f"[FAIL] CB_AC_CTX_LATENCY mask=0x{mask:x} expected Cb-only decoded delta, got U_SAD={u_sad} V_SAD={v_sad}")
            print(
                f"[PASS] CB_AC_CTX_LATENCY mask=0x{mask:x} staged handoff bubble keeps bottom-single control "
                f"strict-decodable {got_bytes}/{EXPECTED_BYTES} U_SAD={u_sad} V_SAD={v_sad}"
            )
        raw.unlink(missing_ok=True)

    print(
        "[PASS] CABAC P16x16 Cb-only chroma AC context-latency probe rejects the simple residual-bin "
        "writeback-bubble repair: top/split sparse masks still miss and the top-pair control regresses, while bottom-single controls stay green"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
