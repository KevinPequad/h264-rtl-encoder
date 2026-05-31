#!/usr/bin/env python3
"""Integrated CABAC P16x16 luma + single-plane chroma-AC residual smoke gate.

The combined luma+Cb+Cr AC smoke gate proves the dense both-plane path, while
single-plane chroma gates prove chroma AC without luma residuals.  This focused
check covers the remaining mixed case: luma residual plus exactly one active
chroma AC plane.  It locks strict FFmpeg decode, plane-local CABAC counters,
CAVLC suppression, final P-slice bytes, and current decoded-plane metrics for
both Cb-only and Cr-only AC residuals.
"""

from __future__ import annotations

import os
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from scripts.rtl_runner import BuildConfig, build_sim, stage_workspace  # noqa: E402

WIDTH = HEIGHT = 16
LUMA_SIZE = WIDTH * HEIGHT
CHROMA_SIZE = (WIDTH // 2) * (HEIGHT // 2)
FRAME_SIZE = LUMA_SIZE + 2 * CHROMA_SIZE
EXPECTED_BYTES = FRAME_SIZE * 2
EXPECTED_CAVLC_SUPPRESSED_BITS = 190
EXPECTED_Y_SAD = 2048


@dataclass(frozen=True)
class Case:
    name: str
    cb_ac: bool
    cr_ac: bool
    expected_final_slice: str
    expected_u_sad: int
    expected_v_sad: int
    expected_cb_ac_mbs: int
    expected_cr_ac_mbs: int
    expected_cb_ac_blocks: int
    expected_cr_ac_blocks: int


CASES = (
    Case(
        name="cb_ac",
        cb_ac=True,
        cr_ac=False,
        expected_final_slice="0000000141d008086b3abeff",
        expected_u_sad=256,
        expected_v_sad=0,
        expected_cb_ac_mbs=1,
        expected_cr_ac_mbs=0,
        expected_cb_ac_blocks=4,
        expected_cr_ac_blocks=0,
    ),
    Case(
        name="cr_ac",
        cb_ac=False,
        cr_ac=True,
        expected_final_slice="0000000141d008086b3af7ef",
        expected_u_sad=0,
        expected_v_sad=256,
        expected_cb_ac_mbs=0,
        expected_cr_ac_mbs=1,
        expected_cb_ac_blocks=0,
        expected_cr_ac_blocks=4,
    ),
)


def checker_chroma() -> bytes:
    return bytes(136 if ((x + y) & 1) else 128 for y in range(HEIGHT // 2) for x in range(WIDTH // 2))


def make_fixture(case: Case) -> Path:
    data_dir = ROOT / "data"
    data_dir.mkdir(parents=True, exist_ok=True)
    path = data_dir / f"smoke_16x16_2f_cabac_p16x16_luma_{case.name}_residual.yuv"
    y0 = bytes([64]) * LUMA_SIZE
    flat_chroma = bytes([128]) * CHROMA_SIZE
    y1 = bytes([72]) * LUMA_SIZE
    cb1 = checker_chroma() if case.cb_ac else flat_chroma
    cr1 = checker_chroma() if case.cr_ac else flat_chroma
    path.write_bytes(y0 + flat_chroma + flat_chroma + y1 + cb1 + cr1)
    print(f"[INFO] LUMA_SINGLE_CHROMA_RES {case.name} fixture {path.relative_to(ROOT)} size={path.stat().st_size}")
    return path


def build_baseline_sim() -> Path:
    workspace = Path(stage_workspace("h264_cabac_luma_single_chroma_residual_"))
    config = BuildConfig(
        width=WIDTH,
        height=HEIGHT,
        bit_depth=8,
        chroma_format_idc=1,
        jobs=int(os.environ.get("BUILD_JOBS", "1")),
        enable_idr_ipcm=1,
        ipcm_sad_threshold=0,
        enable_cabac_p16x16=1,
    )
    sim = Path(build_sim(workspace, config))
    print(f"[INFO] LUMA_SINGLE_CHROMA_RES workspace={workspace} sim={sim}")
    return sim


def run_sim(sim: Path, fixture: Path, case: Case) -> tuple[Path, str]:
    out_dir = ROOT / "output"
    out_dir.mkdir(parents=True, exist_ok=True)
    h264 = out_dir / f"cabac_p16x16_luma_{case.name}_residual.h264"
    sim_log = out_dir / f"validation_cabac_p16x16_luma_{case.name}_residual.sim.log"
    with sim_log.open("w", encoding="utf-8") as log:
        subprocess.run(
            [
                str(sim),
                "+frames=2",
                "+timeout=5000000",
                f"+input={fixture}",
                f"+output={h264}",
                "+idr_interval=12",
            ],
            cwd=ROOT,
            stdout=log,
            stderr=subprocess.STDOUT,
            check=True,
        )
    return h264, sim_log.read_text(encoding="utf-8", errors="replace")


def final_slice_hex(stream: bytes) -> str:
    last_start = stream.rfind(b"\x00\x00\x00\x01")
    if last_start < 0:
        raise SystemExit("[FAIL] LUMA_SINGLE_CHROMA_RES missing final Annex-B start code")
    return stream[last_start:].hex()


def decode_raw(h264: Path, case: Case) -> tuple[bytes, str]:
    with tempfile.NamedTemporaryFile(prefix=f"h264_luma_{case.name}_residual_", suffix=".yuv", delete=False) as raw_tmp:
        raw_path = Path(raw_tmp.name)
    try:
        proc = subprocess.run(
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
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            check=False,
        )
        raw = raw_path.read_bytes() if raw_path.exists() else b""
        return raw, proc.stderr.decode("utf-8", "replace")
    finally:
        raw_path.unlink(missing_ok=True)


def check_sim_log(text: str, case: Case) -> None:
    forbidden = "[CABAC_PSUBSET]"
    if forbidden in text:
        raise SystemExit(f"[FAIL] LUMA_SINGLE_CHROMA_RES {case.name} hit CABAC subset guard {forbidden}")
    for needle in (
        "cabac_p16x16_mbs=1",
        "cabac_chroma_mbs=1",
        "cabac_chroma_dc_mbs=0",
        "cabac_chroma_ac_mbs=1",
        f"cabac_chroma_cb_ac_mbs={case.expected_cb_ac_mbs}",
        f"cabac_chroma_cr_ac_mbs={case.expected_cr_ac_mbs}",
        f"cabac_chroma_cb_ac_blocks={case.expected_cb_ac_blocks}",
        f"cabac_chroma_cr_ac_blocks={case.expected_cr_ac_blocks}",
        f"cavlc_suppressed_bits={EXPECTED_CAVLC_SUPPRESSED_BITS}",
        (
            f"cb_ac_mbs={case.expected_cb_ac_mbs} cr_ac_mbs={case.expected_cr_ac_mbs} "
            f"cb_ac_blocks={case.expected_cb_ac_blocks} cr_ac_blocks={case.expected_cr_ac_blocks}"
        ),
    ):
        if needle not in text:
            raise SystemExit(f"[FAIL] LUMA_SINGLE_CHROMA_RES {case.name} sim log missing {needle}")


def check_decoded_planes(fixture: Path, raw: bytes, case: Case) -> tuple[int, int, int]:
    if len(raw) != EXPECTED_BYTES:
        raise SystemExit(f"[FAIL] LUMA_SINGLE_CHROMA_RES {case.name} decoded {len(raw)}/{EXPECTED_BYTES} bytes")
    src = fixture.read_bytes()
    if raw[:FRAME_SIZE] != src[:FRAME_SIZE]:
        raise SystemExit(f"[FAIL] LUMA_SINGLE_CHROMA_RES {case.name} changed the IDR reference frame")
    frame1 = FRAME_SIZE
    u0 = frame1 + LUMA_SIZE
    v0 = u0 + CHROMA_SIZE
    y_sad = sum(abs(raw[frame1 + i] - src[frame1 + i]) for i in range(LUMA_SIZE))
    u_sad = sum(abs(raw[u0 + i] - src[u0 + i]) for i in range(CHROMA_SIZE))
    v_sad = sum(abs(raw[v0 + i] - src[v0 + i]) for i in range(CHROMA_SIZE))
    expected = (EXPECTED_Y_SAD, case.expected_u_sad, case.expected_v_sad)
    actual = (y_sad, u_sad, v_sad)
    if actual != expected:
        raise SystemExit(f"[FAIL] LUMA_SINGLE_CHROMA_RES {case.name} SAD YUV={actual}, expected {expected}")
    return actual


def run_case(sim: Path, case: Case) -> None:
    fixture = make_fixture(case)
    h264, sim_text = run_sim(sim, fixture, case)
    check_sim_log(sim_text, case)

    stream = h264.read_bytes()
    final_slice = final_slice_hex(stream)
    if final_slice != case.expected_final_slice:
        raise SystemExit(
            f"[FAIL] LUMA_SINGLE_CHROMA_RES {case.name} final P-slice drifted:\n"
            f"  got      {final_slice}\n"
            f"  expected {case.expected_final_slice}"
        )

    raw, err = decode_raw(h264, case)
    if err.strip():
        raise SystemExit(f"[FAIL] LUMA_SINGLE_CHROMA_RES {case.name} strict FFmpeg log {err.strip()!r}")
    y_sad, u_sad, v_sad = check_decoded_planes(fixture, raw, case)
    print(
        f"[PASS] CABAC P16x16 luma+{case.name.upper()} single-plane residual smoke strict-decodes "
        f"{len(raw)}/{EXPECTED_BYTES} bytes with cavlc_suppressed_bits={EXPECTED_CAVLC_SUPPRESSED_BITS}, "
        f"Y_SAD={y_sad} U_SAD={u_sad} V_SAD={v_sad}, final_slice={final_slice}"
    )


def main() -> int:
    sim = build_baseline_sim()
    for case in CASES:
        run_case(sim, case)
    print("[PASS] CABAC P16x16 luma plus single-plane Cb/Cr AC residual smoke cases strict-decode with plane-local counters")
    return 0


if __name__ == "__main__":
    sys.exit(main())
