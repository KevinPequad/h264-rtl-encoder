#!/usr/bin/env python3
"""Reject a naive plane-local-neighbor CBF selector patch for sparse Cb AC.

This is a staged diagnostic only: it patches a temporary RTL workspace, builds the
16x16 CABAC P16x16 path, and verifies that replacing the current sparse Cb-only
CBF walk with direct plane-local neighbour derivation regresses both known green
controls and known red sparse masks to one-frame FFmpeg misses.  It keeps the
repair search away from repeating that already-rejected selector hypothesis.
"""

from __future__ import annotations

from pathlib import Path
import os
import re
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from scripts.rtl_runner import BuildConfig, build_sim, stage_workspace
WIDTH = HEIGHT = 16
FRAME_SIZE = WIDTH * HEIGHT * 3 // 2
EXPECTED_BYTES = 2 * FRAME_SIZE
MASKS = (0x1, 0x2, 0x3, 0x4, 0x8, 0xC)
EXPECTED_SIGNATURES = {
    0x1: "bytestream -9",
    0x2: "bytestream -15",
    0x3: "bytestream -6",
    0x4: "bytestream -15",
    0x8: "bytestream -23",
    0xC: "bytestream -22",
}

SPARSE_SYNTHETIC_WALK = """            if ((block_i < CABAC_CHROMA_AC_BLOCKS_PER_PLANE) &&
                cabac_chroma_ac_cb_plane_any_nz() &&
                !cabac_chroma_ac_cb_plane_full_nz() &&
                !cabac_chroma_ac_cr_plane_any_nz()) begin
                // Sparse Cb-only AC needs a dedicated CBF context walk: the
                // top-row sparse misses stay isolated, while bottom-row sparse Cb
                // now strict-decodes without perturbing dense Cb/Cr or Cr-only.
                case (plane_block_i)
                    3'd0: begin left_coded_i = 1'b1; top_coded_i = 1'b0; end
                    3'd1: begin left_coded_i = 1'b1; top_coded_i = 1'b0; end
                    3'd2: begin left_coded_i = 1'b1; top_coded_i = 1'b1; end
                    default: begin left_coded_i = 1'b0; top_coded_i = 1'b0; end
                endcase
            end else if ((block_i < CABAC_CHROMA_AC_BLOCKS_PER_PLANE) && cabac_chroma_ac_cr_plane_full_nz()) begin"""

PLANE_LOCAL_NEIGHBOR_WALK = """            if ((block_i < CABAC_CHROMA_AC_BLOCKS_PER_PLANE) &&
                cabac_chroma_ac_cb_plane_any_nz() &&
                !cabac_chroma_ac_cb_plane_full_nz() &&
                !cabac_chroma_ac_cr_plane_any_nz()) begin
                left_coded_i = plane_block_i[0] ? cabac_chroma_ac_block_nz_for(block_i - 4'd1) : 1'b0;
                top_coded_i = (plane_block_i >= 3'd2) ? cabac_chroma_ac_block_nz_for(block_i - 4'd2) : 1'b0;
            end else if ((block_i < CABAC_CHROMA_AC_BLOCKS_PER_PLANE) && cabac_chroma_ac_cr_plane_full_nz()) begin"""


def fixture_for_mask(mask: int, out_dir: Path) -> Path:
    y0 = bytes([64]) * (WIDTH * HEIGHT)
    y1 = bytes([64]) * (WIDTH * HEIGHT)
    flat = bytes([128]) * ((WIDTH // 2) * (HEIGHT // 2))
    cb = bytes(
        136
        if (((mask >> ((y // 4) * 2 + (x // 4))) & 1) and ((x + y) & 1))
        else 128
        for y in range(HEIGHT // 2)
        for x in range(WIDTH // 2)
    )
    path = out_dir / f"smoke_16x16_2f_cabac_p16x16_neighbor_cbf_mask_{mask:x}.yuv"
    path.write_bytes(y0 + flat + flat + y1 + cb + flat)
    print(f"[INFO] CB_AC_NEIGHBOR_CBF mask=0x{mask:x} fixture {path.relative_to(ROOT)} size={path.stat().st_size}")
    return path


def patch_workspace() -> Path:
    workspace = stage_workspace("h264_cabac_cb_ac_neighbor_cbf_probe_")
    rtl = workspace / "rtl" / "h264_bitstream.v"
    text = rtl.read_text(encoding="utf-8")
    if SPARSE_SYNTHETIC_WALK not in text:
        raise SystemExit("[FAIL] CB_AC_NEIGHBOR_CBF staged patch anchor missing")
    rtl.write_text(text.replace(SPARSE_SYNTHETIC_WALK, PLANE_LOCAL_NEIGHBOR_WALK), encoding="utf-8")
    return workspace


def decode(h264: Path, raw_path: Path, ffmpeg_log: Path) -> tuple[int, str]:
    with ffmpeg_log.open("w", encoding="utf-8") as log:
        subprocess.run(
            [
                "ffmpeg",
                "-y",
                "-v",
                "error",
                "-xerror",
                "-i",
                str(h264),
                "-f",
                "rawvideo",
                "-pix_fmt",
                "yuv420p",
                str(raw_path),
            ],
            cwd=ROOT,
            stdout=log,
            stderr=subprocess.STDOUT,
            check=False,
        )
    return (raw_path.stat().st_size if raw_path.exists() else 0, ffmpeg_log.read_text(errors="ignore"))


def run_case(sim: Path, mask: int, fixture: Path, out_dir: Path) -> None:
    h264 = out_dir / f"mask_{mask:x}.h264"
    sim_log = out_dir / f"mask_{mask:x}.sim.log"
    ffmpeg_log = out_dir / f"mask_{mask:x}.ffmpeg.log"
    raw_path = Path(tempfile.mktemp(prefix=f"h264_neighbor_cbf_{mask:x}_", suffix=".yuv"))
    with sim_log.open("w", encoding="utf-8") as log:
        subprocess.run(
            [str(sim), "+frames=2", "+timeout=5000000", f"+input={fixture}", f"+output={h264}", "+idr_interval=12"],
            cwd=ROOT,
            stdout=log,
            stderr=subprocess.STDOUT,
            check=True,
        )
    sim_text = sim_log.read_text(errors="ignore")
    for needle in ("cabac_p16x16_mbs=1", "cb_ac_mbs=1", f"cb_ac_blocks={bin(mask).count('1')}", "cr_ac_blocks=0"):
        if needle not in sim_text:
            raise SystemExit(f"[FAIL] CB_AC_NEIGHBOR_CBF mask=0x{mask:x} sim log missing {needle}")
    decoded_bytes, ffmpeg_text = decode(h264, raw_path, ffmpeg_log)
    raw_path.unlink(missing_ok=True)
    expected_signature = EXPECTED_SIGNATURES[mask]
    got_signature = re.search(r"bytestream -\d+", ffmpeg_text)
    if decoded_bytes != FRAME_SIZE or expected_signature not in ffmpeg_text:
        raise SystemExit(
            f"[FAIL] CB_AC_NEIGHBOR_CBF mask=0x{mask:x} expected staged neighbor walk to stay one-frame "
            f"{FRAME_SIZE}/{EXPECTED_BYTES} with {expected_signature!r}, got {decoded_bytes}/{EXPECTED_BYTES} "
            f"{got_signature.group(0) if got_signature else ffmpeg_text.strip()!r}"
        )
    print(
        f"[PASS] CB_AC_NEIGHBOR_CBF mask=0x{mask:x} staged plane-local-neighbor CBF walk "
        f"short-decodes {decoded_bytes}/{EXPECTED_BYTES} with {expected_signature}"
    )


def main() -> int:
    os.environ["PATH"] = "/home/chudpc/.local/verilator-5.020/bin:" + os.environ.get("PATH", "")
    out_dir = ROOT / "output" / "cabac_cb_ac_neighbor_cbf_probe"
    out_dir.mkdir(parents=True, exist_ok=True)
    fixtures = {mask: fixture_for_mask(mask, out_dir) for mask in MASKS}
    sim = build_sim(
        patch_workspace(),
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
    for mask in MASKS:
        run_case(sim, mask, fixtures[mask], out_dir)
    print(
        "[PASS] CABAC P16x16 sparse Cb AC neighbor-CBF diagnostic rejects direct plane-local neighbor "
        "selector restoration: all representative failing masks and former green controls remain one-frame FFmpeg misses"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
