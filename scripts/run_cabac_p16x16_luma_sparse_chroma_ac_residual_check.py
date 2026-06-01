#!/usr/bin/env python3
"""Integrated CABAC P16x16 luma + sparse chroma-AC residual smoke gate.

The dense luma+chroma AC gates prove all four chroma AC blocks active.  This
focused check covers representative sparse mixed cases with luma residual plus
one active chroma AC block, including all four single-plane Cb/Cr quadrants,
same-block Cb+Cr quadrant cases, row-adjacent Cb+Cr pairs, and true
opposite-diagonal Cb+Cr pairs.  It locks
strict FFmpeg decode, plane-local CABAC counters, CAVLC suppression counts,
final P-slice bytes, current decoded-plane metrics, and per-4x4 chroma-block
locality so sparse residuals cannot silently land in the wrong chroma quadrant
while preserving the same aggregate SAD.
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
EXPECTED_Y_SAD = 2048


@dataclass(frozen=True)
class Case:
    name: str
    cb_mask: int
    cr_mask: int
    expected_final_slice: str
    expected_cavlc_suppressed_bits: int
    expected_y_sad: int
    expected_u_sad: int
    expected_v_sad: int

    @property
    def expected_cb_ac_mbs(self) -> int:
        return 1 if self.cb_mask else 0

    @property
    def expected_cr_ac_mbs(self) -> int:
        return 1 if self.cr_mask else 0

    @property
    def expected_cb_ac_blocks(self) -> int:
        return self.cb_mask.bit_count()

    @property
    def expected_cr_ac_blocks(self) -> int:
        return self.cr_mask.bit_count()


CASES = (
    Case(
        name="cb_ac_m1",
        cb_mask=0x1,
        cr_mask=0x0,
        expected_final_slice="0000000141d008086b3ab6e931d045573d34f76955d4",
        expected_cavlc_suppressed_bits=151,
        expected_y_sad=EXPECTED_Y_SAD,
        expected_u_sad=64,
        expected_v_sad=0,
    ),
    Case(
        name="cb_ac_m2",
        cb_mask=0x2,
        cr_mask=0x0,
        expected_final_slice="0000000141d008086b3ab6e931d045573d34f76a08ea",
        expected_cavlc_suppressed_bits=151,
        expected_y_sad=EXPECTED_Y_SAD,
        expected_u_sad=64,
        expected_v_sad=0,
    ),
    Case(
        name="cb_ac_m4",
        cb_mask=0x4,
        cr_mask=0x0,
        expected_final_slice="0000000141d008086b3ab6e931d045573d34f76a46",
        expected_cavlc_suppressed_bits=151,
        expected_y_sad=EXPECTED_Y_SAD,
        expected_u_sad=64,
        expected_v_sad=0,
    ),
    Case(
        name="cb_ac_m8",
        cb_mask=0x8,
        cr_mask=0x0,
        expected_final_slice="0000000141d008086b3ab6e931d045573d34f76a750e",
        expected_cavlc_suppressed_bits=151,
        expected_y_sad=EXPECTED_Y_SAD,
        expected_u_sad=64,
        expected_v_sad=0,
    ),
    Case(
        name="cr_ac_m1",
        cb_mask=0x0,
        cr_mask=0x1,
        expected_final_slice="0000000141d008086b3ab6e931d045573d34f76a3fd5",
        expected_cavlc_suppressed_bits=151,
        expected_y_sad=EXPECTED_Y_SAD,
        expected_u_sad=0,
        expected_v_sad=64,
    ),
    Case(
        name="cr_ac_m2",
        cb_mask=0x0,
        cr_mask=0x2,
        expected_final_slice="0000000141d008086b3ab6e931d045573d34f76a408b",
        expected_cavlc_suppressed_bits=151,
        expected_y_sad=EXPECTED_Y_SAD,
        expected_u_sad=0,
        expected_v_sad=64,
    ),
    Case(
        name="cr_ac_m4",
        cb_mask=0x0,
        cr_mask=0x4,
        expected_final_slice="0000000141d008086b3ab6e931d045573d34f76a3db8",
        expected_cavlc_suppressed_bits=151,
        expected_y_sad=EXPECTED_Y_SAD,
        expected_u_sad=0,
        expected_v_sad=64,
    ),
    Case(
        name="cr_ac_m8",
        cb_mask=0x0,
        cr_mask=0x8,
        expected_final_slice="0000000141d008086b3ab6e931d045573d34f76a3f83",
        expected_cavlc_suppressed_bits=151,
        expected_y_sad=EXPECTED_Y_SAD,
        expected_u_sad=0,
        expected_v_sad=64,
    ),
    Case(
        name="cbcr_ac_m1",
        cb_mask=0x1,
        cr_mask=0x1,
        expected_final_slice="0000000141d008086b3ab6e931d045573d34f76966740000",
        expected_cavlc_suppressed_bits=162,
        expected_y_sad=EXPECTED_Y_SAD,
        expected_u_sad=64,
        expected_v_sad=64,
    ),
    Case(
        name="cbcr_ac_m2",
        cb_mask=0x2,
        cr_mask=0x2,
        expected_final_slice="0000000141d008086b3ab6e931d045573d34f76a57890000",
        expected_cavlc_suppressed_bits=162,
        expected_y_sad=EXPECTED_Y_SAD,
        expected_u_sad=64,
        expected_v_sad=64,
    ),
    Case(
        name="cbcr_ac_m4",
        cb_mask=0x4,
        cr_mask=0x4,
        expected_final_slice="0000000141d008086b3ab6e931d045573d34f76a1f1a0000",
        expected_cavlc_suppressed_bits=162,
        expected_y_sad=EXPECTED_Y_SAD,
        expected_u_sad=64,
        expected_v_sad=64,
    ),
    Case(
        name="cbcr_ac_m2_1",
        cb_mask=0x2,
        cr_mask=0x1,
        expected_final_slice="0000000141d008086b3ab6e931d045573d34f76a57890000",
        expected_cavlc_suppressed_bits=162,
        expected_y_sad=EXPECTED_Y_SAD,
        expected_u_sad=64,
        expected_v_sad=64,
    ),
    Case(
        name="cbcr_ac_m4_8",
        cb_mask=0x4,
        cr_mask=0x8,
        expected_final_slice="0000000141d008086b3ab6e931d045573d34f76a1f1a0000",
        expected_cavlc_suppressed_bits=162,
        expected_y_sad=EXPECTED_Y_SAD,
        expected_u_sad=64,
        expected_v_sad=64,
    ),
    Case(
        name="cbcr_ac_m1_8",
        cb_mask=0x1,
        cr_mask=0x8,
        expected_final_slice="0000000141d008086b3ab6e931d045573d34f76966740000",
        expected_cavlc_suppressed_bits=162,
        expected_y_sad=EXPECTED_Y_SAD,
        expected_u_sad=64,
        expected_v_sad=64,
    ),
    Case(
        name="cbcr_ac_m8_1",
        cb_mask=0x8,
        cr_mask=0x1,
        expected_final_slice="0000000141d008086b3ab6e931d045573d34f76a43ce0000",
        expected_cavlc_suppressed_bits=162,
        expected_y_sad=EXPECTED_Y_SAD,
        expected_u_sad=64,
        expected_v_sad=64,
    ),
    Case(
        name="cbcr_ac_m2_4",
        cb_mask=0x2,
        cr_mask=0x4,
        expected_final_slice="0000000141d008086b3ab6e931d045573d34f76a57890000",
        expected_cavlc_suppressed_bits=162,
        expected_y_sad=EXPECTED_Y_SAD,
        expected_u_sad=64,
        expected_v_sad=64,
    ),
    Case(
        name="cbcr_ac_m4_2",
        cb_mask=0x4,
        cr_mask=0x2,
        expected_final_slice="0000000141d008086b3ab6e931d045573d34f76a1f1a0000",
        expected_cavlc_suppressed_bits=162,
        expected_y_sad=EXPECTED_Y_SAD,
        expected_u_sad=64,
        expected_v_sad=64,
    ),
    Case(
        name="cbcr_ac_m8",
        cb_mask=0x8,
        cr_mask=0x8,
        expected_final_slice="0000000141d008086b3ab6e931d045573d34f76a43ce0000",
        expected_cavlc_suppressed_bits=162,
        expected_y_sad=EXPECTED_Y_SAD,
        expected_u_sad=64,
        expected_v_sad=64,
    ),
)


def sparse_chroma(mask: int) -> bytes:
    data: list[int] = []
    for y in range(HEIGHT // 2):
        for x in range(WIDTH // 2):
            block = (y // 4) * 2 + (x // 4)
            if (mask >> block) & 1:
                data.append(136 if ((x + y) & 1) else 128)
            else:
                data.append(128)
    return bytes(data)


def make_fixture(case: Case) -> Path:
    data_dir = ROOT / "data"
    data_dir.mkdir(parents=True, exist_ok=True)
    path = data_dir / f"smoke_16x16_2f_cabac_p16x16_luma_sparse_{case.name}_residual.yuv"
    y0 = bytes([64]) * LUMA_SIZE
    flat_chroma = bytes([128]) * CHROMA_SIZE
    y1 = bytes([72]) * LUMA_SIZE
    path.write_bytes(y0 + flat_chroma + flat_chroma + y1 + sparse_chroma(case.cb_mask) + sparse_chroma(case.cr_mask))
    print(f"[INFO] LUMA_SPARSE_CHROMA_RES {case.name} fixture {path.relative_to(ROOT)} size={path.stat().st_size}")
    return path


def build_baseline_sim() -> Path:
    workspace = Path(stage_workspace("h264_cabac_luma_sparse_chroma_residual_"))
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
    print(f"[INFO] LUMA_SPARSE_CHROMA_RES workspace={workspace} sim={sim}")
    return sim


def run_sim(sim: Path, fixture: Path, case: Case) -> tuple[Path, str]:
    out_dir = ROOT / "output"
    out_dir.mkdir(parents=True, exist_ok=True)
    h264 = out_dir / f"cabac_p16x16_luma_sparse_{case.name}_residual.h264"
    sim_log = out_dir / f"validation_cabac_p16x16_luma_sparse_{case.name}_residual.sim.log"
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
        raise SystemExit("[FAIL] LUMA_SPARSE_CHROMA_RES missing final Annex-B start code")
    return stream[last_start:].hex()


def decode_raw(h264: Path, case: Case) -> tuple[bytes, str]:
    with tempfile.NamedTemporaryFile(prefix=f"h264_luma_sparse_{case.name}_", suffix=".yuv", delete=False) as raw_tmp:
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
        raise SystemExit(f"[FAIL] LUMA_SPARSE_CHROMA_RES {case.name} hit CABAC subset guard {forbidden}")
    for needle in (
        "cabac_p16x16_mbs=1",
        "cabac_chroma_mbs=1",
        "cabac_chroma_dc_mbs=0",
        "cabac_chroma_ac_mbs=1",
        f"cabac_chroma_cb_ac_mbs={case.expected_cb_ac_mbs}",
        f"cabac_chroma_cr_ac_mbs={case.expected_cr_ac_mbs}",
        f"cabac_chroma_cb_ac_blocks={case.expected_cb_ac_blocks}",
        f"cabac_chroma_cr_ac_blocks={case.expected_cr_ac_blocks}",
        f"cavlc_suppressed_bits={case.expected_cavlc_suppressed_bits}",
        (
            f"cb_ac_mbs={case.expected_cb_ac_mbs} cr_ac_mbs={case.expected_cr_ac_mbs} "
            f"cb_ac_blocks={case.expected_cb_ac_blocks} cr_ac_blocks={case.expected_cr_ac_blocks}"
        ),
    ):
        if needle not in text:
            raise SystemExit(f"[FAIL] LUMA_SPARSE_CHROMA_RES {case.name} sim log missing {needle}")


def check_decoded_planes(fixture: Path, raw: bytes, case: Case) -> tuple[int, int, int]:
    if len(raw) != EXPECTED_BYTES:
        raise SystemExit(f"[FAIL] LUMA_SPARSE_CHROMA_RES {case.name} decoded {len(raw)}/{EXPECTED_BYTES} bytes")
    src = fixture.read_bytes()
    if raw[:FRAME_SIZE] != src[:FRAME_SIZE]:
        raise SystemExit(f"[FAIL] LUMA_SPARSE_CHROMA_RES {case.name} changed the IDR reference frame")
    frame1 = FRAME_SIZE
    u0 = frame1 + LUMA_SIZE
    v0 = u0 + CHROMA_SIZE
    y_sad = sum(abs(raw[frame1 + i] - src[frame1 + i]) for i in range(LUMA_SIZE))
    u_sad = sum(abs(raw[u0 + i] - src[u0 + i]) for i in range(CHROMA_SIZE))
    v_sad = sum(abs(raw[v0 + i] - src[v0 + i]) for i in range(CHROMA_SIZE))
    expected = (case.expected_y_sad, case.expected_u_sad, case.expected_v_sad)
    actual = (y_sad, u_sad, v_sad)
    if actual != expected:
        raise SystemExit(f"[FAIL] LUMA_SPARSE_CHROMA_RES {case.name} SAD YUV={actual}, expected {expected}")
    u_block_sads = chroma_block_sads(raw, src, u0)
    v_block_sads = chroma_block_sads(raw, src, v0)
    expected_u_blocks = tuple(64 if (case.cb_mask >> block) & 1 else 0 for block in range(4))
    expected_v_blocks = tuple(64 if (case.cr_mask >> block) & 1 else 0 for block in range(4))
    if u_block_sads != expected_u_blocks or v_block_sads != expected_v_blocks:
        raise SystemExit(
            f"[FAIL] LUMA_SPARSE_CHROMA_RES {case.name} chroma-block SAD drift: "
            f"U={u_block_sads} V={v_block_sads}, expected U={expected_u_blocks} V={expected_v_blocks}"
        )
    return actual


def chroma_block_sads(raw: bytes, src: bytes, plane0: int) -> tuple[int, int, int, int]:
    sads: list[int] = []
    chroma_width = WIDTH // 2
    for block in range(4):
        bx = (block & 1) * 4
        by = (block >> 1) * 4
        sad = 0
        for y in range(4):
            for x in range(4):
                idx = plane0 + (by + y) * chroma_width + bx + x
                sad += abs(raw[idx] - src[idx])
        sads.append(sad)
    return (sads[0], sads[1], sads[2], sads[3])


def run_case(sim: Path, case: Case) -> None:
    fixture = make_fixture(case)
    h264, sim_text = run_sim(sim, fixture, case)
    check_sim_log(sim_text, case)

    final_slice = final_slice_hex(h264.read_bytes())
    if final_slice != case.expected_final_slice:
        raise SystemExit(
            f"[FAIL] LUMA_SPARSE_CHROMA_RES {case.name} final P-slice drifted:\n"
            f"  got      {final_slice}\n"
            f"  expected {case.expected_final_slice}"
        )

    raw, err = decode_raw(h264, case)
    if err.strip():
        raise SystemExit(f"[FAIL] LUMA_SPARSE_CHROMA_RES {case.name} strict FFmpeg log {err.strip()!r}")
    y_sad, u_sad, v_sad = check_decoded_planes(fixture, raw, case)
    print(
        f"[PASS] CABAC P16x16 luma+sparse {case.name} residual smoke strict-decodes "
        f"{len(raw)}/{EXPECTED_BYTES} bytes with cavlc_suppressed_bits={case.expected_cavlc_suppressed_bits}, "
        f"cb_ac_blocks={case.expected_cb_ac_blocks} cr_ac_blocks={case.expected_cr_ac_blocks}, "
        f"Y_SAD={y_sad} U_SAD={u_sad} V_SAD={v_sad}, sparse block locality locked, "
        f"final_slice={final_slice}"
    )


def main() -> int:
    sim = build_baseline_sim()
    for case in CASES:
        run_case(sim, case)
    print("[PASS] CABAC P16x16 luma plus sparse Cb/Cr chroma-AC residual smoke cases, including all single-plane quadrants, same-quadrant, row-adjacent, and opposite-diagonal mixed-plane pairs, strict-decode with plane-local counters and per-block chroma locality")
    return 0


if __name__ == "__main__":
    sys.exit(main())
