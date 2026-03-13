#!/usr/bin/env python3
"""Run the reproducible smoke matrix against the RTL bitstream path."""

from __future__ import annotations

import argparse
from dataclasses import asdict, dataclass
from pathlib import Path
import json
import re
import struct
import sys

from rtl_runner import BuildConfig, build_sim, repo_root, require_tool, run_cmd, run_sim, stage_workspace


DEFAULT_WIDTH = 32
DEFAULT_HEIGHT = 16
DEFAULT_FRAMES = 2
DEFAULT_TIMEOUT = 20_000_000
SIM_SUMMARY_RE = re.compile(r"\[TB\]\s+(?P<frames>\d+)\s+frames encoded,\s+(?P<cycles>\d+)\s+cycles,\s+(?P<bytes>\d+)\s+bytes")
PSKIP_RE = re.compile(
    r"\[PSKIP\]\s+Frame\s+(?P<frame>\d+)\s+skip_mbs=(?P<skip>\d+)\s+"
    r"b_l1_mbs=(?P<b_l1>\d+)\s+b_bi_mbs=(?P<b_bi>\d+)\s+b_direct_mbs=(?P<b_direct>\d+)\s+"
    r"b_l0_refgt0_mbs=(?P<b_l0_refgt0>\d+)\s+"
    r"b_direct_refgt0_mbs=(?P<b_direct_refgt0>\d+)"
    r"(?:\s+b_direct_l1src_mbs=(?P<b_direct_l1src>\d+))?"
    r"(?:\s+cabac_p16x16_mbs=(?P<cabac_p16x16>\d+))?"
)
DECODE_ERROR_PATTERNS = (
    "error while decoding",
    "mb_type ",
    "cbp too large",
    "top block unavailable",
    "corrupted macroblock",
    "negative number of zero coeffs",
    "sub_mb_type",
    "corrupt decoded frame",
    "error processing packet in decoder",
    "decoder thread returned error",
)


@dataclass(frozen=True)
class SmokeCase:
    name: str
    bit_depth: int
    chroma_format_idc: int
    input_file: str
    output_file: str
    width: int = DEFAULT_WIDTH
    height: int = DEFAULT_HEIGHT
    frames: int = DEFAULT_FRAMES
    timeout: int = DEFAULT_TIMEOUT
    weighted_pred_enable: int = 0
    luma_log2_weight_denom: int = 0
    luma_weight: int = 1
    luma_offset: int = 0
    chroma_log2_weight_denom: int = 0
    chroma_weight_cb: int = 1
    chroma_offset_cb: int = 0
    chroma_weight_cr: int = 1
    chroma_offset_cr: int = 0
    enable_idr_ipcm: int = 0
    enable_p_ipcm: int = 0
    ipcm_sad_threshold: int = 18000
    inter_sad_threshold: int = 8000
    enable_cabac_pskip: int = 0
    enable_cabac_p16x16: int = 0
    idr_interval: int = 12
    force_b_slice: int = 0
    force_bref_slice: int = 0
    force_b_bi: int = 0
    force_b_l0: int = 0
    force_b_l1: int = 0
    force_b_direct: int = 0
    force_b_direct_temporal: int = 0
    force_b_bi_on_reorder_ref_slot: int = 0
    force_b_l0_on_reorder_ref_slot: int = 0
    force_b_l1_on_reorder_ref_slot: int = 0
    force_b_direct_on_reorder_ref_slot: int = 0
    force_b_direct_temporal_on_reorder_ref_slot: int = 0
    force_b_bi_on_reorder_b_slot: int = 0
    force_b_l0_on_reorder_b_slot: int = 0
    force_b_l1_on_reorder_b_slot: int = 0
    force_b_direct_on_reorder_b_slot: int = 0
    force_b_direct_temporal_on_reorder_b_slot: int = 0
    reorder_b_gop: int = 0
    flat_y_frames: tuple[int, ...] | None = None
    require_skip_min: int = 0
    require_bi_min: int = 0
    require_direct_min: int = 0
    require_l1_min: int = 0
    require_l0_refgt0_min: int = 0
    require_direct_refgt0_min: int = 0
    require_direct_l1src_min: int = 0
    require_cabac_p16x16_min: int = 0


CASES = [
    SmokeCase(
        "smoke_8b_420",
        8,
        1,
        "smoke_32x16_2f.yuv",
        "smoke_32x16_2f.h264",
        enable_idr_ipcm=1,
        enable_p_ipcm=1,
        ipcm_sad_threshold=0,
        inter_sad_threshold=0,
    ),
    SmokeCase(
        "smoke_8b_422",
        8,
        2,
        "smoke_32x16_2f_422.yuv",
        "smoke_32x16_2f_422.h264",
        enable_idr_ipcm=1,
        enable_p_ipcm=1,
        ipcm_sad_threshold=0,
        inter_sad_threshold=0,
    ),
    SmokeCase(
        "smoke_10b_420",
        10,
        1,
        "smoke_32x16_2f_10b.yuv",
        "smoke_32x16_2f_10b.h264",
        enable_idr_ipcm=1,
        enable_p_ipcm=1,
        ipcm_sad_threshold=0,
        inter_sad_threshold=0,
    ),
    SmokeCase(
        "smoke_10b_422",
        10,
        2,
        "smoke_32x16_2f_10b_422.yuv",
        "smoke_32x16_2f_10b_422.h264",
        enable_idr_ipcm=1,
        enable_p_ipcm=1,
        ipcm_sad_threshold=0,
        inter_sad_threshold=0,
    ),
    SmokeCase(
        "smoke_8b_444_ipcm",
        8,
        3,
        "smoke_32x16_2f_444.yuv",
        "smoke_32x16_2f_444.h264",
        enable_idr_ipcm=1,
        enable_p_ipcm=1,
        ipcm_sad_threshold=0,
        inter_sad_threshold=0,
    ),
    SmokeCase(
        "smoke_10b_444_ipcm",
        10,
        3,
        "smoke_32x16_2f_10b_444.yuv",
        "smoke_32x16_2f_10b_444.h264",
        enable_idr_ipcm=1,
        enable_p_ipcm=1,
        ipcm_sad_threshold=0,
        inter_sad_threshold=0,
    ),
    SmokeCase(
        "smoke_8b_420_cabac_pskip",
        8,
        1,
        "smoke_32x16_4f_cabac_pskip.yuv",
        "smoke_32x16_4f_cabac_pskip.h264",
        frames=4,
        enable_idr_ipcm=1,
        enable_cabac_pskip=1,
        flat_y_frames=(32, 32, 32, 32),
        require_skip_min=6,
    ),
    SmokeCase(
        "smoke_8b_420_cabac_p16x16",
        8,
        1,
        "smoke_32x16_2f_cabac_p16x16.yuv",
        "smoke_32x16_2f_cabac_p16x16.h264",
        frames=2,
        enable_idr_ipcm=1,
        enable_cabac_p16x16=1,
        flat_y_frames=(64, 64),
        require_cabac_p16x16_min=2,
    ),
    SmokeCase(
        "smoke_8b_420_bdirect",
        8,
        1,
        "smoke_32x16_3f_bdirect.yuv",
        "smoke_32x16_3f_bdirect.h264",
        frames=3,
        force_bref_slice=1,
        force_b_direct=1,
        reorder_b_gop=1,
        flat_y_frames=(128, 128, 128),
        require_direct_min=1,
    ),
    SmokeCase(
        "smoke_8b_420_bdirect_temporal",
        8,
        1,
        "smoke_32x16_3f_bdirect.yuv",
        "smoke_32x16_3f_bdirect_temporal.h264",
        frames=3,
        force_b_direct=1,
        force_b_direct_temporal=1,
        reorder_b_gop=1,
    ),
    SmokeCase(
        "smoke_8b_420_bdirect_temporal_bref",
        8,
        1,
        "smoke_32x16_3f_bdirect.yuv",
        "smoke_32x16_3f_bdirect_temporal_bref.h264",
        frames=3,
        force_bref_slice=1,
        force_b_direct=1,
        force_b_direct_temporal=1,
        reorder_b_gop=1,
    ),
    SmokeCase(
        "smoke_8b_420_bdirect_temporal_ref1",
        8,
        1,
        "smoke_32x16_7f_temporal_ref1.yuv",
        "smoke_32x16_7f_temporal_ref1.h264",
        frames=7,
        timeout=80_000_000,
        force_b_direct=1,
        force_b_direct_temporal=1,
        reorder_b_gop=1,
        flat_y_frames=(255, 128, 0, 100, 200, 0, 0),
        require_direct_min=1,
        require_direct_refgt0_min=1,
    ),
    SmokeCase(
        "smoke_8b_420_bdirect_temporal_auto_ref1",
        8,
        1,
        "smoke_32x16_7f_temporal_ref1.yuv",
        "smoke_32x16_7f_temporal_auto_ref1.h264",
        frames=7,
        timeout=80_000_000,
        reorder_b_gop=1,
        flat_y_frames=(255, 128, 0, 100, 200, 0, 0),
        require_direct_min=1,
        require_direct_refgt0_min=1,
    ),
    SmokeCase(
        "smoke_8b_420_bdirect_temporal_bref_ref1",
        8,
        1,
        "smoke_32x16_7f_temporal_ref1.yuv",
        "smoke_32x16_7f_temporal_bref_ref1.h264",
        frames=7,
        timeout=80_000_000,
        force_bref_slice=1,
        force_b_l0_on_reorder_ref_slot=1,
        force_b_direct_on_reorder_b_slot=1,
        force_b_direct_temporal_on_reorder_b_slot=1,
        reorder_b_gop=1,
        flat_y_frames=(255, 128, 0, 100, 200, 0, 0),
        require_direct_min=1,
        require_l0_refgt0_min=1,
        require_direct_refgt0_min=1,
    ),
    SmokeCase(
        "smoke_8b_420_bdirect_temporal_bref_auto_ref1",
        8,
        1,
        "smoke_32x16_7f_temporal_ref1.yuv",
        "smoke_32x16_7f_temporal_bref_auto_ref1.h264",
        frames=7,
        timeout=80_000_000,
        force_bref_slice=1,
        force_b_l0_on_reorder_ref_slot=1,
        reorder_b_gop=1,
        flat_y_frames=(255, 128, 0, 100, 200, 0, 0),
        require_direct_min=1,
        require_l0_refgt0_min=1,
        require_direct_refgt0_min=1,
    ),
    SmokeCase(
        "smoke_8b_420_bref_l1_refslot",
        8,
        1,
        "smoke_32x16_7f_temporal_ref1.yuv",
        "smoke_32x16_7f_bref_l1_refslot.h264",
        frames=7,
        timeout=80_000_000,
        enable_idr_ipcm=1,
        enable_p_ipcm=1,
        ipcm_sad_threshold=100_000_000,
        inter_sad_threshold=40_000,
        force_bref_slice=1,
        force_b_l1_on_reorder_ref_slot=1,
        reorder_b_gop=1,
        flat_y_frames=(255, 128, 0, 100, 200, 0, 0),
        require_l1_min=1,
    ),
    SmokeCase(
        "smoke_8b_420_bdirect_temporal_bref_l1_ref1",
        8,
        1,
        "smoke_32x16_7f_temporal_ref1.yuv",
        "smoke_32x16_7f_temporal_bref_l1_ref1.h264",
        frames=7,
        timeout=80_000_000,
        enable_idr_ipcm=1,
        enable_p_ipcm=1,
        ipcm_sad_threshold=100_000_000,
        inter_sad_threshold=40_000,
        force_bref_slice=1,
        force_b_l1_on_reorder_ref_slot=1,
        force_b_direct_on_reorder_b_slot=1,
        force_b_direct_temporal_on_reorder_b_slot=1,
        reorder_b_gop=1,
        flat_y_frames=(255, 128, 0, 100, 200, 0, 0),
        require_direct_min=1,
        require_direct_l1src_min=1,
    ),
    SmokeCase(
        "smoke_8b_420_bdirect_temporal_bref_auto_l1_ref1",
        8,
        1,
        "smoke_32x16_7f_temporal_ref1.yuv",
        "smoke_32x16_7f_temporal_bref_auto_l1_ref1.h264",
        frames=7,
        timeout=80_000_000,
        enable_idr_ipcm=1,
        enable_p_ipcm=1,
        ipcm_sad_threshold=100_000_000,
        inter_sad_threshold=40_000,
        force_bref_slice=1,
        force_b_l1_on_reorder_ref_slot=1,
        reorder_b_gop=1,
        flat_y_frames=(255, 128, 0, 100, 200, 0, 0),
        require_direct_min=1,
        require_direct_l1src_min=1,
    ),
    SmokeCase(
        "smoke_8b_420_bdirect_temporal_bref_bi_ref1",
        8,
        1,
        "smoke_32x16_5f_bmultiref_ref1win.yuv",
        "smoke_32x16_5f_temporal_bref_bi_ref1.h264",
        frames=5,
        timeout=80_000_000,
        enable_idr_ipcm=1,
        enable_p_ipcm=1,
        ipcm_sad_threshold=100_000_000,
        inter_sad_threshold=40_000,
        force_bref_slice=1,
        force_b_bi_on_reorder_ref_slot=1,
        force_b_direct_on_reorder_b_slot=1,
        force_b_direct_temporal_on_reorder_b_slot=1,
        reorder_b_gop=1,
        flat_y_frames=(255, 64, 0, 228, 200),
        require_bi_min=1,
        require_direct_min=1,
        require_l0_refgt0_min=1,
        require_direct_l1src_min=1,
    ),
    SmokeCase(
        "smoke_8b_420_bl0_ref1",
        8,
        1,
        "smoke_32x16_7f_bl0_ref1_ipcmrefs.yuv",
        "smoke_32x16_7f_bl0_ref1_ipcmrefs.h264",
        frames=7,
        timeout=80_000_000,
        enable_idr_ipcm=1,
        enable_p_ipcm=1,
        ipcm_sad_threshold=100_000_000,
        force_b_l0=1,
        reorder_b_gop=1,
        flat_y_frames=(255, 128, 0, 90, 180, 0, 255),
        require_l0_refgt0_min=1,
    ),
    SmokeCase(
        "smoke_8b_420_bmultiref_bi_l0ref1",
        8,
        1,
        "smoke_32x16_5f_bmultiref_ref1win.yuv",
        "smoke_32x16_5f_bmultiref_ref1win.h264",
        frames=5,
        timeout=80_000_000,
        enable_idr_ipcm=1,
        enable_p_ipcm=1,
        ipcm_sad_threshold=100_000_000,
        inter_sad_threshold=40_000,
        force_b_slice=1,
        force_b_bi=1,
        reorder_b_gop=1,
        flat_y_frames=(255, 64, 0, 228, 200),
        require_bi_min=1,
        require_l0_refgt0_min=1,
    ),
]


def clamp(value: int, lo: int, hi: int) -> int:
    return max(lo, min(hi, value))


def frame_sizes(width: int, height: int, chroma_format_idc: int) -> tuple[int, int, int]:
    luma = width * height
    if chroma_format_idc == 3:
        chroma = width * height
    elif chroma_format_idc == 2:
        chroma = (width // 2) * height
    else:
        chroma = (width // 2) * (height // 2)
    return luma, chroma, chroma


def plane_value(bit_depth: int, kind: str, x: int, y: int, frame_idx: int) -> int:
    if bit_depth == 8:
        y_base = 16
        y_span = 219
        c_base = 16
        c_span = 224
    else:
        y_base = 64
        y_span = 876
        c_base = 64
        c_span = 896

    if kind == "y":
        raw = y_base + ((x * 17 + y * 29 + frame_idx * 53) % y_span)
        return clamp(raw, y_base, y_base + y_span)

    if kind == "u":
        raw = 128 if bit_depth == 8 else 512
        raw += ((x * 9 - y * 7 + frame_idx * 31) % 41) - 20
        return clamp(raw, c_base, c_base + c_span)

    raw = 128 if bit_depth == 8 else 512
    raw += ((x * 5 + y * 11 + frame_idx * 17) % 49) - 24
    return clamp(raw, c_base, c_base + c_span)


def write_sample(out_f, value: int, bit_depth: int) -> None:
    if bit_depth > 8:
        out_f.write(struct.pack("<H", value))
    else:
        out_f.write(bytes((value,)))


def generate_smoke_input(
    path: Path,
    width: int,
    height: int,
    frames: int,
    bit_depth: int,
    chroma_format_idc: int,
    flat_y_frames: tuple[int, ...] | None = None,
) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    chroma_height = height if chroma_format_idc in (2, 3) else height // 2
    chroma_width = width if chroma_format_idc == 3 else width // 2
    if flat_y_frames is not None and len(flat_y_frames) != frames:
        raise ValueError(f"Expected {frames} flat-frame entries, got {len(flat_y_frames)}")

    with path.open("wb") as out_f:
        for frame_idx in range(frames):
            if flat_y_frames is not None:
                y_value = clamp(flat_y_frames[frame_idx], 0, (1 << bit_depth) - 1)
                c_value = 128 if bit_depth == 8 else 512
                for _ in range(height):
                    for _ in range(width):
                        write_sample(out_f, y_value, bit_depth)
                for _ in range(chroma_height):
                    for _ in range(chroma_width):
                        write_sample(out_f, c_value, bit_depth)
                for _ in range(chroma_height):
                    for _ in range(chroma_width):
                        write_sample(out_f, c_value, bit_depth)
            else:
                for y in range(height):
                    for x in range(width):
                        write_sample(out_f, plane_value(bit_depth, "y", x, y, frame_idx), bit_depth)

                for y in range(chroma_height):
                    for x in range(chroma_width):
                        write_sample(out_f, plane_value(bit_depth, "u", x, y, frame_idx), bit_depth)

                for y in range(chroma_height):
                    for x in range(chroma_width):
                        write_sample(out_f, plane_value(bit_depth, "v", x, y, frame_idx), bit_depth)


def ffprobe_stream(path: Path) -> dict[str, str]:
    proc = run_cmd(
        [
            "ffprobe",
            "-v",
            "error",
            "-select_streams",
            "v:0",
            "-show_entries",
            "stream=codec_name,profile,width,height,pix_fmt",
            "-of",
            "json",
            str(path),
        ],
        capture=True,
    )
    data = json.loads(proc.stdout)
    streams = data.get("streams", [])
    return streams[0] if streams else {}


def extract_decode_errors(stderr: str) -> list[str]:
    hits: list[str] = []
    for line in stderr.splitlines():
        lowered = line.lower()
        if any(pattern in lowered for pattern in DECODE_ERROR_PATTERNS):
            hits.append(line.strip())
    return hits


def decode_check(path: Path) -> None:
    # The tiny generated smoke cases are kept as a fast parser/profile sanity
    # check, but they still need strict decoder-error gating.
    proc = run_cmd(["ffmpeg", "-v", "error", "-i", str(path), "-f", "null", "-"], capture=True)
    decode_errors = extract_decode_errors(proc.stderr)
    if decode_errors:
        raise RuntimeError("FFmpeg decoder reported H.264 errors:\n" + "\n".join(decode_errors[:16]))


def parse_sim_summary(sim_log: str) -> dict[str, int]:
    match = SIM_SUMMARY_RE.search(sim_log)
    if not match:
        return {}
    return {
        "frames_encoded": int(match.group("frames")),
        "cycles": int(match.group("cycles")),
        "bytes": int(match.group("bytes")),
    }


def parse_b_mode_summary(sim_log: str) -> dict[str, int]:
    frames_with_skip = 0
    frames_with_l1 = 0
    frames_with_bi = 0
    frames_with_direct = 0
    frames_with_l0_refgt0 = 0
    frames_with_direct_refgt0 = 0
    frames_with_direct_l1src = 0
    frames_with_cabac_p16x16 = 0
    max_skip = 0
    max_l1 = 0
    max_bi = 0
    max_direct = 0
    max_l0_refgt0 = 0
    max_direct_refgt0 = 0
    max_direct_l1src = 0
    max_cabac_p16x16 = 0
    total_skip = 0
    total_l1 = 0
    total_bi = 0
    total_direct = 0
    total_l0_refgt0 = 0
    total_direct_refgt0 = 0
    total_direct_l1src = 0
    total_cabac_p16x16 = 0

    for match in PSKIP_RE.finditer(sim_log):
        skip = int(match.group("skip"))
        l1 = int(match.group("b_l1"))
        bi = int(match.group("b_bi"))
        direct = int(match.group("b_direct"))
        l0_refgt0 = int(match.group("b_l0_refgt0"))
        direct_refgt0 = int(match.group("b_direct_refgt0"))
        direct_l1src = int(match.group("b_direct_l1src") or 0)
        cabac_p16x16 = int(match.group("cabac_p16x16") or 0)
        total_skip += skip
        total_l1 += l1
        total_bi += bi
        total_direct += direct
        total_l0_refgt0 += l0_refgt0
        total_direct_refgt0 += direct_refgt0
        total_direct_l1src += direct_l1src
        total_cabac_p16x16 += cabac_p16x16
        if skip:
            frames_with_skip += 1
        if l1:
            frames_with_l1 += 1
        if bi:
            frames_with_bi += 1
        if direct:
            frames_with_direct += 1
        if l0_refgt0:
            frames_with_l0_refgt0 += 1
        if direct_refgt0:
            frames_with_direct_refgt0 += 1
        if direct_l1src:
            frames_with_direct_l1src += 1
        if cabac_p16x16:
            frames_with_cabac_p16x16 += 1
        max_skip = max(max_skip, skip)
        max_l1 = max(max_l1, l1)
        max_bi = max(max_bi, bi)
        max_direct = max(max_direct, direct)
        max_l0_refgt0 = max(max_l0_refgt0, l0_refgt0)
        max_direct_refgt0 = max(max_direct_refgt0, direct_refgt0)
        max_direct_l1src = max(max_direct_l1src, direct_l1src)
        max_cabac_p16x16 = max(max_cabac_p16x16, cabac_p16x16)

    return {
        "frames_with_skip": frames_with_skip,
        "frames_with_l1": frames_with_l1,
        "frames_with_bi": frames_with_bi,
        "frames_with_direct": frames_with_direct,
        "frames_with_l0_refgt0": frames_with_l0_refgt0,
        "frames_with_direct_refgt0": frames_with_direct_refgt0,
        "frames_with_direct_l1src": frames_with_direct_l1src,
        "frames_with_cabac_p16x16": frames_with_cabac_p16x16,
        "max_skip": max_skip,
        "max_l1": max_l1,
        "max_bi": max_bi,
        "max_direct": max_direct,
        "max_l0_refgt0": max_l0_refgt0,
        "max_direct_refgt0": max_direct_refgt0,
        "max_direct_l1src": max_direct_l1src,
        "max_cabac_p16x16": max_cabac_p16x16,
        "total_skip": total_skip,
        "total_l1": total_l1,
        "total_bi": total_bi,
        "total_direct": total_direct,
        "total_l0_refgt0": total_l0_refgt0,
        "total_direct_refgt0": total_direct_refgt0,
        "total_direct_l1src": total_direct_l1src,
        "total_cabac_p16x16": total_cabac_p16x16,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--case",
        action="append",
        dest="cases",
        metavar="NAME",
        help="Run only the named smoke case. May be supplied multiple times.",
    )
    args = parser.parse_args()

    require_tool("ffmpeg")
    require_tool("ffprobe")
    require_tool("make")

    root = repo_root()
    data_dir = root / "data"
    output_dir = root / "output"
    selected_cases = CASES
    if args.cases:
        wanted = set(args.cases)
        selected_cases = [case for case in CASES if case.name in wanted]
        missing = sorted(wanted - {case.name for case in selected_cases})
        if missing:
            raise SystemExit(f"Unknown smoke case(s): {', '.join(missing)}")
        summary_path = output_dir / "smoke_matrix_summary_filtered.json"
    else:
        summary_path = output_dir / "smoke_matrix_summary.json"
    results = []

    for case in selected_cases:
        input_path = data_dir / case.input_file
        output_path = output_dir / case.output_file
        log_path = output_dir / f"{case.name}.sim.log"
        build_log_path = output_dir / f"{case.name}.build.log"
        generate_smoke_input(
            input_path,
            case.width,
            case.height,
            case.frames,
            case.bit_depth,
            case.chroma_format_idc,
            case.flat_y_frames,
        )

        workspace = stage_workspace(f"h264_{case.name}_")
        config = BuildConfig(
            width=case.width,
            height=case.height,
            bit_depth=case.bit_depth,
            chroma_format_idc=case.chroma_format_idc,
            weighted_pred_enable=case.weighted_pred_enable,
            enable_idr_ipcm=case.enable_idr_ipcm,
            enable_p_ipcm=case.enable_p_ipcm,
            ipcm_sad_threshold=case.ipcm_sad_threshold,
            inter_sad_threshold=case.inter_sad_threshold,
            enable_cabac_pskip=case.enable_cabac_pskip,
            enable_cabac_p16x16=case.enable_cabac_p16x16,
            luma_log2_weight_denom=case.luma_log2_weight_denom,
            luma_weight=case.luma_weight,
            luma_offset=case.luma_offset,
            chroma_log2_weight_denom=case.chroma_log2_weight_denom,
            chroma_weight_cb=case.chroma_weight_cb,
            chroma_offset_cb=case.chroma_offset_cb,
            chroma_weight_cr=case.chroma_weight_cr,
            chroma_offset_cr=case.chroma_offset_cr,
            idr_interval=case.idr_interval,
            force_b_slice=case.force_b_slice,
            force_bref_slice=case.force_bref_slice,
            force_b_bi=case.force_b_bi,
            force_b_l0=case.force_b_l0,
            force_b_l1=case.force_b_l1,
            force_b_direct=case.force_b_direct,
            force_b_direct_temporal=case.force_b_direct_temporal,
            force_b_bi_on_reorder_ref_slot=case.force_b_bi_on_reorder_ref_slot,
            force_b_l0_on_reorder_ref_slot=case.force_b_l0_on_reorder_ref_slot,
            force_b_l1_on_reorder_ref_slot=case.force_b_l1_on_reorder_ref_slot,
            force_b_direct_on_reorder_ref_slot=case.force_b_direct_on_reorder_ref_slot,
            force_b_direct_temporal_on_reorder_ref_slot=case.force_b_direct_temporal_on_reorder_ref_slot,
            force_b_bi_on_reorder_b_slot=case.force_b_bi_on_reorder_b_slot,
            force_b_l0_on_reorder_b_slot=case.force_b_l0_on_reorder_b_slot,
            force_b_l1_on_reorder_b_slot=case.force_b_l1_on_reorder_b_slot,
            force_b_direct_on_reorder_b_slot=case.force_b_direct_on_reorder_b_slot,
            force_b_direct_temporal_on_reorder_b_slot=case.force_b_direct_temporal_on_reorder_b_slot,
            reorder_b_gop=case.reorder_b_gop,
        )
        sim_bin = build_sim(workspace, config, build_log_path=build_log_path)
        sim_proc = run_sim(
            sim_bin,
            case.frames,
            case.timeout,
            input_path,
            output_path,
            idr_interval=case.idr_interval,
            force_b_slice=case.force_b_slice,
            force_bref_slice=case.force_bref_slice,
            force_b_bi=case.force_b_bi,
            force_b_l0=case.force_b_l0,
            force_b_l1=case.force_b_l1,
            force_b_direct=case.force_b_direct,
            force_b_direct_temporal=case.force_b_direct_temporal,
            force_b_bi_on_reorder_ref_slot=case.force_b_bi_on_reorder_ref_slot,
            force_b_l0_on_reorder_ref_slot=case.force_b_l0_on_reorder_ref_slot,
            force_b_l1_on_reorder_ref_slot=case.force_b_l1_on_reorder_ref_slot,
            force_b_direct_on_reorder_ref_slot=case.force_b_direct_on_reorder_ref_slot,
            force_b_direct_temporal_on_reorder_ref_slot=case.force_b_direct_temporal_on_reorder_ref_slot,
            force_b_bi_on_reorder_b_slot=case.force_b_bi_on_reorder_b_slot,
            force_b_l0_on_reorder_b_slot=case.force_b_l0_on_reorder_b_slot,
            force_b_l1_on_reorder_b_slot=case.force_b_l1_on_reorder_b_slot,
            force_b_direct_on_reorder_b_slot=case.force_b_direct_on_reorder_b_slot,
            force_b_direct_temporal_on_reorder_b_slot=case.force_b_direct_temporal_on_reorder_b_slot,
            reorder_b_gop=case.reorder_b_gop,
            capture=True,
        )
        sim_log = (sim_proc.stdout or "") + (sim_proc.stderr or "")
        log_path.write_text(sim_log, encoding="utf-8")
        sim_summary = parse_sim_summary(sim_log)
        b_mode_summary = parse_b_mode_summary(sim_log)
        decode_check(output_path)
        stream = ffprobe_stream(output_path)
        if b_mode_summary.get("total_bi", 0) < case.require_bi_min:
            raise RuntimeError(
                f"{case.name} expected at least {case.require_bi_min} B_BI macroblocks, "
                f"saw {b_mode_summary.get('total_bi', 0)}"
            )
        if b_mode_summary.get("total_skip", 0) < case.require_skip_min:
            raise RuntimeError(
                f"{case.name} expected at least {case.require_skip_min} skip macroblocks, "
                f"saw {b_mode_summary.get('total_skip', 0)}"
            )
        if b_mode_summary.get("total_l1", 0) < case.require_l1_min:
            raise RuntimeError(
                f"{case.name} expected at least {case.require_l1_min} B_L1 macroblocks, "
                f"saw {b_mode_summary.get('total_l1', 0)}"
            )
        if b_mode_summary.get("total_direct", 0) < case.require_direct_min:
            raise RuntimeError(
                f"{case.name} expected at least {case.require_direct_min} B_DIRECT macroblocks, "
                f"saw {b_mode_summary.get('total_direct', 0)}"
            )
        if b_mode_summary.get("total_l0_refgt0", 0) < case.require_l0_refgt0_min:
            raise RuntimeError(
                f"{case.name} expected at least {case.require_l0_refgt0_min} nonzero B List0 refs, "
                f"saw {b_mode_summary.get('total_l0_refgt0', 0)}"
            )
        if b_mode_summary.get("total_direct_refgt0", 0) < case.require_direct_refgt0_min:
            raise RuntimeError(
                f"{case.name} expected at least {case.require_direct_refgt0_min} nonzero B_DIRECT List0 refs, "
                f"saw {b_mode_summary.get('total_direct_refgt0', 0)}"
            )
        if b_mode_summary.get("total_direct_l1src", 0) < case.require_direct_l1src_min:
            raise RuntimeError(
                f"{case.name} expected at least {case.require_direct_l1src_min} B_DIRECT macroblocks "
                f"derived from colocated List1, saw {b_mode_summary.get('total_direct_l1src', 0)}"
            )
        if b_mode_summary.get("total_cabac_p16x16", 0) < case.require_cabac_p16x16_min:
            raise RuntimeError(
                f"{case.name} expected at least {case.require_cabac_p16x16_min} CABAC P_L0_16x16 macroblocks, "
                f"saw {b_mode_summary.get('total_cabac_p16x16', 0)}"
            )

        result = {
            "name": case.name,
            "config": asdict(config),
            "input": str(input_path),
            "output": str(output_path),
            "build_log": str(build_log_path),
            "sim_log": str(log_path),
            "sim_summary": sim_summary,
            "b_mode_summary": b_mode_summary,
            "stream": stream,
        }
        results.append(result)
        print(
            f"[PASS] {case.name}: profile={stream.get('profile')} "
            f"pix_fmt={stream.get('pix_fmt')} {stream.get('width')}x{stream.get('height')} "
            f"skip_max={b_mode_summary.get('max_skip', 0)} "
            f"b_l1_max={b_mode_summary.get('max_l1', 0)} "
            f"b_direct_max={b_mode_summary.get('max_direct', 0)} "
            f"b_l0_refgt0_max={b_mode_summary.get('max_l0_refgt0', 0)} "
            f"b_direct_refgt0_max={b_mode_summary.get('max_direct_refgt0', 0)} "
            f"b_direct_l1src_max={b_mode_summary.get('max_direct_l1src', 0)}"
        )

    output_dir.mkdir(parents=True, exist_ok=True)
    summary_path.write_text(json.dumps({"cases": results}, indent=2), encoding="utf-8")
    print(f"[PASS] Wrote smoke matrix summary to {summary_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
