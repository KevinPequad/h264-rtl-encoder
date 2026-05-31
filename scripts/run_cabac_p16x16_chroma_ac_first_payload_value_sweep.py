#!/usr/bin/env python3
"""Representative first-CABAC-payload value sweep for chroma AC.

The earlier substitution probes proved that changing only the first CABAC byte
after the locked P-slice header tail from 0xeb to 0x75 or 0x6b can promote the
current sparse chroma-AC short-decode cases.  This bounded sweep keeps the RTL
checkout unchanged and mutates that single byte through all 256 values for a few
representative Cb-only and Cb+Cr cases.

The goal is not to endorse byte patching.  It locks that the promotion is a wide
arithmetic-decode equivalence class rather than a unique 0x75/0x6b signature, so
the source repair needs to target the CABAC state/renormalization boundary that
makes baseline 0xeb land outside the class.
"""

from __future__ import annotations

import os
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from scripts.rtl_runner import BuildConfig, build_sim, stage_workspace

WIDTH = HEIGHT = 16
FRAME_SIZE = WIDTH * HEIGHT * 3 // 2
LUMA_SIZE = WIDTH * HEIGHT
CHROMA_SIZE = WIDTH * HEIGHT // 4
EXPECTED_BYTES = FRAME_SIZE * 2
EXPECTED_HEADER_TAIL = 0x6B
BASELINE_FIRST_PAYLOAD = 0xEB
KNOWN_PROMOTED = {0x6B, 0x75}

CASES = {
    "cb_mask1": {"cb_mask": 0x1, "cr_mask": 0x0, "u_sad": 64, "v_sad": 0, "pass_count": 180, "baseline_strict": False},
    "cb_mask2": {"cb_mask": 0x2, "cr_mask": 0x0, "u_sad": 64, "v_sad": 0, "pass_count": 180, "baseline_strict": False},
    "cb_maskc": {"cb_mask": 0xC, "cr_mask": 0x0, "u_sad": 128, "v_sad": 0, "pass_count": 181, "baseline_strict": False},
    "cbcr_dense": {"cb_mask": 0xF, "cr_mask": 0xF, "u_sad": 256, "v_sad": 256, "pass_count": 174, "baseline_strict": True},
}


def checker_chroma(mask: int) -> bytes:
    return bytes(
        136
        if ((mask >> ((1 if x >= 4 else 0) + (2 if y >= 4 else 0))) & 1 and ((x + y) & 1))
        else 128
        for y in range(HEIGHT // 2)
        for x in range(WIDTH // 2)
    )


def make_fixture(name: str, cb_mask: int, cr_mask: int) -> Path:
    y0 = bytes([64]) * LUMA_SIZE
    y1 = bytes([64]) * LUMA_SIZE
    flat = bytes([128]) * CHROMA_SIZE
    data_dir = ROOT / "data"
    data_dir.mkdir(parents=True, exist_ok=True)
    path = data_dir / f"smoke_16x16_2f_cabac_p16x16_chroma_ac_first_payload_value_sweep_{name}.yuv"
    path.write_bytes(y0 + flat + flat + y1 + checker_chroma(cb_mask) + checker_chroma(cr_mask))
    print(f"[INFO] CHRAC_FIRST_PAYLOAD_VALUE {name} fixture {path.relative_to(ROOT)} size={path.stat().st_size}")
    return path


def build_baseline_sim() -> Path:
    workspace = Path(stage_workspace("h264_cabac_chrac_first_payload_value_sweep_"))
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
    print(f"[INFO] CHRAC_FIRST_PAYLOAD_VALUE workspace={workspace} sim={sim}")
    return sim


def run_case(sim: Path, name: str, fixture: Path) -> bytes:
    out_dir = ROOT / "output" / "cabac_chroma_ac_first_payload_value_sweep"
    out_dir.mkdir(parents=True, exist_ok=True)
    h264 = out_dir / f"{name}.h264"
    sim_log = out_dir / f"{name}.sim.log"
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
    sim_text = sim_log.read_text(encoding="utf-8", errors="replace")
    for needle in ("cabac_p16x16_mbs=1", "cabac_chroma_ac_mbs=1"):
        if needle not in sim_text:
            raise SystemExit(f"[FAIL] CHRAC_FIRST_PAYLOAD_VALUE {name} sim log missing {needle}")
    return h264.read_bytes()


def first_payload_index(stream: bytes, name: str) -> int:
    last_start = stream.rfind(b"\x00\x00\x00\x01")
    if last_start < 0:
        raise SystemExit(f"[FAIL] CHRAC_FIRST_PAYLOAD_VALUE {name} missing final Annex-B start code")
    header_tail_idx = last_start + 8
    first_idx = last_start + 9
    if first_idx >= len(stream):
        raise SystemExit(f"[FAIL] CHRAC_FIRST_PAYLOAD_VALUE {name} missing first CABAC payload byte")
    if stream[header_tail_idx] != EXPECTED_HEADER_TAIL:
        raise SystemExit(
            f"[FAIL] CHRAC_FIRST_PAYLOAD_VALUE {name} header tail 0x{stream[header_tail_idx]:02x}, "
            f"expected 0x{EXPECTED_HEADER_TAIL:02x}"
        )
    if stream[first_idx] != BASELINE_FIRST_PAYLOAD:
        raise SystemExit(
            f"[FAIL] CHRAC_FIRST_PAYLOAD_VALUE {name} baseline first payload 0x{stream[first_idx]:02x}, "
            f"expected 0x{BASELINE_FIRST_PAYLOAD:02x}"
        )
    return first_idx


def decode_raw(stream: bytes) -> tuple[bytes, str]:
    with tempfile.NamedTemporaryFile(prefix="h264_chrac_value_sweep_", suffix=".h264", delete=False) as h264_tmp:
        h264_tmp.write(stream)
        h264_path = Path(h264_tmp.name)
    with tempfile.NamedTemporaryFile(prefix="h264_chrac_value_sweep_", suffix=".yuv", delete=False) as raw_tmp:
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
                str(h264_path),
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
        h264_path.unlink(missing_ok=True)
        raw_path.unlink(missing_ok=True)


def is_expected_decode(raw: bytes, err: str, fixture: Path, expected_u_sad: int, expected_v_sad: int) -> bool:
    if err.strip() or len(raw) != EXPECTED_BYTES:
        return False
    src = fixture.read_bytes()
    if raw[:FRAME_SIZE] != src[:FRAME_SIZE]:
        return False
    u0 = FRAME_SIZE + LUMA_SIZE
    v0 = u0 + CHROMA_SIZE
    u_sad = sum(abs(raw[u0 + i] - src[u0 + i]) for i in range(CHROMA_SIZE))
    v_sad = sum(abs(raw[v0 + i] - src[v0 + i]) for i in range(CHROMA_SIZE))
    return u_sad == expected_u_sad and v_sad == expected_v_sad


def compact_ranges(values: list[int]) -> str:
    ranges: list[str] = []
    start = prev = values[0]
    for value in values[1:]:
        if value == prev + 1:
            prev = value
            continue
        ranges.append(f"0x{start:02x}" if start == prev else f"0x{start:02x}-0x{prev:02x}")
        start = prev = value
    ranges.append(f"0x{start:02x}" if start == prev else f"0x{start:02x}-0x{prev:02x}")
    return ",".join(ranges)


def check_case(sim: Path, name: str, spec: dict[str, int | bool]) -> None:
    fixture = make_fixture(name, int(spec["cb_mask"]), int(spec["cr_mask"]))
    stream = run_case(sim, name, fixture)
    first_idx = first_payload_index(stream, name)

    pass_values: list[int] = []
    for value in range(256):
        mutated = bytearray(stream)
        mutated[first_idx] = value
        raw, err = decode_raw(bytes(mutated))
        if is_expected_decode(raw, err, fixture, int(spec["u_sad"]), int(spec["v_sad"])):
            pass_values.append(value)

    expected_count = int(spec["pass_count"])
    if len(pass_values) != expected_count:
        raise SystemExit(
            f"[FAIL] CHRAC_FIRST_PAYLOAD_VALUE {name} pass-count {len(pass_values)}, expected {expected_count}: "
            f"{compact_ranges(pass_values)}"
        )

    pass_set = set(pass_values)
    if not KNOWN_PROMOTED.issubset(pass_set):
        raise SystemExit(f"[FAIL] CHRAC_FIRST_PAYLOAD_VALUE {name} lost known promoted values {sorted(KNOWN_PROMOTED - pass_set)}")
    baseline_strict = bool(spec["baseline_strict"])
    if (BASELINE_FIRST_PAYLOAD in pass_set) != baseline_strict:
        raise SystemExit(
            f"[FAIL] CHRAC_FIRST_PAYLOAD_VALUE {name} baseline 0xeb strict={BASELINE_FIRST_PAYLOAD in pass_set}, "
            f"expected {baseline_strict}"
        )

    print(
        f"[PASS] CHRAC_FIRST_PAYLOAD_VALUE {name} pass_count={len(pass_values)} "
        f"baseline_0xeb_strict={baseline_strict} ranges={compact_ranges(pass_values)}"
    )


def main() -> None:
    sim = build_baseline_sim()
    for name, spec in CASES.items():
        check_case(sim, name, spec)
    print(
        "[PASS] CABAC P16x16 chroma-AC first-payload value sweep locks broad decode-equivalence classes; "
        "0x6b/0x75 remain promoted controls, but baseline sparse Cb 0xeb stays outside the class"
    )


if __name__ == "__main__":
    main()
