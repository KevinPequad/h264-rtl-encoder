#!/usr/bin/env python3
"""Integrated CABAC P16x16 luma+chroma residual smoke gate.

The existing promoted gates cover luma-only residuals and chroma-only DC/AC
residuals separately.  This focused check drives a single P_L0_16x16 macroblock
with both luma residual and both-plane chroma AC residual present, then locks the
current strict-decode behavior, CABAC/chroma counters, CAVLC suppression count,
final P-slice bytes, and decoded-plane metrics.  It is intentionally a smoke
case rather than a full quality claim: the luma plane still carries the current
quantized mismatch, so this gate records that fact instead of hiding it.
"""

from __future__ import annotations

import os
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from scripts.rtl_runner import BuildConfig, build_sim, stage_workspace  # noqa: E402

WIDTH = HEIGHT = 16
LUMA_SIZE = WIDTH * HEIGHT
CHROMA_SIZE = (WIDTH // 2) * (HEIGHT // 2)
FRAME_SIZE = LUMA_SIZE + 2 * CHROMA_SIZE
EXPECTED_BYTES = FRAME_SIZE * 2
EXPECTED_FINAL_SLICE = "0000000141d008086b3afee9ffdd7d77fdb6f7"
EXPECTED_CAVLC_SUPPRESSED_BITS = 240
EXPECTED_Y_SAD = 2048
EXPECTED_U_SAD = 256
EXPECTED_V_SAD = 256


def checker_chroma() -> bytes:
    return bytes(136 if ((x + y) & 1) else 128 for y in range(HEIGHT // 2) for x in range(WIDTH // 2))


def make_fixture() -> Path:
    data_dir = ROOT / "data"
    data_dir.mkdir(parents=True, exist_ok=True)
    path = data_dir / "smoke_16x16_2f_cabac_p16x16_luma_chroma_residual.yuv"
    y0 = bytes([64]) * LUMA_SIZE
    flat_chroma = bytes([128]) * CHROMA_SIZE
    y1 = bytes([72]) * LUMA_SIZE
    chroma = checker_chroma()
    path.write_bytes(y0 + flat_chroma + flat_chroma + y1 + chroma + chroma)
    print(f"[INFO] LUMA_CHROMA_RES fixture {path.relative_to(ROOT)} size={path.stat().st_size}")
    return path


def build_baseline_sim() -> Path:
    workspace = Path(stage_workspace("h264_cabac_luma_chroma_residual_"))
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
    print(f"[INFO] LUMA_CHROMA_RES workspace={workspace} sim={sim}")
    return sim


def run_sim(sim: Path, fixture: Path) -> tuple[Path, str]:
    out_dir = ROOT / "output"
    out_dir.mkdir(parents=True, exist_ok=True)
    h264 = out_dir / "cabac_p16x16_luma_chroma_residual.h264"
    sim_log = out_dir / "validation_cabac_p16x16_luma_chroma_residual.sim.log"
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
        raise SystemExit("[FAIL] LUMA_CHROMA_RES missing final Annex-B start code")
    return stream[last_start:].hex()


def decode_raw(h264: Path) -> tuple[bytes, str]:
    with tempfile.NamedTemporaryFile(prefix="h264_luma_chroma_residual_", suffix=".yuv", delete=False) as raw_tmp:
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


def check_sim_log(text: str) -> None:
    forbidden = "[CABAC_PSUBSET]"
    if forbidden in text:
        raise SystemExit(f"[FAIL] LUMA_CHROMA_RES hit CABAC subset guard {forbidden}")
    for needle in (
        "cabac_p16x16_mbs=1",
        "cabac_chroma_mbs=1",
        "cabac_chroma_ac_mbs=1",
        "cabac_chroma_cb_ac_mbs=1",
        "cabac_chroma_cr_ac_mbs=1",
        "cabac_chroma_cb_ac_blocks=4",
        "cabac_chroma_cr_ac_blocks=4",
        f"cavlc_suppressed_bits={EXPECTED_CAVLC_SUPPRESSED_BITS}",
        "cb_ac_mbs=1 cr_ac_mbs=1 cb_ac_blocks=4 cr_ac_blocks=4",
    ):
        if needle not in text:
            raise SystemExit(f"[FAIL] LUMA_CHROMA_RES sim log missing {needle}")


def check_decoded_planes(fixture: Path, raw: bytes) -> tuple[int, int, int]:
    if len(raw) != EXPECTED_BYTES:
        raise SystemExit(f"[FAIL] LUMA_CHROMA_RES decoded {len(raw)}/{EXPECTED_BYTES} bytes")
    src = fixture.read_bytes()
    if raw[:FRAME_SIZE] != src[:FRAME_SIZE]:
        raise SystemExit("[FAIL] LUMA_CHROMA_RES changed the IDR reference frame")
    frame1 = FRAME_SIZE
    u0 = frame1 + LUMA_SIZE
    v0 = u0 + CHROMA_SIZE
    y_sad = sum(abs(raw[frame1 + i] - src[frame1 + i]) for i in range(LUMA_SIZE))
    u_sad = sum(abs(raw[u0 + i] - src[u0 + i]) for i in range(CHROMA_SIZE))
    v_sad = sum(abs(raw[v0 + i] - src[v0 + i]) for i in range(CHROMA_SIZE))
    expected = (EXPECTED_Y_SAD, EXPECTED_U_SAD, EXPECTED_V_SAD)
    actual = (y_sad, u_sad, v_sad)
    if actual != expected:
        raise SystemExit(f"[FAIL] LUMA_CHROMA_RES SAD YUV={actual}, expected {expected}")
    return actual


def main() -> int:
    fixture = make_fixture()
    sim = build_baseline_sim()
    h264, sim_text = run_sim(sim, fixture)
    check_sim_log(sim_text)

    stream = h264.read_bytes()
    final_slice = final_slice_hex(stream)
    if final_slice != EXPECTED_FINAL_SLICE:
        raise SystemExit(
            "[FAIL] LUMA_CHROMA_RES final P-slice drifted:\n"
            f"  got      {final_slice}\n"
            f"  expected {EXPECTED_FINAL_SLICE}"
        )

    raw, err = decode_raw(h264)
    if err.strip():
        raise SystemExit(f"[FAIL] LUMA_CHROMA_RES strict FFmpeg log {err.strip()!r}")
    y_sad, u_sad, v_sad = check_decoded_planes(fixture, raw)
    print(
        "[PASS] CABAC P16x16 combined luma+Cb+Cr AC residual smoke strict-decodes "
        f"{len(raw)}/{EXPECTED_BYTES} bytes with cavlc_suppressed_bits={EXPECTED_CAVLC_SUPPRESSED_BITS}, "
        f"Y_SAD={y_sad} U_SAD={u_sad} V_SAD={v_sad}, final_slice={final_slice}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
