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


WIDTH = 32
HEIGHT = 16
FRAMES = 2
TIMEOUT = 20_000_000
SIM_SUMMARY_RE = re.compile(r"\[TB\]\s+(?P<frames>\d+)\s+frames encoded,\s+(?P<cycles>\d+)\s+cycles,\s+(?P<bytes>\d+)\s+bytes")


@dataclass(frozen=True)
class SmokeCase:
    name: str
    bit_depth: int
    chroma_format_idc: int
    input_file: str
    output_file: str


CASES = [
    SmokeCase("smoke_8b_420", 8, 1, "smoke_32x16_2f.yuv", "smoke_32x16_2f.h264"),
    SmokeCase("smoke_8b_422", 8, 2, "smoke_32x16_2f_422.yuv", "smoke_32x16_2f_422.h264"),
    SmokeCase("smoke_10b_420", 10, 1, "smoke_32x16_2f_10b.yuv", "smoke_32x16_2f_10b.h264"),
    SmokeCase("smoke_10b_422", 10, 2, "smoke_32x16_2f_10b_422.yuv", "smoke_32x16_2f_10b_422.h264"),
]


def clamp(value: int, lo: int, hi: int) -> int:
    return max(lo, min(hi, value))


def frame_sizes(chroma_format_idc: int) -> tuple[int, int, int]:
    luma = WIDTH * HEIGHT
    chroma = (WIDTH // 2) * (HEIGHT if chroma_format_idc == 2 else HEIGHT // 2)
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


def generate_smoke_input(path: Path, bit_depth: int, chroma_format_idc: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    chroma_height = HEIGHT if chroma_format_idc == 2 else HEIGHT // 2
    chroma_width = WIDTH // 2

    with path.open("wb") as out_f:
        for frame_idx in range(FRAMES):
            for y in range(HEIGHT):
                for x in range(WIDTH):
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


def decode_check(path: Path) -> None:
    run_cmd(["ffmpeg", "-v", "error", "-i", str(path), "-f", "null", "-"])


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
        generate_smoke_input(input_path, case.bit_depth, case.chroma_format_idc)

        workspace = stage_workspace(f"h264_{case.name}_")
        config = BuildConfig(
            width=WIDTH,
            height=HEIGHT,
            bit_depth=case.bit_depth,
            chroma_format_idc=case.chroma_format_idc,
        )
        sim_bin = build_sim(workspace, config)
        sim_proc = run_sim(sim_bin, FRAMES, TIMEOUT, input_path, output_path, capture=True)
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
