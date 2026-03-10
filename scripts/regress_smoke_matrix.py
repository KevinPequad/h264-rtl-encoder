#!/usr/bin/env python3
"""Run the reproducible smoke matrix against the RTL bitstream path."""

from __future__ import annotations

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


def generate_smoke_input(path: Path, width: int, height: int, frames: int, bit_depth: int, chroma_format_idc: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    chroma_height = height if chroma_format_idc in (2, 3) else height // 2
    chroma_width = width if chroma_format_idc == 3 else width // 2

    with path.open("wb") as out_f:
        for frame_idx in range(frames):
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


def main() -> int:
    require_tool("ffmpeg")
    require_tool("ffprobe")
    require_tool("make")

    root = repo_root()
    data_dir = root / "data"
    output_dir = root / "output"
    summary_path = output_dir / "smoke_matrix_summary.json"
    results = []

    for case in CASES:
        input_path = data_dir / case.input_file
        output_path = output_dir / case.output_file
        log_path = output_dir / f"{case.name}.sim.log"
        build_log_path = output_dir / f"{case.name}.build.log"
        generate_smoke_input(input_path, case.width, case.height, case.frames, case.bit_depth, case.chroma_format_idc)

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
            luma_log2_weight_denom=case.luma_log2_weight_denom,
            luma_weight=case.luma_weight,
            luma_offset=case.luma_offset,
            chroma_log2_weight_denom=case.chroma_log2_weight_denom,
            chroma_weight_cb=case.chroma_weight_cb,
            chroma_offset_cb=case.chroma_offset_cb,
            chroma_weight_cr=case.chroma_weight_cr,
            chroma_offset_cr=case.chroma_offset_cr,
        )
        sim_bin = build_sim(workspace, config, build_log_path=build_log_path)
        sim_proc = run_sim(sim_bin, case.frames, case.timeout, input_path, output_path, capture=True)
        sim_log = (sim_proc.stdout or "") + (sim_proc.stderr or "")
        log_path.write_text(sim_log, encoding="utf-8")
        sim_summary = parse_sim_summary(sim_log)
        decode_check(output_path)
        stream = ffprobe_stream(output_path)

        result = {
            "name": case.name,
            "config": asdict(config),
            "input": str(input_path),
            "output": str(output_path),
            "build_log": str(build_log_path),
            "sim_log": str(log_path),
            "sim_summary": sim_summary,
            "stream": stream,
        }
        results.append(result)
        print(
            f"[PASS] {case.name}: profile={stream.get('profile')} "
            f"pix_fmt={stream.get('pix_fmt')} {stream.get('width')}x{stream.get('height')}"
        )

    output_dir.mkdir(parents=True, exist_ok=True)
    summary_path.write_text(json.dumps({"cases": results}, indent=2), encoding="utf-8")
    print(f"[PASS] Wrote smoke matrix summary to {summary_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
