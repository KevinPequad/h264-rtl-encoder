#!/usr/bin/env python3
"""Helpers for staged RTL builds and simulator runs under Linux/WSL."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
import shutil
import subprocess
import tempfile


DEFAULT_JOBS = 24


@dataclass(frozen=True)
class BuildConfig:
    width: int
    height: int
    bit_depth: int
    chroma_format_idc: int
    jobs: int = DEFAULT_JOBS
    trace: bool = False
    extra_verilator_args: tuple[str, ...] = ()
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
    idr_interval: int = 12
    force_b_slice: int = 0
    force_bref_slice: int = 0


def repo_root() -> Path:
    return Path(__file__).resolve().parents[1]


def require_tool(tool: str) -> None:
    if shutil.which(tool) is None:
        raise FileNotFoundError(f"Required tool not found on PATH: {tool}")


def run_cmd(cmd: list[str], cwd: Path | None = None, capture: bool = False) -> subprocess.CompletedProcess[str]:
    kwargs = {
        "cwd": str(cwd) if cwd is not None else None,
        "check": True,
        "text": True,
    }
    if capture:
        kwargs["capture_output"] = True
    return subprocess.run(cmd, **kwargs)


def format_cmd(cmd: list[str]) -> str:
    return " ".join(cmd)


def stage_workspace(prefix: str) -> Path:
    root = repo_root()
    workspace = Path(tempfile.mkdtemp(prefix=prefix))
    shutil.copytree(root / "rtl", workspace / "rtl")
    shutil.copytree(
        root / "tb",
        workspace / "tb",
        ignore=shutil.ignore_patterns("obj_dir", "Vh264_encoder_top"),
    )
    return workspace


def build_sim(workspace: Path, config: BuildConfig, build_log_path: Path | None = None) -> Path:
    tb_dir = workspace / "tb"
    build_logs: list[str] = []

    clean_cmd = ["make", "clean"]
    clean_proc = run_cmd(clean_cmd, cwd=tb_dir, capture=True)
    build_logs.append(f"$ {format_cmd(clean_cmd)}\n")
    if clean_proc.stdout:
        build_logs.append(clean_proc.stdout)
    if clean_proc.stderr:
        build_logs.append(clean_proc.stderr)

    cmd = [
        "make",
        f"-j{config.jobs}",
        "all",
        f"WIDTH={config.width}",
        f"HEIGHT={config.height}",
        f"BIT_DEPTH={config.bit_depth}",
        f"CHROMA_FORMAT_IDC={config.chroma_format_idc}",
        f"TRACE={1 if config.trace else 0}",
        f"WEIGHTED_PRED_ENABLE={config.weighted_pred_enable}",
        f"LUMA_LOG2_WEIGHT_DENOM={config.luma_log2_weight_denom}",
        f"LUMA_WEIGHT={config.luma_weight}",
        f"LUMA_OFFSET={config.luma_offset}",
        f"CHROMA_LOG2_WEIGHT_DENOM={config.chroma_log2_weight_denom}",
        f"CHROMA_WEIGHT_CB={config.chroma_weight_cb}",
        f"CHROMA_OFFSET_CB={config.chroma_offset_cb}",
        f"CHROMA_WEIGHT_CR={config.chroma_weight_cr}",
        f"CHROMA_OFFSET_CR={config.chroma_offset_cr}",
        f"ENABLE_IDR_IPCM={config.enable_idr_ipcm}",
        f"ENABLE_P_IPCM={config.enable_p_ipcm}",
        f"IPCM_SAD_THRESHOLD={config.ipcm_sad_threshold}",
        f"INTER_SAD_THRESHOLD={config.inter_sad_threshold}",
    ]
    if config.extra_verilator_args:
        cmd.append(f"EXTRA_VERILATOR_ARGS={' '.join(config.extra_verilator_args)}")
    build_proc = run_cmd(cmd, cwd=tb_dir, capture=True)
    build_logs.append(f"$ {format_cmd(cmd)}\n")
    if build_proc.stdout:
        build_logs.append(build_proc.stdout)
    if build_proc.stderr:
        build_logs.append(build_proc.stderr)
    if build_log_path is not None:
        build_log_path.parent.mkdir(parents=True, exist_ok=True)
        build_log_path.write_text("".join(build_logs), encoding="utf-8")
    return tb_dir / "Vh264_encoder_top"


def run_sim(
    sim_bin: Path,
    frames: int,
    timeout: int,
    input_path: Path,
    output_path: Path,
    idr_interval: int = 12,
    force_b_slice: int = 0,
    force_bref_slice: int = 0,
    trace: bool = False,
    trace_file: Path | None = None,
    capture: bool = False,
) -> subprocess.CompletedProcess[str]:
    output_path.parent.mkdir(parents=True, exist_ok=True)
    cmd = [
        str(sim_bin),
        f"+frames={frames}",
        f"+timeout={timeout}",
        f"+input={input_path}",
        f"+output={output_path}",
        f"+idr_interval={idr_interval}",
    ]
    if force_b_slice:
        cmd.append("+force_b_slice=1")
    if force_bref_slice:
        cmd.append("+force_bref_slice=1")
    if trace:
        cmd.append("+trace")
        if trace_file is not None:
            cmd.append(f"+trace_file={trace_file}")
    return run_cmd(cmd, cwd=sim_bin.parent, capture=capture)
