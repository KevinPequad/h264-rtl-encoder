#!/usr/bin/env python3
"""Staged CABAC initial-queue neighborhood sweep for chroma AC.

This diagnostic rebuilds isolated workspaces with nearby CABAC core
`cod_i_queue` initial values around the checked-in `-7` source value.  The
earlier `-9 -> -8` probe showed that `-8` promotes sparse Cb/Cr chroma-AC masks
but regresses a dense Cb+Cr guard.  This bounded sweep locks the neighborhood:
legacy `-9` keeps the old sparse Cb miss signatures, `-8` keeps the known dense
guard regression, `-10` overflows, and the source `-7` candidate is the sampled
plane-safe value for representative sparse and dense controls.
"""

from __future__ import annotations

import os
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from scripts.rtl_runner import BuildConfig, build_sim, stage_workspace  # noqa: E402

WIDTH = HEIGHT = 16
FRAME_SIZE = WIDTH * HEIGHT * 3 // 2
LUMA_SIZE = WIDTH * HEIGHT
CHROMA_SIZE = WIDTH * HEIGHT // 4
EXPECTED_BYTES = FRAME_SIZE * 2
QUEUE_ANCHOR = "cod_i_queue       <= -8'sd7;"
SOURCE_QUEUE = -7
SWEEP_VALUES = (-10, -9, -8, -7)


def checker_chroma(mask: int) -> bytes:
    return bytes(
        136 if ((mask >> ((1 if x >= 4 else 0) + (2 if y >= 4 else 0))) & 1 and ((x + y) & 1)) else 128
        for y in range(HEIGHT // 2)
        for x in range(WIDTH // 2)
    )


def make_fixture(name: str, cb_mask: int, cr_mask: int) -> Path:
    y0 = bytes([64]) * LUMA_SIZE
    y1 = bytes([64]) * LUMA_SIZE
    flat = bytes([128]) * CHROMA_SIZE
    data_dir = ROOT / "data"
    data_dir.mkdir(parents=True, exist_ok=True)
    path = data_dir / f"smoke_16x16_2f_cabac_p16x16_chroma_ac_queue_init_sweep_{name}.yuv"
    path.write_bytes(y0 + flat + flat + y1 + checker_chroma(cb_mask) + checker_chroma(cr_mask))
    print(
        f"[INFO] CHRAC_QUEUE_INIT {name} fixture {path.relative_to(ROOT)} "
        f"cb=0x{cb_mask:x} cr=0x{cr_mask:x} size={path.stat().st_size}"
    )
    return path


def patch_queue(workspace: Path, value: int) -> None:
    if value == SOURCE_QUEUE:
        return
    core = workspace / "rtl" / "h264_cabac_core.v"
    text = core.read_text(encoding="utf-8")
    count = text.count(QUEUE_ANCHOR)
    if count != 2:
        raise SystemExit(f"[FAIL] CHRAC_QUEUE_INIT expected exactly two queue anchors, found {count}")
    replacement = f"cod_i_queue       <= -8'sd{abs(value)};"
    core.write_text(text.replace(QUEUE_ANCHOR, replacement), encoding="utf-8")


def build_candidate(value: int) -> Path:
    name = f"m{abs(value)}"
    workspace = Path(stage_workspace(f"h264_cabac_chrac_queue_init_{name}_"))
    patch_queue(workspace, value)
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
    print(f"[INFO] CHRAC_QUEUE_INIT q={value} workspace={workspace} sim={sim}")
    return sim


def decode_raw(h264: Path) -> tuple[bytes, str]:
    with tempfile.NamedTemporaryFile(prefix="h264_chrac_queue_init_", suffix=".yuv", delete=False) as raw_tmp:
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


def run_case(sim: Path, q_value: int, name: str, fixture: Path) -> tuple[str, int, str, int, int, str]:
    out_dir = ROOT / "output" / "cabac_chroma_ac_queue_init_sweep" / f"m{abs(q_value)}"
    out_dir.mkdir(parents=True, exist_ok=True)
    h264 = out_dir / f"{name}.h264"
    sim_log = out_dir / f"{name}.sim.log"
    with sim_log.open("w", encoding="utf-8") as log:
        proc = subprocess.run(
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
            check=False,
        )
    sim_text = sim_log.read_text(encoding="utf-8", errors="replace")
    if proc.returncode != 0:
        signature = next((line.strip() for line in sim_text.splitlines() if "%Error:" in line or "Assertion failed" in line), "")
        print(
            f"[INFO] CHRAC_QUEUE_INIT q={q_value} {name}: sim_abort "
            f"returncode={proc.returncode} sig={signature!r}"
        )
        return "sim_abort", 0, signature, -1, -1, ""
    if "cabac_p16x16_mbs=1" not in sim_text or "cabac_chroma_ac_mbs=1" not in sim_text:
        raise SystemExit(f"[FAIL] CHRAC_QUEUE_INIT q={q_value} {name} did not exercise integrated chroma AC")
    raw, err = decode_raw(h264)
    stream = h264.read_bytes()
    tail = stream[stream.rfind(b"\x00\x00\x00\x01") :].hex()
    src = fixture.read_bytes()
    u_sad = v_sad = -1
    if len(raw) == EXPECTED_BYTES and not err.strip():
        if raw[:FRAME_SIZE] != src[:FRAME_SIZE]:
            raise SystemExit(f"[FAIL] CHRAC_QUEUE_INIT q={q_value} {name} changed the IDR reference frame")
        u0 = FRAME_SIZE + LUMA_SIZE
        v0 = u0 + CHROMA_SIZE
        u_sad = sum(abs(raw[u0 + i] - src[u0 + i]) for i in range(CHROMA_SIZE))
        v_sad = sum(abs(raw[v0 + i] - src[v0 + i]) for i in range(CHROMA_SIZE))
        outcome = "strict"
    else:
        outcome = "short"
    signature = err.strip().splitlines()[0] if err.strip() else ""
    print(
        f"[INFO] CHRAC_QUEUE_INIT q={q_value} {name}: {outcome} "
        f"decoded={len(raw)}/{EXPECTED_BYTES} U_SAD={u_sad} V_SAD={v_sad} "
        f"sig={signature!r} tail={tail}"
    )
    return outcome, len(raw), signature, u_sad, v_sad, tail


def expect(result: tuple[str, int, str, int, int, str], *, outcome: str, u_sad: int | None = None, v_sad: int | None = None, sig: str | None = None) -> None:
    got_outcome, got_len, got_sig, got_u, got_v, _tail = result
    if got_outcome != outcome:
        raise SystemExit(f"[FAIL] CHRAC_QUEUE_INIT expected {outcome}, got {got_outcome} decoded={got_len} sig={got_sig!r}")
    if outcome == "strict":
        if got_len != EXPECTED_BYTES or got_u != u_sad or got_v != v_sad:
            raise SystemExit(
                f"[FAIL] CHRAC_QUEUE_INIT strict SAD drift: decoded={got_len}/{EXPECTED_BYTES} "
                f"U={got_u} V={got_v}, expected U={u_sad} V={v_sad}"
            )
    elif sig is not None and sig not in got_sig:
        raise SystemExit(f"[FAIL] CHRAC_QUEUE_INIT short signature drift: got {got_sig!r}, expected contains {sig!r}")


def main() -> None:
    cases = {
        "cb_mask1": make_fixture("cb_mask1", 0x1, 0x0),
        "cb_mask2": make_fixture("cb_mask2", 0x2, 0x0),
        "cb_mask3": make_fixture("cb_mask3", 0x3, 0x0),
        "dense_both": make_fixture("dense_both", 0xF, 0xF),
    }
    all_results: dict[int, dict[str, tuple[str, int, str, int, int, str]]] = {}
    for q_value in SWEEP_VALUES:
        sim = build_candidate(q_value)
        all_results[q_value] = {name: run_case(sim, q_value, name, fixture) for name, fixture in cases.items()}

    # Legacy baseline and known -8 candidate anchors must stay locked, while
    # the checked-in -7 source value must keep the sampled sparse/dense controls
    # strict.  The -10 neighbor is intentionally only reported because it aborts
    # before completing the P frame.
    expect(all_results[-9]["cb_mask1"], outcome="short", sig="bytestream -19")
    expect(all_results[-9]["cb_mask2"], outcome="short", sig="bytestream -21")
    expect(all_results[-9]["cb_mask3"], outcome="strict", u_sad=128, v_sad=0)
    expect(all_results[-9]["dense_both"], outcome="strict", u_sad=256, v_sad=256)

    expect(all_results[-8]["cb_mask1"], outcome="strict", u_sad=64, v_sad=0)
    expect(all_results[-8]["cb_mask2"], outcome="strict", u_sad=64, v_sad=0)
    expect(all_results[-8]["cb_mask3"], outcome="strict", u_sad=128, v_sad=0)
    expect(all_results[-8]["dense_both"], outcome="short", sig="bytestream -9")

    expect(all_results[-7]["cb_mask1"], outcome="strict", u_sad=64, v_sad=0)
    expect(all_results[-7]["cb_mask2"], outcome="strict", u_sad=64, v_sad=0)
    expect(all_results[-7]["cb_mask3"], outcome="strict", u_sad=128, v_sad=0)
    expect(all_results[-7]["dense_both"], outcome="strict", u_sad=256, v_sad=256)

    safe = [
        q_value
        for q_value, results in all_results.items()
        if all(results[name][0] == "strict" for name in cases)
        and results["cb_mask1"][3:5] == (64, 0)
        and results["cb_mask2"][3:5] == (64, 0)
        and results["cb_mask3"][3:5] == (128, 0)
        and results["dense_both"][3:5] == (256, 256)
    ]
    if safe != [SOURCE_QUEUE]:
        raise SystemExit(f"[FAIL] CHRAC_QUEUE_INIT sampled safe queue drift: got {safe}, expected [{SOURCE_QUEUE}]")
    print(
        "[PASS] CABAC P16x16 chroma-AC queue-init neighborhood sweep: "
        "legacy -9 and known -8 anchors stay locked, -10 overflows, and the "
        "checked-in -7 queue initializer is the sampled plane-safe candidate "
        "that promotes sparse Cb masks while preserving the dense Cb+Cr guard."
    )


if __name__ == "__main__":
    main()
