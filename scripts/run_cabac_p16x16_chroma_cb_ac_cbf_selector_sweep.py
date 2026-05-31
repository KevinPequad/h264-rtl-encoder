#!/usr/bin/env python3
"""Staged CABAC Cb AC CBF selector sweep.

This diagnostic intentionally patches only the sparse-Cb-only chroma AC CBF
context selector table in a temporary RTL workspace, then verifies a small set of
representative Cb-only AC masks. It rejects the simple hypothesis that changing
that synthetic selector table alone can promote the top-row sparse Cb AC misses
without regressing existing strict-decode controls.
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from scripts.rtl_runner import BuildConfig, build_sim, stage_workspace  # noqa: E402

WIDTH = HEIGHT = 16
EXPECTED_FRAME_BYTES = WIDTH * HEIGHT * 3 // 2 * 2
MASKS = (0x1, 0x2, 0x3, 0x4, 0x8)

SPARSE_CBF_TABLE = """                case (plane_block_i)\n                    3'd0: begin left_coded_i = 1'b1; top_coded_i = 1'b0; end\n                    3'd1: begin left_coded_i = 1'b1; top_coded_i = 1'b0; end\n                    3'd2: begin left_coded_i = 1'b1; top_coded_i = 1'b1; end\n                    default: begin left_coded_i = 1'b0; top_coded_i = 1'b0; end\n                endcase\n"""


@dataclass(frozen=True)
class Variant:
    name: str
    sels: tuple[int, int, int, int]
    expected_bytes: dict[int, int]


# sel encodes {top_coded,left_coded}. These variants cover the current synthetic
# table, unavailable-edge walks, plane-local/actual-ish neighbors, and the simple
# all-same selector extremes that are plausible one-table repair hypotheses.
VARIANTS = (
    Variant("current", (1, 1, 3, 0), {1: 384, 2: 384, 3: 768, 4: 768, 8: 768}),
    Variant("all_zero", (0, 0, 0, 0), {1: 384, 2: 384, 3: 768, 4: 384, 8: 384}),
    Variant("top_unavail_actualish", (0, 1, 2, 3), {1: 384, 2: 384, 3: 384, 4: 384, 8: 768}),
    Variant("top_zero_keep_bottom", (0, 0, 3, 0), {1: 384, 2: 384, 3: 768, 4: 384, 8: 384}),
    Variant("b0_zero_b1_left", (0, 1, 3, 0), {1: 384, 2: 384, 3: 384, 4: 768, 8: 384}),
    Variant("b0_edge_b1_zero", (1, 0, 3, 0), {1: 384, 2: 384, 3: 768, 4: 384, 8: 384}),
    Variant("top_only_for_b0_b1", (2, 2, 3, 0), {1: 384, 2: 384, 3: 384, 4: 384, 8: 384}),
    Variant("all_left", (1, 1, 1, 1), {1: 384, 2: 384, 3: 768, 4: 768, 8: 384}),
    Variant("all_top", (2, 2, 2, 2), {1: 384, 2: 384, 3: 384, 4: 384, 8: 384}),
    Variant("all_coded", (3, 3, 3, 3), {1: 384, 2: 384, 3: 768, 4: 384, 8: 384}),
)


def selector_table(sels: tuple[int, int, int, int]) -> str:
    rows = []
    for block, sel in enumerate(sels[:3]):
        rows.append(
            f"                    3'd{block}: begin left_coded_i = 1'b{sel & 1}; "
            f"top_coded_i = 1'b{(sel >> 1) & 1}; end"
        )
    sel = sels[3]
    rows.append(
        f"                    default: begin left_coded_i = 1'b{sel & 1}; "
        f"top_coded_i = 1'b{(sel >> 1) & 1}; end"
    )
    return "                case (plane_block_i)\n" + "\n".join(rows) + "\n                endcase\n"


def write_fixtures() -> dict[int, Path]:
    y0 = bytes([64]) * (WIDTH * HEIGHT)
    y1 = bytes([64]) * (WIDTH * HEIGHT)
    flat_chroma = bytes([128]) * ((WIDTH // 2) * (HEIGHT // 2))
    fixtures: dict[int, Path] = {}
    out_dir = ROOT / "data"
    out_dir.mkdir(parents=True, exist_ok=True)
    for mask in MASKS:
        cb = bytes(
            136
            if (((mask >> ((y // 4) * 2 + (x // 4))) & 1) and ((x + y) % 2))
            else 128
            for y in range(HEIGHT // 2)
            for x in range(WIDTH // 2)
        )
        path = out_dir / f"smoke_16x16_2f_cabac_p16x16_chroma_residual_cb_ac_cbf_sweep_mask_{mask:x}.yuv"
        path.write_bytes(y0 + flat_chroma + flat_chroma + y1 + cb + flat_chroma)
        fixtures[mask] = path
    return fixtures


def patch_variant(workspace: Path, variant: Variant) -> None:
    rtl = workspace / "rtl" / "h264_bitstream.v"
    text = rtl.read_text(encoding="utf-8")
    if SPARSE_CBF_TABLE not in text:
        raise SystemExit(f"[FAIL] sparse Cb CBF table anchor not found in {rtl}")
    rtl.write_text(text.replace(SPARSE_CBF_TABLE, selector_table(variant.sels)), encoding="utf-8")


def decoded_bytes(sim: str | Path, fixture: Path, out_dir: Path, mask: int) -> int:
    h264 = out_dir / f"mask_{mask:x}.h264"
    sim_log = out_dir / f"mask_{mask:x}.sim.log"
    ffmpeg_log = out_dir / f"mask_{mask:x}.ffmpeg.log"
    with sim_log.open("wb") as log:
        subprocess.run(
            [
                sim,
                "+frames=2",
                "+timeout=5000000",
                f"+input={fixture}",
                f"+output={h264}",
                "+idr_interval=12",
            ],
            stdout=log,
            stderr=subprocess.STDOUT,
            check=False,
        )
    if not h264.exists() or h264.stat().st_size == 0:
        raise SystemExit(f"[FAIL] mask=0x{mask:x} did not produce an H.264 stream; see {sim_log}")
    raw = out_dir / f"mask_{mask:x}.yuv"
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
            str(raw),
        ],
        stdout=ffmpeg_log.open("wb"),
        stderr=subprocess.STDOUT,
        check=False,
    )
    nbytes = raw.stat().st_size if raw.exists() else 0
    raw.unlink(missing_ok=True)
    return nbytes


def main() -> None:
    fixtures = write_fixtures()
    config = BuildConfig(
        width=WIDTH,
        height=HEIGHT,
        bit_depth=8,
        chroma_format_idc=1,
        enable_idr_ipcm=1,
        ipcm_sad_threshold=0,
        enable_cabac_p16x16=1,
        debug_cabac_p16x16=0,
    )
    promoted = []
    for variant in VARIANTS:
        workspace = Path(stage_workspace(f"h264_cb_ac_cbf_sweep_{variant.name}_"))
        patch_variant(workspace, variant)
        sim = build_sim(workspace, config)
        out_dir = ROOT / "output" / "cabac_cb_ac_cbf_selector_sweep" / variant.name
        out_dir.mkdir(parents=True, exist_ok=True)
        actual: dict[int, int] = {}
        for mask in MASKS:
            actual[mask] = decoded_bytes(sim, fixtures[mask], out_dir, mask)
        print(
            f"[INFO] CBF_SWEEP {variant.name} sels={variant.sels} "
            + " ".join(f"mask=0x{mask:x}:{actual[mask]}/{EXPECTED_FRAME_BYTES}" for mask in MASKS)
        )
        if actual != variant.expected_bytes:
            raise SystemExit(
                f"[FAIL] CBF_SWEEP {variant.name} changed decode bytes: "
                f"actual={actual} expected={variant.expected_bytes}"
            )
        if actual[1] == EXPECTED_FRAME_BYTES and actual[2] == EXPECTED_FRAME_BYTES:
            promoted.append(variant.name)
    if promoted:
        raise SystemExit(f"[FAIL] CBF_SWEEP unexpectedly promoted top-row sparse Cb masks: {promoted}")
    print(
        "[PASS] CABAC Cb AC CBF selector sweep: simple sparse-Cb selector-table variants "
        "do not promote top-row masks 0x1/0x2 without regressions; current top-row blocker remains elsewhere."
    )


if __name__ == "__main__":
    main()
