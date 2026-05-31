#!/usr/bin/env python3
"""Representative first-CABAC-payload value sweep for chroma AC.

The earlier substitution probes proved that changing only the first CABAC byte
after the locked P-slice header tail from 0xeb to 0x75 or 0x6b can promote the
current sparse chroma-AC short-decode cases.  This bounded sweep keeps the RTL
checkout unchanged and mutates that single byte through all 256 values for a few
representative Cb-only, Cr-only, and Cb+Cr cases, including a mixed-plane
case that already strict-decodes with the wrong chroma reconstruction.

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
    "cr_mask1": {"cb_mask": 0x0, "cr_mask": 0x1, "u_sad": 0, "v_sad": 64, "pass_count": 178, "baseline_strict": True},
    "cr_mask3": {"cb_mask": 0x0, "cr_mask": 0x3, "u_sad": 0, "v_sad": 128, "pass_count": 181, "baseline_strict": False},
    "cr_mask5": {"cb_mask": 0x0, "cr_mask": 0x5, "u_sad": 0, "v_sad": 128, "pass_count": 185, "baseline_strict": False},
    "cbcr_sparse_pair": {"cb_mask": 0x1, "cr_mask": 0x1, "u_sad": 64, "v_sad": 64, "pass_count": 183, "baseline_strict": False},
    "cbcr_dense": {"cb_mask": 0xF, "cr_mask": 0xF, "u_sad": 256, "v_sad": 256, "pass_count": 174, "baseline_strict": True},
    "cbcr_quality_guard": {"cb_mask": 0xE, "cr_mask": 0x1, "u_sad": 192, "v_sad": 64, "pass_count": 190, "baseline_strict": False},
}

EXPECTED_PASS_RANGES = {
    "cb_mask1": "0x00-0xa7,0xad,0xb5,0xb9,0xc6,0xcd,0xe6,0xed-0xee,0xf4-0xf6,0xf9",
    "cb_mask2": "0x00-0xa7,0xa9,0xae,0xb1,0xb5,0xb9,0xc6,0xe4,0xed,0xef,0xf5-0xf6,0xf9",
    "cb_maskc": "0x00-0xa7,0xaf,0xb1,0xb5,0xb9,0xc6-0xc7,0xd3,0xdb,0xe0,0xed-0xee,0xf5-0xf6",
    "cr_mask1": "0x00-0xa7,0xa9,0xab,0xae,0xb5,0xb9,0xc6,0xd4,0xeb,0xed,0xf1",
    "cr_mask3": "0x00-0xa7,0xa9-0xaa,0xb1,0xb5,0xb9,0xc3,0xc6-0xc7,0xcc,0xed,0xf5-0xf6,0xf9",
    "cr_mask5": "0x00-0xa9,0xb1,0xb5-0xb6,0xb9-0xba,0xc6-0xc7,0xd9,0xde,0xe6,0xe8,0xec-0xed,0xf5-0xf6",
    "cbcr_sparse_pair": "0x00-0xa7,0xa9,0xb1,0xb5,0xb9,0xc3,0xc6-0xc7,0xe1,0xe3,0xec-0xed,0xef,0xf5-0xf6,0xf9",
    "cbcr_dense": "0x00-0xa7,0xae,0xb5,0xb9,0xd1,0xeb,0xfd",
    "cbcr_quality_guard": "0x00-0xa9,0xaf,0xb1,0xb5-0xb6,0xb9-0xba,0xc3-0xc4,0xc6-0xc7,0xcc,0xd3,0xe0,0xe9,0xed-0xee,0xf5-0xf6,0xf9,0xfc",
}

EXPECTED_BASELINE_STREAMS = {
    "cb_mask1": (449, "8080800000000141d008086beb2ed226"),
    "cb_mask2": (449, "8080800000000141d008086beb2f6b5d"),
    "cb_maskc": (452, "0000000141d008086beb3189943a6990"),
    "cr_mask1": (449, "8080800000000141d008086beb2f99af"),
    "cr_mask3": (452, "0000000141d008086beb3026a0abd3f7"),
    "cr_mask5": (452, "0000000141d008086beb30431d5bd40a"),
    "cbcr_sparse_pair": (451, "800000000141d008086beb2ee2d45ea4"),
    "cbcr_dense": (446, "8080808080800000000141d008086beb"),
    "cbcr_quality_guard": (455, "0141d008086beb30d80b4fd63286ced3"),
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


def check_baseline_stream(stream: bytes, name: str) -> None:
    expected_len, expected_tail_hex = EXPECTED_BASELINE_STREAMS[name]
    actual_tail = stream[-16:].hex()
    if len(stream) != expected_len:
        raise SystemExit(
            f"[FAIL] CHRAC_FIRST_PAYLOAD_VALUE {name} stream length {len(stream)}, expected {expected_len}"
        )
    if actual_tail != expected_tail_hex:
        raise SystemExit(
            f"[FAIL] CHRAC_FIRST_PAYLOAD_VALUE {name} final tail drifted:\n"
            f"  got      {actual_tail}\n"
            f"  expected {expected_tail_hex}"
        )


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
    check_baseline_stream(stream, name)
    first_idx = first_payload_index(stream, name)

    pass_values: list[int] = []
    for value in range(256):
        mutated = bytearray(stream)
        mutated[first_idx] = value
        raw, err = decode_raw(bytes(mutated))
        if is_expected_decode(raw, err, fixture, int(spec["u_sad"]), int(spec["v_sad"])):
            pass_values.append(value)

    actual_ranges = compact_ranges(pass_values)
    expected_count = int(spec["pass_count"])
    if len(pass_values) != expected_count:
        raise SystemExit(
            f"[FAIL] CHRAC_FIRST_PAYLOAD_VALUE {name} pass-count {len(pass_values)}, expected {expected_count}: "
            f"{actual_ranges}"
        )
    expected_ranges = EXPECTED_PASS_RANGES[name]
    if actual_ranges != expected_ranges:
        raise SystemExit(
            f"[FAIL] CHRAC_FIRST_PAYLOAD_VALUE {name} pass-ranges drifted:\n"
            f"  got      {actual_ranges}\n"
            f"  expected {expected_ranges}"
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
        f"baseline_0xeb_strict={baseline_strict} ranges={actual_ranges}"
    )


def main() -> None:
    sim = build_baseline_sim()
    for name, spec in CASES.items():
        check_case(sim, name, spec)
    print(
        "[PASS] CABAC P16x16 chroma-AC first-payload value sweep locks broad decode-equivalence classes "
        "for representative Cb-only, Cr-only, sparse/dense Cb+Cr, and mixed-plane quality-guard cases; "
        "baseline stream lengths/final tails and 0x6b/0x75 promoted controls are stable, but baseline sparse "
        "Cb/Cr 0xeb stays outside the short/strict-but-wrong-plane repair classes"
    )


if __name__ == "__main__":
    main()
