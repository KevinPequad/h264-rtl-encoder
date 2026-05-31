#!/usr/bin/env python3
"""Representative post-queue-init cross-plane chroma-AC strict-decode gate.

The checked-in CABAC core now uses the `cod_i_queue=-7` initializer.  Single-
plane Cb/Cr mask probes promote the complete nonzero 2x2 AC mask lattice; this
bounded mixed-plane gate makes sure representative Cb+Cr combinations also
strict-decode from the generated RTL stream with exact plane-local SAD instead
of relying on the older first-payload bytestream-substitution diagnostics.
"""

from __future__ import annotations

import os
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from scripts.rtl_runner import BuildConfig, build_sim, stage_workspace

WIDTH = HEIGHT = 16
FRAME_SIZE = WIDTH * HEIGHT * 3 // 2
LUMA_SIZE = WIDTH * HEIGHT
CHROMA_SIZE = WIDTH * HEIGHT // 4
EXPECTED_BYTES = FRAME_SIZE * 2
EXPECTED_HEADER_TAIL = 0x6B

# Representative cross-plane cases: sparse/sparse top-row, diagonal, split-row,
# bottom/top mirror pairs, dense-Cr, dense-Cb, and dense-both controls.  This is
# deliberately smaller than the full 15x15 lattice so the cron gate stays
# bounded while still covering the combinations that used to expose short-decode
# and wrong-plane quality failures before the `cod_i_queue=-7` promotion.
TAILS = {
    (0x1, 0x1): "0000000141d008086b3acbb8b517a9",
    (0x1, 0x2): "0000000141d008086b3acbb8b517b2",
    (0x2, 0x1): "0000000141d008086b3acbeb2d4098",
    (0x3, 0x3): "0000000141d008086b3acc614c11ff50ec24abcc54",
    (0x4, 0x1): "0000000141d008086b3acbdfe134e8",
    (0x5, 0x5): "0000000141d008086b3acc6f8c40ff5158a92c2c76",
    (0xC, 0xC): "0000000141d008086b3acc626e3a52133cb094a23a",
    (0x3, 0xC): "0000000141d008086b3acc614c37df50ec24aaa82a",
    (0xC, 0x3): "0000000141d008086b3acc626e1472133cb0958454",
    (0x1, 0xF): "0000000141d008086b3acbf59d7451ccca22bad74d",
    (0x8, 0x2): "0000000141d008086b3acbe70e269b",
    (0xF, 0x1): "0000000141d008086b3acc332499ec2488aa9fedd3",
    (0xF, 0xF): "0000000141d008086b7acc",
    (0xE, 0x1): "0000000141d008086b3acc3602d3f58ca1b3b4",
}


def checker_chroma(mask: int) -> bytes:
    out = []
    for y in range(HEIGHT // 2):
        for x in range(WIDTH // 2):
            block = (1 if x >= 4 else 0) + (2 if y >= 4 else 0)
            out.append(136 if ((mask >> block) & 1 and ((x + y) % 2)) else 128)
    return bytes(out)


def make_fixture(cb_mask: int, cr_mask: int) -> Path:
    y0 = bytes([64]) * LUMA_SIZE
    y1 = bytes([64]) * LUMA_SIZE
    flat = bytes([128]) * CHROMA_SIZE
    data_dir = ROOT / "data"
    data_dir.mkdir(parents=True, exist_ok=True)
    path = data_dir / (
        "smoke_16x16_2f_cabac_p16x16_chroma_residual_"
        f"cbcr_ac_first_payload_cross_cb{cb_mask:x}_cr{cr_mask:x}.yuv"
    )
    path.write_bytes(y0 + flat + flat + y1 + checker_chroma(cb_mask) + checker_chroma(cr_mask))
    print(
        f"[INFO] CROSS_PLANE_AC cb=0x{cb_mask:x} cr=0x{cr_mask:x} "
        f"fixture {path} size={path.stat().st_size}"
    )
    return path


def decode_raw(h264: Path) -> tuple[bytes, str]:
    with tempfile.NamedTemporaryFile(prefix="h264_cross_plane_ac_", suffix=".yuv", delete=False) as raw_tmp:
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
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            check=False,
        )
        raw = raw_path.read_bytes() if raw_path.exists() else b""
        return raw, proc.stderr.decode("utf-8", "replace")
    finally:
        raw_path.unlink(missing_ok=True)


def build_baseline_sim() -> Path:
    workspace = Path(stage_workspace("h264_cabac_cross_plane_ac_"))
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
    print(f"[INFO] CROSS_PLANE_AC workspace={workspace} sim={sim}")
    return sim


def final_slice_hex(stream: bytes, label: str) -> str:
    last_start = stream.rfind(b"\x00\x00\x00\x01")
    if last_start < 0:
        raise SystemExit(f"[FAIL] CROSS_PLANE_AC {label} missing final Annex-B start code")
    header_tail_idx = last_start + 8
    if header_tail_idx >= len(stream):
        raise SystemExit(f"[FAIL] CROSS_PLANE_AC {label} final slice too short")
    if stream[header_tail_idx] != EXPECTED_HEADER_TAIL:
        raise SystemExit(
            f"[FAIL] CROSS_PLANE_AC {label} header tail 0x{stream[header_tail_idx]:02x}, "
            f"expected 0x{EXPECTED_HEADER_TAIL:02x}"
        )
    return stream[last_start:].hex()


def run_case(sim: Path, cb_mask: int, cr_mask: int, fixture: Path) -> Path:
    out_dir = ROOT / "output" / "cabac_cross_plane_ac_probe"
    out_dir.mkdir(parents=True, exist_ok=True)
    case_name = f"cb{cb_mask:x}_cr{cr_mask:x}"
    h264 = out_dir / f"{case_name}.h264"
    sim_log = out_dir / f"{case_name}.sim.log"
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
    sim_text = sim_log.read_text(encoding="utf-8", errors="replace")
    for needle in (
        "cabac_p16x16_mbs=1",
        "cb_ac_mbs=1",
        "cr_ac_mbs=1",
        f"cb_ac_blocks={cb_mask.bit_count()}",
        f"cr_ac_blocks={cr_mask.bit_count()}",
    ):
        if needle not in sim_text:
            raise SystemExit(f"[FAIL] CROSS_PLANE_AC cb=0x{cb_mask:x} cr=0x{cr_mask:x} sim log missing {needle}")
    if "cavlc_suppressed_bits=" not in sim_text:
        raise SystemExit(f"[FAIL] CROSS_PLANE_AC cb=0x{cb_mask:x} cr=0x{cr_mask:x} did not suppress legacy CAVLC")
    return h264


def assert_planes(cb_mask: int, cr_mask: int, fixture: Path, raw: bytes) -> tuple[int, int]:
    if len(raw) != EXPECTED_BYTES:
        raise SystemExit(
            f"[FAIL] CROSS_PLANE_AC cb=0x{cb_mask:x} cr=0x{cr_mask:x} decoded {len(raw)}/{EXPECTED_BYTES}"
        )
    src = fixture.read_bytes()
    if raw[:FRAME_SIZE] != src[:FRAME_SIZE]:
        raise SystemExit(f"[FAIL] CROSS_PLANE_AC cb=0x{cb_mask:x} cr=0x{cr_mask:x} changed IDR reference")
    u0 = FRAME_SIZE + LUMA_SIZE
    v0 = u0 + CHROMA_SIZE
    u_sad = sum(abs(raw[u0 + i] - src[u0 + i]) for i in range(CHROMA_SIZE))
    v_sad = sum(abs(raw[v0 + i] - src[v0 + i]) for i in range(CHROMA_SIZE))
    expected_u = cb_mask.bit_count() * 64
    expected_v = cr_mask.bit_count() * 64
    if u_sad != expected_u or v_sad != expected_v:
        raise SystemExit(
            f"[FAIL] CROSS_PLANE_AC cb=0x{cb_mask:x} cr=0x{cr_mask:x} "
            f"SAD U={u_sad} V={v_sad}, expected U={expected_u} V={expected_v}"
        )
    return u_sad, v_sad


def check_case(sim: Path, cb_mask: int, cr_mask: int, expected_tail: str) -> None:
    fixture = make_fixture(cb_mask, cr_mask)
    h264 = run_case(sim, cb_mask, cr_mask, fixture)
    stream = h264.read_bytes()
    tail = final_slice_hex(stream, f"cb=0x{cb_mask:x} cr=0x{cr_mask:x}")
    if tail != expected_tail:
        raise SystemExit(
            f"[FAIL] CROSS_PLANE_AC cb=0x{cb_mask:x} cr=0x{cr_mask:x} tail drift {tail}, expected {expected_tail}"
        )
    raw, err = decode_raw(h264)
    if err.strip():
        raise SystemExit(f"[FAIL] CROSS_PLANE_AC cb=0x{cb_mask:x} cr=0x{cr_mask:x} FFmpeg log {err.strip()!r}")
    u_sad, v_sad = assert_planes(cb_mask, cr_mask, fixture, raw)
    print(
        f"[PASS] CROSS_PLANE_AC cb=0x{cb_mask:x} cr=0x{cr_mask:x} strict-decodes "
        f"{len(raw)}/{EXPECTED_BYTES} U_SAD={u_sad} V_SAD={v_sad} tail={tail}"
    )


def main() -> int:
    sim = build_baseline_sim()
    for (cb_mask, cr_mask), tail in TAILS.items():
        check_case(sim, cb_mask, cr_mask, tail)
    print(
        "[PASS] CABAC P16x16 cross-plane chroma-AC gate promoted: representative "
        "sparse/sparse, mirror, split-row, dense-Cb, dense-Cr, and dense-both Cb+Cr "
        "AC masks strict-decode two frames with exact plane-local SAD under the "
        "checked-in -7 CABAC queue initializer"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
