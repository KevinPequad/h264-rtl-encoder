#!/usr/bin/env python3
"""Manifest-driven H.264 verification harness.

This runner is intentionally conservative:
- it never runs broad/long T2/T3 tiers while the manifest says they are blocked;
- it records machine-readable evidence for each executed case;
- it treats pending feature-lane placeholders as PENDING, not PASS;
- it includes negative-test and RTL byte-ownership audit hooks.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import time
from typing import Any


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

DECODE_ERROR_SAMPLE_LINES = [
    "[h264 @ 0x1] error while decoding MB 1 0",
    "[h264 @ 0x1] mb_type 42 in P slice too large",
    "[h264 @ 0x1] cbp too large (47) at 2 1",
    "[h264 @ 0x1] top block unavailable for requested intra mode",
    "[h264 @ 0x1] corrupted macroblock 1 0 (total_coeff=16)",
    "[h264 @ 0x1] negative number of zero coeffs at 0 0",
    "[h264 @ 0x1] sub_mb_type 13 out of range",
    "[h264 @ 0x1] corrupt decoded frame in stream 0",
    "Error processing packet in decoder: Invalid data found when processing input",
    "decoder thread returned error -1094995529",
]

EXPECTED_PIX_FMT = {
    (8, 1): "yuv420p",
    (8, 2): "yuv422p",
    (8, 3): "yuv444p",
    (10, 1): "yuv420p10le",
    (10, 2): "yuv422p10le",
    (10, 3): "yuv444p10le",
}

TEXT_FILE_SUFFIXES = {".py", ".cpp", ".cc", ".cxx", ".h", ".hpp", ".sh"}
AUDIT_TOOL_FILES = {"scripts/run_h264_verify_manifest.py"}
PACKAGING_ONLY_FILES = {"scripts/package_mp4.py"}
REFERENCE_ONLY_FILES = {"scripts/validate_clip.py"}


class HarnessError(RuntimeError):
    pass


def repo_root() -> Path:
    return Path(__file__).resolve().parents[1]


def default_manifest_path() -> Path:
    return repo_root() / "verification" / "h264_full_matrix.json"


def default_output_path() -> Path:
    return repo_root() / "output" / "h264_verify_manifest_summary.json"


def relpath(path: Path, root: Path | None = None) -> str:
    root = root or repo_root()
    try:
        return str(path.resolve().relative_to(root.resolve()))
    except ValueError:
        return str(path)


def now_utc_seconds() -> int:
    return int(time.time())


def limit_text(text: str | None, limit: int = 12000) -> str:
    if not text:
        return ""
    if len(text) <= limit:
        return text
    return text[:limit] + f"\n...[truncated {len(text) - limit} chars]"


def sha256_file(path: Path) -> dict[str, Any]:
    info: dict[str, Any] = {"path": str(path), "exists": path.exists()}
    if not path.exists() or not path.is_file():
        return info
    h = hashlib.sha256()
    size = 0
    with path.open("rb") as fh:
        while True:
            chunk = fh.read(1024 * 1024)
            if not chunk:
                break
            size += len(chunk)
            h.update(chunk)
    info.update({"bytes": size, "sha256": h.hexdigest()})
    return info


def load_json(path: Path) -> Any:
    with path.open("r", encoding="utf-8") as fh:
        return json.load(fh)


def write_json(path: Path, data: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def normalize_cmd(cmd: list[str]) -> list[str]:
    if cmd and cmd[0] == "python3":
        return [sys.executable] + cmd[1:]
    return cmd


def command_record(cmd: list[str]) -> dict[str, Any]:
    return {"argv": cmd, "shell": shlex.join(cmd)}


def run_command(cmd: list[str], cwd: Path, timeout: int) -> dict[str, Any]:
    executable_cmd = normalize_cmd(cmd)
    started = time.time()
    try:
        proc = subprocess.run(
            executable_cmd,
            cwd=str(cwd),
            text=True,
            capture_output=True,
            timeout=timeout,
            check=False,
        )
        duration = time.time() - started
        return {
            "command": command_record(cmd),
            "cwd": str(cwd),
            "returncode": proc.returncode,
            "duration_seconds": duration,
            "stdout": limit_text(proc.stdout),
            "stderr": limit_text(proc.stderr),
            "timed_out": False,
        }
    except subprocess.TimeoutExpired as exc:
        duration = time.time() - started
        return {
            "command": command_record(cmd),
            "cwd": str(cwd),
            "returncode": None,
            "duration_seconds": duration,
            "stdout": limit_text(exc.stdout if isinstance(exc.stdout, str) else ""),
            "stderr": limit_text(exc.stderr if isinstance(exc.stderr, str) else ""),
            "timed_out": True,
        }


def git_commit(root: Path) -> dict[str, str | None]:
    def git(args: list[str]) -> str | None:
        proc = subprocess.run(["git", *args], cwd=str(root), text=True, capture_output=True, check=False)
        if proc.returncode != 0:
            return None
        return proc.stdout.strip()

    return {
        "commit": git(["rev-parse", "HEAD"]),
        "commit_short": git(["rev-parse", "--short", "HEAD"]),
        "branch": git(["branch", "--show-current"]),
        "status_short": git(["status", "--short"]),
    }


def extract_decode_errors(stderr: str) -> list[str]:
    hits: list[str] = []
    for line in stderr.splitlines():
        lowered = line.lower()
        if any(pattern in lowered for pattern in DECODE_ERROR_PATTERNS):
            hits.append(line.strip())
    return hits


def expected_pix_fmt(config: dict[str, Any]) -> str | None:
    bit_depth = int(config.get("bit_depth", 8))
    chroma = int(config.get("chroma_format_idc", 1))
    return EXPECTED_PIX_FMT.get((bit_depth, chroma))


def expected_profile(config: dict[str, Any]) -> str | None:
    bit_depth = int(config.get("bit_depth", 8))
    chroma = int(config.get("chroma_format_idc", 1))
    if config.get("enable_cabac_pskip") or config.get("enable_cabac_p16x16"):
        return "Main"
    if bit_depth == 8 and chroma == 1:
        return "Constrained Baseline"
    if bit_depth == 8 and chroma == 2:
        return "High 4:2:2"
    if bit_depth == 8 and chroma == 3:
        return "High 4:4:4 Predictive"
    if bit_depth == 10 and chroma == 1:
        return "High 10"
    if bit_depth == 10 and chroma == 2:
        return "High 4:2:2"
    if bit_depth == 10 and chroma == 3:
        return "High 4:4:4 Predictive"
    return None


def verify_stream_metadata(stream: dict[str, Any], config: dict[str, Any]) -> list[str]:
    mismatches: list[str] = []
    width = int(config.get("width", config.get("config", {}).get("width", 32)))
    height = int(config.get("height", config.get("config", {}).get("height", 16)))
    exp_pix_fmt = expected_pix_fmt(config)
    exp_profile = expected_profile(config)

    if stream.get("codec_name") != "h264":
        mismatches.append(f"codec_name expected h264 saw {stream.get('codec_name')!r}")
    if stream.get("width") is not None and int(stream.get("width")) != width:
        mismatches.append(f"width expected {width} saw {stream.get('width')!r}")
    if stream.get("height") is not None and int(stream.get("height")) != height:
        mismatches.append(f"height expected {height} saw {stream.get('height')!r}")
    if exp_pix_fmt and stream.get("pix_fmt") != exp_pix_fmt:
        mismatches.append(f"pix_fmt expected {exp_pix_fmt} saw {stream.get('pix_fmt')!r}")
    if exp_profile and stream.get("profile") != exp_profile:
        mismatches.append(f"profile expected {exp_profile} saw {stream.get('profile')!r}")
    return mismatches


def strict_decode(path: Path, timeout: int) -> dict[str, Any]:
    cmd = [
        "ffmpeg",
        "-hide_banner",
        "-nostdin",
        "-v",
        "error",
        "-xerror",
        "-err_detect",
        "explode",
        "-i",
        str(path),
        "-f",
        "null",
        "-",
    ]
    res = run_command(cmd, repo_root(), timeout)
    errors = extract_decode_errors(res.get("stderr", ""))
    res["decode_errors"] = errors
    res["passed"] = (res.get("returncode") == 0) and not errors and not res.get("timed_out")
    return res


def ffprobe_metadata(path: Path, timeout: int) -> dict[str, Any]:
    cmd = [
        "ffprobe",
        "-v",
        "error",
        "-select_streams",
        "v:0",
        "-show_entries",
        "stream=codec_name,profile,level,width,height,pix_fmt,refs,has_b_frames",
        "-of",
        "json",
        str(path),
    ]
    res = run_command(cmd, repo_root(), timeout)
    streams: list[dict[str, Any]] = []
    parse_error = None
    if res.get("stdout"):
        try:
            streams = json.loads(res["stdout"]).get("streams", [])
        except json.JSONDecodeError as exc:
            parse_error = str(exc)
    return {
        "command": res["command"],
        "returncode": res["returncode"],
        "stderr": res.get("stderr", ""),
        "timed_out": res.get("timed_out", False),
        "parse_error": parse_error,
        "stream": streams[0] if streams else {},
        "passed": res.get("returncode") == 0 and bool(streams) and parse_error is None,
    }


def trace_headers(path: Path, log_path: Path, timeout: int) -> dict[str, Any]:
    cmd = [
        "ffmpeg",
        "-hide_banner",
        "-v",
        "trace",
        "-i",
        str(path),
        "-c:v",
        "copy",
        "-bsf:v",
        "trace_headers",
        "-f",
        "null",
        "-",
    ]
    res = run_command(cmd, repo_root(), timeout)
    log_path.parent.mkdir(parents=True, exist_ok=True)
    log_path.write_text((res.get("stderr") or "") + (res.get("stdout") or ""), encoding="utf-8")
    return {
        "command": res["command"],
        "returncode": res["returncode"],
        "timed_out": res.get("timed_out", False),
        "log": sha256_file(log_path),
        "decode_errors": extract_decode_errors(res.get("stderr", "")),
        "passed": res.get("returncode") == 0 and not res.get("timed_out"),
    }


def framemd5(path: Path, md5_path: Path, timeout: int) -> dict[str, Any]:
    cmd = ["ffmpeg", "-hide_banner", "-v", "error", "-i", str(path), "-f", "framemd5", str(md5_path)]
    res = run_command(cmd, repo_root(), timeout)
    return {
        "command": res["command"],
        "returncode": res["returncode"],
        "timed_out": res.get("timed_out", False),
        "stderr": res.get("stderr", ""),
        "framemd5": sha256_file(md5_path),
        "passed": res.get("returncode") == 0 and md5_path.exists() and not res.get("timed_out"),
    }


def needs_trace(entry: dict[str, Any], force: bool) -> bool:
    if force:
        return True
    gates = " ".join(entry.get("required_gates", []))
    return "trace" in gates


def needs_framemd5(entry: dict[str, Any], force: bool) -> bool:
    if force:
        return True
    gates = " ".join(entry.get("required_gates", []))
    return "framemd5" in gates or "exact_decoded_framemd5" in gates


def smoke_summary_path(root: Path) -> Path:
    return root / "output" / "smoke_matrix_summary_filtered.json"


def find_smoke_case_result(summary: dict[str, Any], case_name: str) -> dict[str, Any] | None:
    for item in summary.get("cases", []):
        if item.get("name") == case_name:
            return item
    return None


def run_smoke_entry(entry: dict[str, Any], args: argparse.Namespace, manifest: dict[str, Any]) -> dict[str, Any]:
    root = repo_root()
    tier = entry.get("runtime_tier") or entry.get("tier")
    tier_info = manifest.get("runtime_tiers", {}).get(tier, {})
    if tier_info.get("allowed_now") is False:
        return {
            "id": entry["id"],
            "name": entry.get("name"),
            "kind": entry.get("kind"),
            "runtime_tier": tier,
            "status": "BLOCKED",
            "attempted_execution": False,
            "reason": f"runtime tier {tier} is blocked: {tier_info.get('blocked_until', 'release condition not met')}",
        }
    if args.dry_run:
        return {
            "id": entry["id"],
            "name": entry.get("name"),
            "kind": entry.get("kind"),
            "runtime_tier": tier,
            "status": "DRY_RUN",
            "attempted_execution": False,
            "command": command_record(entry.get("command", [])),
            "reason": "dry-run only; no simulator or decoder process executed",
        }

    command = list(entry.get("command", []))
    if not command:
        return {
            "id": entry["id"],
            "name": entry.get("name"),
            "kind": entry.get("kind"),
            "runtime_tier": tier,
            "status": "UNSUPPORTED",
            "reason": "manifest entry has no executable command",
        }

    root.joinpath("output").mkdir(exist_ok=True)
    old_summary = smoke_summary_path(root)
    if old_summary.exists():
        old_summary.unlink()

    command_result = run_command(command, root, args.command_timeout)
    result: dict[str, Any] = {
        "id": entry["id"],
        "name": entry.get("name"),
        "kind": entry.get("kind"),
        "runtime_tier": tier,
        "required_gates": entry.get("required_gates", []),
        "commit": git_commit(root),
        "command_result": command_result,
        "attempted_execution": True,
    }

    case_summary: dict[str, Any] | None = None
    if old_summary.exists():
        try:
            case_summary = find_smoke_case_result(load_json(old_summary), entry["name"])
        except json.JSONDecodeError as exc:
            result["summary_parse_error"] = str(exc)

    if case_summary is None:
        result["status"] = "FAIL"
        result["reason"] = "regress_smoke_matrix command did not produce a parseable case summary"
        if command_result.get("returncode") not in (0, None):
            result["reason"] += f"; command returned {command_result.get('returncode')}"
        return result

    result["case_summary"] = case_summary
    input_path = Path(case_summary.get("input", ""))
    output_path = Path(case_summary.get("output", ""))
    result["input_hash"] = sha256_file(input_path)
    result["output_bitstream_hash"] = sha256_file(output_path)
    result["sim_summary"] = case_summary.get("sim_summary", {})
    result["b_mode_summary"] = case_summary.get("b_mode_summary", {})
    result["frame_recon_hash_metric_summary"] = {
        "sim_frames_encoded": case_summary.get("sim_summary", {}).get("frames_encoded"),
        "sim_cycles": case_summary.get("sim_summary", {}).get("cycles"),
        "sim_bytes": case_summary.get("sim_summary", {}).get("bytes"),
        "b_mode_summary": case_summary.get("b_mode_summary", {}),
        "metrics": case_summary.get("rtl_metrics"),
        "recon_hash": None,
        "recon_note": "smoke matrix runs in a temporary staged tb directory; current smoke summary does not expose recon.yuv path",
    }

    failures: list[str] = []
    if command_result.get("returncode") != 0 or command_result.get("timed_out"):
        failures.append(f"smoke command failed rc={command_result.get('returncode')} timed_out={command_result.get('timed_out')}")
    if not output_path.exists():
        failures.append(f"expected output bitstream missing: {output_path}")

    if output_path.exists():
        decode = strict_decode(output_path, args.command_timeout)
        probe = ffprobe_metadata(output_path, args.command_timeout)
        result["public_decoder"] = {"strict_decode": decode, "ffprobe_metadata": probe}
        if not decode.get("passed"):
            failures.append("strict ffmpeg decode failed or reported fatal decoder patterns")
        if not probe.get("passed"):
            failures.append("ffprobe metadata gate failed")
        stream = probe.get("stream", {})
        merged_config = dict(entry.get("config", {}))
        merged_config.update(case_summary.get("config", {}))
        metadata_mismatches = verify_stream_metadata(stream, merged_config)
        result["public_decoder"]["metadata_mismatches"] = metadata_mismatches
        if metadata_mismatches:
            failures.extend(metadata_mismatches)
        if needs_trace(entry, args.trace_headers):
            trace = trace_headers(output_path, root / "output" / f"{entry['id']}.trace_headers.log", args.command_timeout)
            result["public_decoder"]["trace_headers"] = trace
            if not trace.get("passed"):
                failures.append("trace_headers gate failed")
        if needs_framemd5(entry, args.framemd5):
            md5 = framemd5(output_path, root / "output" / f"{entry['id']}.framemd5", args.command_timeout)
            result["public_decoder"]["framemd5"] = md5
            if not md5.get("passed"):
                failures.append("framemd5 gate failed")

    result["status"] = "FAIL" if failures else "PASS"
    result["reason"] = "; ".join(failures) if failures else "all selected manifest gates passed"
    return result


def run_feature_placeholder(entry: dict[str, Any], args: argparse.Namespace, manifest: dict[str, Any]) -> dict[str, Any]:
    tier = entry.get("runtime_tier") or entry.get("tier")
    tier_info = manifest.get("runtime_tiers", {}).get(tier, {})
    if tier_info.get("allowed_now") is False:
        status = "BLOCKED"
        reason = f"runtime tier {tier} is blocked: {tier_info.get('blocked_until', 'release condition not met')}"
    else:
        status = "PENDING"
        reason = entry.get("reason") or "feature lane has no executable fixture registered yet"
    return {
        "id": entry["id"],
        "name": entry.get("name"),
        "kind": entry.get("kind"),
        "feature_lane_id": entry.get("feature_lane_id"),
        "runtime_tier": tier,
        "status": "DRY_RUN" if args.dry_run else status,
        "attempted_execution": False,
        "dependencies": entry.get("dependencies", []),
        "required_gates": entry.get("required_gates", []),
        "must_cover": entry.get("must_cover", []),
        "reason": "dry-run listing of pending feature lane" if args.dry_run else reason,
    }


def iter_audit_files(root: Path) -> list[Path]:
    paths: list[Path] = []
    for subdir in ("tb", "scripts"):
        base = root / subdir
        if not base.exists():
            continue
        for path in base.rglob("*"):
            if path.is_file() and path.suffix in TEXT_FILE_SUFFIXES:
                paths.append(path)
    return sorted(paths)


def line_records(path: Path, root: Path) -> list[tuple[int, str]]:
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return []
    return list(enumerate(text.splitlines(), start=1))


def static_rtl_ownership_audit() -> dict[str, Any]:
    root = repo_root()
    evidence: list[dict[str, Any]] = []
    allowed_findings: list[dict[str, Any]] = []
    forbidden_findings: list[dict[str, Any]] = []

    rtl_bitstream = root / "rtl" / "h264_bitstream.v"
    tb = root / "tb" / "tb_h264_encoder.cpp"
    if rtl_bitstream.exists():
        rtl_text = rtl_bitstream.read_text(encoding="utf-8", errors="replace")
        for token in ("bs_mem_addr", "bs_mem_data", "bs_mem_wr", "bs_bytes_written"):
            if token in rtl_text:
                evidence.append({"kind": "rtl_bs_mem_port", "file": relpath(rtl_bitstream, root), "token": token})
    if tb.exists():
        tb_lines = line_records(tb, root)
        for line_no, line in tb_lines:
            if "dut->bs_mem_wr" in line or "dut->bs_mem_addr" in line or "dut->bs_mem_data" in line:
                evidence.append({"kind": "tb_bs_mem_capture", "file": relpath(tb, root), "line": line_no, "text": line.strip()})
            if "bitstream_mem.data()" in line and "total_bs_bytes" in line and "write" in line:
                evidence.append({"kind": "tb_final_h264_write_from_captured_bs_mem", "file": relpath(tb, root), "line": line_no, "text": line.strip()})

    high_confidence_patterns = [
        (re.compile(r"\b(?:write_ue|write_se|put_ue|put_se|put_bits|emit_bits|rbsp_trailing_bits)\b", re.I), "software bit/RBSP syntax writer"),
        (re.compile(r"\b(?:build|emit|write)_(?:sps|pps|slice|mb|macroblock|residual|cavlc|cabac|nal|rbsp)\b", re.I), "software final-syntax builder"),
        (re.compile(r"\.write_bytes\s*\(.*\.h264", re.I), "direct .h264 write_bytes"),
        (re.compile(r"open\s*\([^\n]*(?:\.h264|encoded)[^\n]*[\"'](?:w|a|wb|ab)", re.I), "direct .h264 open-for-write"),
        (re.compile(r"\b(?:backpatch|byte[-_ ]?patch|repair|pad bytes|pad rbsp|rewrite final|rewrite.*\.h264)\b", re.I), "byte patch/repair language"),
        (re.compile(r"\b(?:seek|truncate)\s*\(", re.I), "seek/truncate may indicate byte backpatch"),
    ]

    for path in iter_audit_files(root):
        rel = relpath(path, root)
        for line_no, line in line_records(path, root):
            stripped = line.strip()
            if not stripped:
                continue
            if rel in PACKAGING_ONLY_FILES and any(token in stripped for token in ("parse_annexb", "build_avcc", "ffmpeg", "copy", "struct.pack", "bytearray", "NAL", "SPS", "PPS")):
                allowed_findings.append({"kind": "allowed_packaging_only", "file": rel, "line": line_no, "text": stripped[:240]})
                continue
            if rel in REFERENCE_ONLY_FILES and ("libx264" in stripped or "x264" in stripped):
                allowed_findings.append({"kind": "allowed_x264_reference_only", "file": rel, "line": line_no, "text": stripped[:240]})
                continue
            if rel in AUDIT_TOOL_FILES:
                if "negative_malformed" in stripped or "malformed_bitstream_decode" in stripped:
                    allowed_findings.append({"kind": "allowed_negative_fixture", "file": rel, "line": line_no, "text": stripped[:240]})
                continue
            for pattern, reason in high_confidence_patterns:
                if pattern.search(stripped):
                    if stripped.startswith("//") or stripped.startswith("#"):
                        continue
                    forbidden_findings.append({"kind": reason, "file": rel, "line": line_no, "text": stripped[:240]})

    required_evidence = {
        "rtl_bs_mem_port": any(item["kind"] == "rtl_bs_mem_port" for item in evidence),
        "tb_bs_mem_capture": any(item["kind"] == "tb_bs_mem_capture" for item in evidence),
        "tb_final_h264_write_from_captured_bs_mem": any(item["kind"] == "tb_final_h264_write_from_captured_bs_mem" for item in evidence),
    }
    missing = [key for key, ok in required_evidence.items() if not ok]
    passed = not missing and not forbidden_findings
    return {
        "status": "PASS" if passed else "FAIL",
        "passed": passed,
        "required_evidence": required_evidence,
        "missing_evidence": missing,
        "evidence": evidence[:200],
        "allowed_findings": allowed_findings[:200],
        "forbidden_findings": forbidden_findings[:200],
        "reason": "RTL bs_mem ownership evidence present and no forbidden final-syntax repair hooks found" if passed else "RTL ownership audit failed",
    }


def run_negative_test(neg: dict[str, Any], args: argparse.Namespace) -> dict[str, Any]:
    root = repo_root()
    neg_id = neg["id"]
    builtin = neg.get("builtin")
    base = {
        "id": neg_id,
        "kind": "negative_test",
        "runtime_tier": neg.get("runtime_tier", "T0-RED"),
        "intent": neg.get("intent"),
        "expected": neg.get("expected"),
        "builtin": builtin,
    }
    if args.dry_run:
        return {**base, "status": "DRY_RUN", "attempted_execution": False, "reason": "dry-run only"}
    if builtin == "decode_error_parser_samples":
        misses = [line for line in DECODE_ERROR_SAMPLE_LINES if not extract_decode_errors(line)]
        return {
            **base,
            "status": "RED_EXPECTED_FAIL" if not misses else "FAIL",
            "attempted_execution": True,
            "sample_lines": DECODE_ERROR_SAMPLE_LINES,
            "misses": misses,
            "reason": "all fatal stderr samples were caught" if not misses else "decode-error parser missed fatal sample lines",
        }
    if builtin == "malformed_bitstream_decode":
        malformed = root / "output" / "negative_malformed.h264"
        malformed.parent.mkdir(parents=True, exist_ok=True)
        malformed.write_bytes(b"\x00\x00\x00\x01\x65\xff\xff\xff\xff\x00\x00")
        decode = strict_decode(malformed, args.command_timeout)
        caught = decode.get("returncode") != 0 or bool(decode.get("decode_errors"))
        return {
            **base,
            "status": "RED_EXPECTED_FAIL" if caught else "FAIL",
            "attempted_execution": True,
            "malformed_bitstream_hash": sha256_file(malformed),
            "strict_decode": decode,
            "reason": "malformed bitstream was rejected by public decoder gate" if caught else "malformed bitstream unexpectedly decoded cleanly",
        }
    if builtin == "rtl_ownership_static_audit":
        audit = static_rtl_ownership_audit()
        return {
            **base,
            "status": audit["status"],
            "attempted_execution": True,
            "audit": audit,
            "reason": audit["reason"],
        }
    return {
        **base,
        "status": "UNSUPPORTED",
        "attempted_execution": False,
        "reason": "negative test declared in manifest but requires a feature-specific fixture or RTL toggle not registered in this harness yet",
    }


def validate_manifest(manifest: dict[str, Any]) -> dict[str, Any]:
    errors: list[str] = []
    warnings: list[str] = []
    if manifest.get("schema_version") != "h264-verification-manifest/v1":
        errors.append("unexpected schema_version")
    entries = manifest.get("entries", [])
    negatives = manifest.get("negative_tests", [])
    ids = [entry.get("id") for entry in entries]
    dupes = sorted({item for item in ids if ids.count(item) > 1})
    if dupes:
        errors.append(f"duplicate entry ids: {dupes}")
    smoke_count = sum(1 for entry in entries if entry.get("kind") == "smoke_case")
    if smoke_count != 21:
        errors.append(f"expected 21 smoke_case entries, saw {smoke_count}")
    if len(negatives) != 10:
        errors.append(f"expected 10 negative_tests entries, saw {len(negatives)}")
    for tier in ("T2", "T3"):
        info = manifest.get("runtime_tiers", {}).get(tier)
        if not info or info.get("allowed_now") is not False:
            errors.append(f"runtime tier {tier} must remain blocked in this manifest")
    runnable_neg = sorted(neg.get("id") for neg in negatives if neg.get("status") == "runnable")
    expected_runnable = ["NEG-ERRORPAT-001", "NEG-MALFORMED-001", "NEG-REPAIR-001"]
    if runnable_neg != expected_runnable:
        warnings.append(f"runnable negative tests are {runnable_neg}, expected {expected_runnable}")
    return {"status": "PASS" if not errors else "FAIL", "errors": errors, "warnings": warnings}


def select_entries(manifest: dict[str, Any], args: argparse.Namespace) -> list[dict[str, Any]]:
    entries = manifest.get("entries", [])
    selected: list[dict[str, Any]] = []
    by_id_or_name: dict[str, dict[str, Any]] = {}
    for entry in entries:
        by_id_or_name[entry.get("id")] = entry
        by_id_or_name[entry.get("name")] = entry

    for case in args.cases or []:
        entry = by_id_or_name.get(case)
        if entry is None:
            raise HarnessError(f"Unknown manifest case/entry: {case}")
        selected.append(entry)

    for tier in args.tiers or []:
        for entry in entries:
            if entry.get("runtime_tier") == tier or entry.get("tier") == tier:
                if entry.get("kind") == "feature_lane_placeholder" and not args.include_pending:
                    continue
                selected.append(entry)

    deduped: list[dict[str, Any]] = []
    seen: set[str] = set()
    for entry in selected:
        entry_id = entry.get("id")
        if entry_id in seen:
            continue
        seen.add(entry_id)
        deduped.append(entry)
    return deduped


def select_negative_tests(manifest: dict[str, Any], args: argparse.Namespace) -> list[dict[str, Any]]:
    wanted = args.negative_tests or []
    if not wanted:
        return []
    negatives = manifest.get("negative_tests", [])
    if "all" in wanted:
        return negatives
    by_id = {neg.get("id"): neg for neg in negatives}
    selected = []
    for neg_id in wanted:
        if neg_id not in by_id:
            raise HarnessError(f"Unknown negative test id: {neg_id}")
        selected.append(by_id[neg_id])
    return selected


def print_entry_listing(manifest: dict[str, Any]) -> None:
    for entry in manifest.get("entries", []):
        print(
            f"{entry.get('id'):42} {entry.get('kind'):26} {entry.get('runtime_tier'):8} {entry.get('status'):16} {entry.get('name')}"
        )
    if manifest.get("negative_tests"):
        print("\nNegative tests:")
        for neg in manifest.get("negative_tests", []):
            print(f"{neg.get('id'):18} {neg.get('status'):16} {neg.get('builtin') or '-':32} {neg.get('intent')}")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, default=default_manifest_path())
    parser.add_argument("--output", type=Path, default=default_output_path())
    parser.add_argument("--case", action="append", dest="cases", help="Run/list a manifest entry by smoke case name or entry id. Repeatable.")
    parser.add_argument("--tier", action="append", dest="tiers", choices=("T0-RED", "T0-GREEN", "T1", "T2", "T3"), help="Select entries by runtime tier. Repeatable.")
    parser.add_argument("--include-pending", action="store_true", help="Include pending feature-lane placeholders when selecting by tier.")
    parser.add_argument("--negative", action="append", dest="negative_tests", help="Run a negative test id, or 'all'. Repeatable.")
    parser.add_argument("--audit-only", action="store_true", help="Run only the RTL byte-ownership/no-repair static audit hook.")
    parser.add_argument("--validate-manifest", action="store_true", help="Validate manifest shape and blocked-tier policy.")
    parser.add_argument("--list", action="store_true", help="Print manifest entries and negative tests without running them.")
    parser.add_argument("--dry-run", action="store_true", help="Resolve selections and commands without executing simulator/decoder gates.")
    parser.add_argument("--trace-headers", action="store_true", help="Force trace_headers for executed bitstreams even if the entry does not require it.")
    parser.add_argument("--framemd5", action="store_true", help="Force framemd5 for executed bitstreams even if the entry does not require it.")
    parser.add_argument("--command-timeout", type=int, default=1800, help="Per external command timeout in seconds.")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    root = repo_root()
    manifest = load_json(args.manifest if args.manifest.is_absolute() else root / args.manifest)
    output = args.output if args.output.is_absolute() else root / args.output

    validation = validate_manifest(manifest)
    selected_entries = select_entries(manifest, args)
    selected_negatives = select_negative_tests(manifest, args)

    if args.list:
        print_entry_listing(manifest)

    if not any([selected_entries, selected_negatives, args.audit_only, args.validate_manifest, args.list]):
        raise SystemExit(
            "No work selected. Use --case NAME, --tier T0-GREEN, --negative ID, --audit-only, --validate-manifest, or --list."
        )

    summary: dict[str, Any] = {
        "schema_version": "h264-verification-run-summary/v1",
        "runner": relpath(Path(__file__), root),
        "manifest": {"path": str(args.manifest), "hash": sha256_file(args.manifest if args.manifest.is_absolute() else root / args.manifest)},
        "started_at_unix": now_utc_seconds(),
        "repo": git_commit(root),
        "validation": validation,
        "selection": {
            "cases": args.cases or [],
            "tiers": args.tiers or [],
            "include_pending": args.include_pending,
            "negative_tests": args.negative_tests or [],
            "audit_only": args.audit_only,
            "dry_run": args.dry_run,
        },
        "results": [],
        "negative_results": [],
        "audit": None,
    }

    if validation and validation.get("status") == "FAIL" and args.validate_manifest and not (selected_entries or selected_negatives or args.audit_only):
        write_json(output, summary)
        print(f"[FAIL] Manifest validation failed; wrote {output}")
        return 1

    for entry in selected_entries:
        if entry.get("kind") == "smoke_case":
            result = run_smoke_entry(entry, args, manifest)
        else:
            result = run_feature_placeholder(entry, args, manifest)
        summary["results"].append(result)
        print(f"[{result['status']}] {result.get('id')}: {result.get('reason')}")
        write_json(output, summary)

    for neg in selected_negatives:
        result = run_negative_test(neg, args)
        summary["negative_results"].append(result)
        print(f"[{result['status']}] {result.get('id')}: {result.get('reason')}")
        write_json(output, summary)

    if args.audit_only:
        audit = static_rtl_ownership_audit()
        summary["audit"] = audit
        print(f"[{audit['status']}] OWN-001 audit: {audit.get('reason')}")
        write_json(output, summary)

    summary["ended_at_unix"] = now_utc_seconds()
    write_json(output, summary)
    print(f"[PASS] Wrote manifest run summary to {output}")

    statuses = [item.get("status") for item in summary["results"]]
    statuses.extend(item.get("status") for item in summary["negative_results"])
    if summary.get("audit"):
        statuses.append(summary["audit"].get("status"))
    if validation:
        statuses.append(validation.get("status"))
    if "FAIL" in statuses:
        return 1
    blocked_non_dry = any(item.get("status") == "BLOCKED" and not args.dry_run for item in summary["results"])
    if blocked_non_dry:
        return 2
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except HarnessError as exc:
        print(f"[FAIL] {exc}", file=sys.stderr)
        sys.exit(1)
