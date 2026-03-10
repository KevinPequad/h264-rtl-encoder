#!/usr/bin/env python3
"""Run a repeatable multi-frame validation flow for the RTL encoder."""

from __future__ import annotations

from dataclasses import asdict
from pathlib import Path
import argparse
import json
import math
import re
import sys

from rtl_runner import BuildConfig, build_sim, repo_root, require_tool, run_cmd, run_sim, stage_workspace


PSNR_RE = re.compile(r"PSNR y:(?P<y>[0-9.inf-]+).*average:(?P<avg>[0-9.inf-]+)")
SSIM_RE = re.compile(r"SSIM Y:(?P<y>[0-9.]+).*All:(?P<all>[0-9.]+)")
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


def pix_fmt_for_config(bit_depth: int, chroma_format_idc: int) -> str:
    if bit_depth == 8 and chroma_format_idc == 1:
        return "yuv420p"
    if bit_depth == 8 and chroma_format_idc == 2:
        return "yuv422p"
    if bit_depth == 10 and chroma_format_idc == 1:
        return "yuv420p10le"
    if bit_depth == 10 and chroma_format_idc == 2:
        return "yuv422p10le"
    raise ValueError(f"Unsupported pixel format for bit_depth={bit_depth} chroma_format_idc={chroma_format_idc}")


def parse_sim_summary(sim_log: str) -> dict[str, int]:
    match = SIM_SUMMARY_RE.search(sim_log)
    if not match:
        return {}
    return {
        "frames_encoded": int(match.group("frames")),
        "cycles": int(match.group("cycles")),
        "bytes": int(match.group("bytes")),
    }


def sanitize_for_json(value):
    if isinstance(value, float):
        if math.isnan(value):
            return "nan"
        if math.isinf(value):
            return "inf" if value > 0 else "-inf"
        return value
    if isinstance(value, dict):
        return {key: sanitize_for_json(subvalue) for key, subvalue in value.items()}
    if isinstance(value, list):
        return [sanitize_for_json(item) for item in value]
    return value


def extract_decode_errors(stderr: str) -> list[str]:
    hits: list[str] = []
    for line in stderr.splitlines():
        lowered = line.lower()
        if any(pattern in lowered for pattern in DECODE_ERROR_PATTERNS):
            hits.append(line.strip())
    return hits


def ffmpeg_metric(
    input_raw: Path,
    compare_input: Path,
    width: int,
    height: int,
    fps: int,
    frames: int,
    pix_fmt: str,
    metric: str,
) -> dict[str, float]:
    filter_graph = (
        f"[0:v]trim=end_frame={frames},setpts=PTS-STARTPTS[a];"
        f"[1:v]trim=end_frame={frames},setpts=PTS-STARTPTS[b];"
        f"[a][b]{metric}"
    )
    proc = run_cmd(
        [
            "ffmpeg",
            "-hide_banner",
            "-nostats",
            "-v",
            "info",
            "-s",
            f"{width}x{height}",
            "-pix_fmt",
            pix_fmt,
            "-r",
            str(fps),
            "-i",
            str(input_raw),
            "-i",
            str(compare_input),
            "-filter_complex",
            filter_graph,
            "-f",
            "null",
            "-",
        ],
        capture=True,
    )

    line = ""
    for candidate in proc.stderr.splitlines():
        if f"Parsed_{metric}" in candidate:
            line = candidate
    if not line:
        raise RuntimeError(f"Could not parse {metric} output")

    if metric == "psnr":
        match = PSNR_RE.search(line)
        if not match:
            raise RuntimeError(f"Unexpected PSNR output: {line}")
        return {"y": float(match.group("y")), "average": float(match.group("avg"))}

    match = SSIM_RE.search(line)
    if not match:
        raise RuntimeError(f"Unexpected SSIM output: {line}")
    return {"y": float(match.group("y")), "all": float(match.group("all"))}


def build_side_by_side(
    source_raw: Path,
    rtl_h264: Path,
    output_png: Path,
    width: int,
    height: int,
    fps: int,
    pix_fmt: str,
    frame_idx: int,
) -> None:
    filter_graph = (
        f"[0:v]trim=start_frame={frame_idx}:end_frame={frame_idx + 1},setpts=PTS-STARTPTS[src];"
        f"[1:v]trim=start_frame={frame_idx}:end_frame={frame_idx + 1},setpts=PTS-STARTPTS[dec];"
        "[src][dec]hstack=inputs=2"
    )
    output_png.parent.mkdir(parents=True, exist_ok=True)
    run_cmd(
        [
            "ffmpeg",
            "-y",
            "-hide_banner",
            "-loglevel",
            "error",
            "-s",
            f"{width}x{height}",
            "-pix_fmt",
            pix_fmt,
            "-r",
            str(fps),
            "-i",
            str(source_raw),
            "-i",
            str(rtl_h264),
            "-filter_complex",
            filter_graph,
            "-frames:v",
            "1",
            "-update",
            "1",
            str(output_png),
        ]
    )


def package_mp4(h264_path: Path, mp4_path: Path, width: int, height: int, fps: int) -> None:
    root = repo_root()
    run_cmd(
        [
            sys.executable,
            str(root / "scripts" / "package_mp4.py"),
            str(h264_path),
            str(mp4_path),
            "--fps",
            str(fps),
            "--width",
            str(width),
            "--height",
            str(height),
        ]
    )


def encode_x264_reference(
    source_raw: Path,
    output_mp4: Path,
    width: int,
    height: int,
    fps: int,
    frames: int,
    pix_fmt: str,
    chroma_format_idc: int,
) -> None:
    cmd = [
        "ffmpeg",
        "-y",
        "-hide_banner",
        "-loglevel",
        "error",
        "-s",
        f"{width}x{height}",
        "-pix_fmt",
        pix_fmt,
        "-r",
        str(fps),
        "-i",
        str(source_raw),
        "-frames:v",
        str(frames),
        "-c:v",
        "libx264",
        "-bf",
        "0",
        "-coder",
        "0",
        "-preset",
        "veryfast",
    ]
    if chroma_format_idc == 1:
        cmd.extend(["-profile:v", "baseline"])
    elif chroma_format_idc == 2:
        cmd.extend(["-profile:v", "high422"])
    run_cmd(cmd + [str(output_mp4)])


def parse_args() -> argparse.Namespace:
    root = repo_root()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--width", type=int, default=320)
    parser.add_argument("--height", type=int, default=176)
    parser.add_argument("--fps", type=int, default=24)
    parser.add_argument("--frames", type=int, default=24)
    parser.add_argument("--bit-depth", type=int, default=8)
    parser.add_argument("--chroma-format-idc", type=int, default=1)
    parser.add_argument("--weighted-pred-enable", type=int, choices=(0, 1), default=0)
    parser.add_argument("--luma-log2-weight-denom", type=int, default=0)
    parser.add_argument("--luma-weight", type=int, default=1)
    parser.add_argument("--luma-offset", type=int, default=0)
    parser.add_argument("--chroma-log2-weight-denom", type=int, default=0)
    parser.add_argument("--chroma-weight-cb", type=int, default=1)
    parser.add_argument("--chroma-offset-cb", type=int, default=0)
    parser.add_argument("--chroma-weight-cr", type=int, default=1)
    parser.add_argument("--chroma-offset-cr", type=int, default=0)
    parser.add_argument("--jobs", type=int, default=24)
    parser.add_argument("--timeout", type=int, default=500_000_000)
    parser.add_argument("--input", type=Path, default=root / "data" / "raw_frames.yuv")
    parser.add_argument("--label", default="320x176_24f")
    parser.add_argument("--idr-interval", type=int, default=12)
    parser.add_argument("--decode-only", action="store_true")
    parser.add_argument("--skip-metrics", action="store_true")
    parser.add_argument("--skip-x264", action="store_true")
    parser.add_argument("--skip-compare", action="store_true")
    parser.add_argument("--skip-mp4", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    require_tool("ffmpeg")
    require_tool("make")

    skip_metrics = args.skip_metrics or args.decode_only
    skip_x264 = args.skip_x264 or args.decode_only
    skip_compare = args.skip_compare or args.decode_only
    skip_mp4 = args.skip_mp4

    root = repo_root()
    input_path = args.input if args.input.is_absolute() else (root / args.input).resolve()
    if not input_path.exists():
        raise FileNotFoundError(f"Input clip not found: {input_path}")
    output_dir = root / "output"
    rtl_h264 = output_dir / f"validation_{args.label}.h264"
    rtl_mp4 = output_dir / f"validation_{args.label}.mp4"
    compare_png = output_dir / f"validation_{args.label}_compare.png"
    x264_mp4 = output_dir / f"validation_{args.label}_x264.mp4"
    summary_json = output_dir / f"validation_{args.label}.json"
    sim_log_path = output_dir / f"validation_{args.label}.sim.log"
    build_log_path = output_dir / f"validation_{args.label}.build.log"
    pix_fmt = pix_fmt_for_config(args.bit_depth, args.chroma_format_idc)

    workspace = stage_workspace(f"h264_validate_{args.label}_")
    config = BuildConfig(
        width=args.width,
        height=args.height,
        bit_depth=args.bit_depth,
        chroma_format_idc=args.chroma_format_idc,
        jobs=args.jobs,
        weighted_pred_enable=args.weighted_pred_enable,
        luma_log2_weight_denom=args.luma_log2_weight_denom,
        luma_weight=args.luma_weight,
        luma_offset=args.luma_offset,
        chroma_log2_weight_denom=args.chroma_log2_weight_denom,
        chroma_weight_cb=args.chroma_weight_cb,
        chroma_offset_cb=args.chroma_offset_cb,
        chroma_weight_cr=args.chroma_weight_cr,
        chroma_offset_cr=args.chroma_offset_cr,
        idr_interval=args.idr_interval,
    )
    sim_bin = build_sim(workspace, config, build_log_path=build_log_path)
    sim_proc = run_sim(
        sim_bin,
        args.frames,
        args.timeout,
        input_path,
        rtl_h264,
        idr_interval=args.idr_interval,
        capture=True,
    )
    sim_log = (sim_proc.stdout or "") + (sim_proc.stderr or "")
    sim_log_path.write_text(sim_log, encoding="utf-8")
    sim_summary = parse_sim_summary(sim_log)
    decode_probe = run_cmd(
        ["ffmpeg", "-v", "error", "-i", str(rtl_h264), "-f", "null", "-"],
        capture=True,
    )
    decode_errors = extract_decode_errors(decode_probe.stderr)
    if decode_errors:
        raise RuntimeError(
            "FFmpeg decoder reported H.264 errors:\n" + "\n".join(decode_errors[:16])
        )

    rtl_psnr = None
    rtl_ssim = None
    if not skip_metrics:
        rtl_psnr = ffmpeg_metric(
            input_path,
            rtl_h264,
            args.width,
            args.height,
            args.fps,
            args.frames,
            pix_fmt,
            "psnr",
        )
        rtl_ssim = ffmpeg_metric(
            input_path,
            rtl_h264,
            args.width,
            args.height,
            args.fps,
            args.frames,
            pix_fmt,
            "ssim",
        )

    ref_psnr = None
    ref_ssim = None
    if not skip_metrics and not skip_x264 and args.bit_depth == 8:
        encode_x264_reference(
            input_path,
            x264_mp4,
            args.width,
            args.height,
            args.fps,
            args.frames,
            pix_fmt,
            args.chroma_format_idc,
        )
        ref_psnr = ffmpeg_metric(input_path, x264_mp4, args.width, args.height, args.fps, args.frames, pix_fmt, "psnr")
        ref_ssim = ffmpeg_metric(input_path, x264_mp4, args.width, args.height, args.fps, args.frames, pix_fmt, "ssim")

    if not skip_compare:
        build_side_by_side(
            input_path,
            rtl_h264,
            compare_png,
            args.width,
            args.height,
            args.fps,
            pix_fmt,
            args.frames // 2,
        )
    if not skip_mp4:
        package_mp4(rtl_h264, rtl_mp4, args.width, args.height, args.fps)

    summary = {
        "config": asdict(config),
        "frames": args.frames,
        "timeout": args.timeout,
        "input": str(input_path),
        "pix_fmt": pix_fmt,
        "rtl_h264": str(rtl_h264),
        "rtl_mp4": str(rtl_mp4) if not skip_mp4 else None,
        "compare_png": str(compare_png) if not skip_compare else None,
        "build_log": str(build_log_path),
        "sim_log": str(sim_log_path),
        "sim_summary": sim_summary,
        "decode_errors": decode_errors,
        "validation_mode": {
            "decode_only": args.decode_only,
            "skip_metrics": skip_metrics,
            "skip_x264": skip_x264,
            "skip_compare": skip_compare,
            "skip_mp4": skip_mp4,
        },
        "x264_reference_mp4": str(x264_mp4) if ref_psnr is not None else None,
        "rtl_metrics": {"psnr": rtl_psnr, "ssim": rtl_ssim} if rtl_psnr is not None else None,
        "x264_metrics": {"psnr": ref_psnr, "ssim": ref_ssim} if ref_psnr is not None else None,
    }
    summary_json.write_text(json.dumps(sanitize_for_json(summary), indent=2), encoding="utf-8")

    print("[PASS] Strict FFmpeg decode check passed")
    if rtl_psnr is not None and rtl_ssim is not None:
        print(f"[PASS] RTL PSNR avg={rtl_psnr['average']:.4f} SSIM all={rtl_ssim['all']:.6f}")
    else:
        print("[PASS] RTL metrics skipped")
    if ref_psnr is not None and ref_ssim is not None:
        print(f"[PASS] x264 PSNR avg={ref_psnr['average']:.4f} SSIM all={ref_ssim['all']:.6f}")
    elif skip_x264 or skip_metrics or args.bit_depth != 8:
        print("[PASS] x264 reference step skipped")
    if skip_compare:
        print("[PASS] Side-by-side PNG skipped")
    if skip_mp4:
        print("[PASS] MP4 packaging skipped")
    print(f"[PASS] Wrote summary to {summary_json}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
