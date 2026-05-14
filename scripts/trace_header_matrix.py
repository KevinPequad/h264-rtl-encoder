#!/usr/bin/env python3
"""Run deterministic RTL smoke rows and assert SPS/PPS/slice header fields.

This gate is intentionally trace_headers-based: the RTL still owns every output
byte, while this script asks FFmpeg to decode the generated RBSP fields and then
checks that the advertised profile/VUI/entropy/DPB state does not overclaim or
underclaim the enabled control lane.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parents[0]
sys.path.insert(0, str(SCRIPT_DIR))

from regress_smoke_matrix import CASES, require_tool  # noqa: E402

TRACE_FIELD_RE = re.compile(
    r"\]\s+(?P<bitpos>\d+)\s+(?P<field>[A-Za-z0-9_]+)\s+[^=]*=\s+(?P<value>-?\d+)\s*$"
)


@dataclass(frozen=True)
class HeaderExpectation:
    case: str
    profile_idc: int
    ffprobe_profile: str | None = None
    pix_fmt: str | None = None
    required_slice_types: tuple[int, ...] = ()
    min_max_num_reorder_frames: int = 0
    require_all_reorder_zero: bool = False
    require_cabac_pps: bool = False
    require_transform_8x8_zero: bool = False
    notes: str = ""
    extra_expected_fields: dict[str, int] = field(default_factory=dict)


EXPECTATIONS: dict[str, HeaderExpectation] = {
    # Baseline CAVLC I/P subset: no HRD, no reordering advertised.
    "smoke_8b_420": HeaderExpectation(
        case="smoke_8b_420",
        profile_idc=66,
        ffprobe_profile="Constrained Baseline",
        pix_fmt="yuv420p",
        required_slice_types=(2, 0),
        require_all_reorder_zero=True,
        extra_expected_fields={
            "constraint_set0_flag": 1,
            "constraint_set1_flag": 1,
        },
        notes="8-bit 4:2:0 CAVLC IDR/P must remain a legal constrained-baseline stream.",
    ),
    # Reordered B/BREF stream: Baseline is illegal, and VUI must not underclaim
    # no reordering while the harness emits display-order-reordered B pictures.
    "smoke_8b_420_bdirect": HeaderExpectation(
        case="smoke_8b_420_bdirect",
        profile_idc=77,
        ffprobe_profile="Main",
        pix_fmt="yuv420p",
        required_slice_types=(2, 1),
        min_max_num_reorder_frames=1,
        notes="B/reordered GOP control lane must escalate to Main and advertise at least one reorder frame.",
    ),
    # CABAC subset: profile must be Main and the secondary PPS must carry CABAC.
    "smoke_8b_420_cabac_p16x16": HeaderExpectation(
        case="smoke_8b_420_cabac_p16x16",
        profile_idc=77,
        ffprobe_profile="Main",
        pix_fmt="yuv420p",
        required_slice_types=(2, 0),
        require_all_reorder_zero=True,
        require_cabac_pps=True,
        notes="CABAC P16x16 zero-CBP subset must use Main profile and PPS id 1 with entropy_coding_mode_flag=1.",
    ),
    # High 4:2:2 / 10-bit row: keep transform_8x8 and HRD off until those lanes exist.
    "smoke_10b_422": HeaderExpectation(
        case="smoke_10b_422",
        profile_idc=122,
        pix_fmt="yuv422p10le",
        required_slice_types=(2, 0),
        require_all_reorder_zero=True,
        require_transform_8x8_zero=True,
        extra_expected_fields={
            "chroma_format_idc": 2,
            "bit_depth_luma_minus8": 2,
            "bit_depth_chroma_minus8": 2,
        },
        notes="10-bit 4:2:2 must signal High422-compatible SPS fields without 8x8-transform/HRD overclaim.",
    ),
}


def run_cmd(cmd: list[str], cwd: Path = REPO_ROOT, log_path: Path | None = None) -> subprocess.CompletedProcess[str]:
    proc = subprocess.run(cmd, cwd=str(cwd), text=True, capture_output=True)
    if log_path is not None:
        log_path.parent.mkdir(parents=True, exist_ok=True)
        log_path.write_text(
            "$ " + " ".join(cmd) + "\n" + (proc.stdout or "") + (proc.stderr or ""),
            encoding="utf-8",
        )
    if proc.returncode != 0:
        raise RuntimeError(
            f"Command failed with exit code {proc.returncode}: {' '.join(cmd)}"
            + (f"\nLog: {log_path}" if log_path else "")
        )
    return proc


def case_by_name() -> dict[str, Any]:
    return {case.name: case for case in CASES}


def ffprobe_stream(stream_path: Path) -> dict[str, Any]:
    proc = run_cmd(
        [
            "ffprobe",
            "-v",
            "error",
            "-select_streams",
            "v:0",
            "-show_entries",
            "stream=codec_name,profile,level,width,height,pix_fmt",
            "-of",
            "json",
            str(stream_path),
        ]
    )
    data = json.loads(proc.stdout)
    streams = data.get("streams", [])
    return streams[0] if streams else {}


def decode_check(stream_path: Path, log_path: Path) -> None:
    run_cmd(["ffmpeg", "-v", "error", "-i", str(stream_path), "-f", "null", "-"], log_path=log_path)


def run_trace_headers(stream_path: Path, trace_path: Path) -> str:
    proc = run_cmd(
        [
            "ffmpeg",
            "-hide_banner",
            "-i",
            str(stream_path),
            "-c",
            "copy",
            "-bsf:v",
            "trace_headers",
            "-f",
            "null",
            "-",
        ]
    )
    text = (proc.stdout or "") + (proc.stderr or "")
    trace_path.parent.mkdir(parents=True, exist_ok=True)
    trace_path.write_text(text, encoding="utf-8")
    return text


def parse_trace_units(trace_text: str) -> list[dict[str, list[int] | int]]:
    units: list[dict[str, list[int] | int]] = []
    current: dict[str, list[int] | int] | None = None
    for line in trace_text.splitlines():
        match = TRACE_FIELD_RE.search(line)
        if not match:
            continue
        field_name = match.group("field")
        value = int(match.group("value"))
        if field_name == "nal_ref_idc" or current is None:
            current = {"fields": {}}  # type: ignore[dict-item]
            units.append(current)
        fields = current["fields"]  # type: ignore[index]
        if field_name == "nal_unit_type":
            current["nal_unit_type"] = value
        fields.setdefault(field_name, []).append(value)  # type: ignore[attr-defined]
    return units


def field_values(units: list[dict[str, Any]], name: str, nal_type: int | None = None) -> list[int]:
    values: list[int] = []
    for unit in units:
        if nal_type is not None and unit.get("nal_unit_type") != nal_type:
            continue
        values.extend(unit.get("fields", {}).get(name, []))
    return values


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def assert_expectation(expectation: HeaderExpectation, stream: dict[str, Any], units: list[dict[str, Any]]) -> dict[str, Any]:
    sps_profiles = field_values(units, "profile_idc", nal_type=7)
    require(sps_profiles, f"{expectation.case}: no SPS profile_idc found in trace_headers output")
    require(
        all(value == expectation.profile_idc for value in sps_profiles),
        f"{expectation.case}: expected SPS profile_idc={expectation.profile_idc}, saw {sps_profiles}",
    )

    if expectation.ffprobe_profile is not None:
        require(
            stream.get("profile") == expectation.ffprobe_profile,
            f"{expectation.case}: expected ffprobe profile {expectation.ffprobe_profile!r}, saw {stream.get('profile')!r}",
        )
    if expectation.pix_fmt is not None:
        require(
            stream.get("pix_fmt") == expectation.pix_fmt,
            f"{expectation.case}: expected pix_fmt {expectation.pix_fmt!r}, saw {stream.get('pix_fmt')!r}",
        )

    for field_name, expected_value in expectation.extra_expected_fields.items():
        values = field_values(units, field_name)
        require(values, f"{expectation.case}: no {field_name} fields found")
        require(
            all(value == expected_value for value in values),
            f"{expectation.case}: expected {field_name}={expected_value}, saw {values}",
        )

    nal_hrd_values = field_values(units, "nal_hrd_parameters_present_flag", nal_type=7)
    vcl_hrd_values = field_values(units, "vcl_hrd_parameters_present_flag", nal_type=7)
    require(nal_hrd_values, f"{expectation.case}: no nal_hrd_parameters_present_flag found")
    require(vcl_hrd_values, f"{expectation.case}: no vcl_hrd_parameters_present_flag found")
    require(all(value == 0 for value in nal_hrd_values), f"{expectation.case}: HRD overclaim, nal_hrd={nal_hrd_values}")
    require(all(value == 0 for value in vcl_hrd_values), f"{expectation.case}: HRD overclaim, vcl_hrd={vcl_hrd_values}")

    reorder_values = field_values(units, "max_num_reorder_frames", nal_type=7)
    require(reorder_values, f"{expectation.case}: no max_num_reorder_frames found")
    if expectation.require_all_reorder_zero:
        require(
            all(value == 0 for value in reorder_values),
            f"{expectation.case}: expected all max_num_reorder_frames=0, saw {reorder_values}",
        )
    if expectation.min_max_num_reorder_frames:
        require(
            max(reorder_values) >= expectation.min_max_num_reorder_frames,
            f"{expectation.case}: expected max_num_reorder_frames >= {expectation.min_max_num_reorder_frames}, saw {reorder_values}",
        )

    slice_types = field_values(units, "slice_type", nal_type=1) + field_values(units, "slice_type", nal_type=5)
    entropy_values = field_values(units, "entropy_coding_mode_flag", nal_type=8)
    pps_ids = field_values(units, "pic_parameter_set_id")
    transform_values = field_values(units, "transform_8x8_mode_flag", nal_type=8)
    extra_field_values = {
        field_name: field_values(units, field_name)
        for field_name in expectation.extra_expected_fields
    }
    for required_slice_type in expectation.required_slice_types:
        require(
            required_slice_type in slice_types,
            f"{expectation.case}: expected slice_type {required_slice_type} in trace, saw {slice_types}",
        )

    if expectation.require_cabac_pps:
        require(1 in entropy_values, f"{expectation.case}: expected a secondary CABAC PPS, saw entropy flags {entropy_values}")
        require(1 in pps_ids, f"{expectation.case}: expected pic_parameter_set_id=1 in PPS/slice trace, saw {pps_ids}")

    if expectation.require_transform_8x8_zero:
        require(transform_values, f"{expectation.case}: expected transform_8x8_mode_flag in High-profile PPS trace")
        require(
            all(value == 0 for value in transform_values),
            f"{expectation.case}: transform_8x8 advertised before datapath exists: {transform_values}",
        )

    return {
        "profile_idc": sps_profiles,
        "ffprobe": stream,
        "max_num_reorder_frames": reorder_values,
        "nal_hrd_parameters_present_flag": nal_hrd_values,
        "vcl_hrd_parameters_present_flag": vcl_hrd_values,
        "slice_type": slice_types,
        "entropy_coding_mode_flag": entropy_values,
        "pic_parameter_set_id": pps_ids,
        "transform_8x8_mode_flag": transform_values,
        "extra_expected_fields": extra_field_values,
    }


def run_case(expectation: HeaderExpectation, skip_smoke: bool) -> dict[str, Any]:
    cases = case_by_name()
    if expectation.case not in cases:
        raise SystemExit(f"Unknown smoke case in header expectation: {expectation.case}")
    case = cases[expectation.case]
    output_dir = REPO_ROOT / "output"
    output_dir.mkdir(parents=True, exist_ok=True)

    regress_log = output_dir / f"{expectation.case}.trace_header_matrix.regress.log"
    if not skip_smoke:
        run_cmd([sys.executable, str(SCRIPT_DIR / "regress_smoke_matrix.py"), "--case", expectation.case], log_path=regress_log)

    stream_path = output_dir / case.output_file
    require(stream_path.exists(), f"{expectation.case}: missing generated stream {stream_path}")
    decode_log = output_dir / f"{expectation.case}.trace_header_matrix.decode.log"
    trace_path = output_dir / f"{expectation.case}.trace_headers.txt"
    decode_check(stream_path, decode_log)
    stream = ffprobe_stream(stream_path)
    trace_text = run_trace_headers(stream_path, trace_path)
    units = parse_trace_units(trace_text)
    assertions = assert_expectation(expectation, stream, units)
    return {
        "name": expectation.case,
        "notes": expectation.notes,
        "stream": str(stream_path),
        "trace_headers": str(trace_path),
        "regress_log": str(regress_log),
        "decode_log": str(decode_log),
        "assertions": assertions,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--case", action="append", dest="cases", help="Run one expected trace row; may be repeated.")
    parser.add_argument("--skip-smoke", action="store_true", help="Reuse existing output/*.h264 instead of regenerating streams.")
    args = parser.parse_args()

    for tool in ("ffmpeg", "ffprobe", "make"):
        require_tool(tool)

    selected = EXPECTATIONS
    summary_name = "header_trace_matrix_summary.json"
    if args.cases:
        wanted = set(args.cases)
        missing = sorted(wanted - set(EXPECTATIONS))
        if missing:
            raise SystemExit(f"Unknown header trace case(s): {', '.join(missing)}")
        selected = {name: EXPECTATIONS[name] for name in args.cases}
        summary_name = "header_trace_matrix_summary_filtered.json"

    results: list[dict[str, Any]] = []
    for expectation in selected.values():
        result = run_case(expectation, args.skip_smoke)
        results.append(result)
        print(
            f"[PASS] {expectation.case}: profile_idc={result['assertions']['profile_idc']} "
            f"reorder={result['assertions']['max_num_reorder_frames']} trace={result['trace_headers']}"
        )

    summary_path = REPO_ROOT / "output" / summary_name
    summary_path.write_text(json.dumps({"cases": results}, indent=2), encoding="utf-8")
    print(f"[PASS] Wrote header trace matrix summary to {summary_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
