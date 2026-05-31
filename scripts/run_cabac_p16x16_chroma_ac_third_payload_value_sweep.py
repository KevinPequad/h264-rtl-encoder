#!/usr/bin/env python3
"""Representative third-CABAC-payload value sweep for chroma AC.

The first- and second-payload sweeps showed broad/non-unique decode-equivalence
classes around the `d0 08 08 6b eb ...` CABAC residual boundary.  This bounded
diagnostic keeps the RTL checkout unchanged and mutates only the third CABAC
payload byte for three representative currently-bad cases.  It locks that the
baseline third byte is also outside the strict expected-SAD class while the pass
sets remain narrow and non-unique.
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
EXPECTED_HEADER_TAIL = 0x6B
BASELINE_FIRST_PAYLOAD = 0xEB

CASES = {
    "cb_mask1": {
        "cb_mask": 0x1,
        "cr_mask": 0x0,
        "u_sad": 64,
        "v_sad": 0,
        "pass_count": 16,
        "baseline_second_payload": 0x2E,
        "baseline_third_payload": 0xD2,
    },
    "cr_mask3": {
        "cb_mask": 0x0,
        "cr_mask": 0x3,
        "u_sad": 0,
        "v_sad": 128,
        "pass_count": 42,
        "baseline_second_payload": 0x30,
        "baseline_third_payload": 0x26,
    },
    "cbcr_sparse_pair": {
        "cb_mask": 0x1,
        "cr_mask": 0x1,
        "u_sad": 64,
        "v_sad": 64,
        "pass_count": 23,
        "baseline_second_payload": 0x2E,
        "baseline_third_payload": 0xE2,
    },
}

EXPECTED_PASS_RANGES = {
    "cb_mask1": "0x07,0x64-0x65,0x67-0x6c,0x70,0x86-0x87,0x94,0xa0,0xfd-0xfe",
    "cr_mask3": "0x1a,0x2d-0x36,0x38-0x3a,0x40,0x50-0x51,0x5e,0x60,0x66,0x75,0x79,0xb3,0xc6-0xcf,0xd1-0xd3,0xd9,0xe9-0xea,0xf7,0xf9,0xff",
    "cbcr_sparse_pair": "0x00,0x03,0x08,0x11,0x5a,0x63-0x64,0x66-0x6b,0x6f-0x70,0x99,0x9c,0xa1,0xaa,0xf3,0xfc-0xfd,0xff",
}

EXPECTED_BASELINE_STREAMS = {
    "cb_mask1": (449, "8080800000000141d008086beb2ed226"),
    "cr_mask3": (452, "0000000141d008086beb3026a0abd3f7"),
    "cbcr_sparse_pair": (451, "800000000141d008086beb2ee2d45ea4"),
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
    path = data_dir / f"smoke_16x16_2f_cabac_p16x16_chroma_ac_third_payload_value_sweep_{name}.yuv"
    path.write_bytes(y0 + flat + flat + y1 + checker_chroma(cb_mask) + checker_chroma(cr_mask))
    print(f"[INFO] CHRAC_THIRD_PAYLOAD_VALUE {name} fixture {path.relative_to(ROOT)} size={path.stat().st_size}")
    return path


def build_baseline_sim() -> Path:
    workspace = Path(stage_workspace("h264_cabac_chrac_third_payload_value_sweep_"))
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
    print(f"[INFO] CHRAC_THIRD_PAYLOAD_VALUE workspace={workspace} sim={sim}")
    return sim


def run_case(sim: Path, name: str, fixture: Path) -> bytes:
    out_dir = ROOT / "output" / "cabac_chroma_ac_third_payload_value_sweep"
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
            raise SystemExit(f"[FAIL] CHRAC_THIRD_PAYLOAD_VALUE {name} sim log missing {needle}")
    return h264.read_bytes()


def check_baseline_stream(stream: bytes, name: str) -> None:
    expected_len, expected_tail_hex = EXPECTED_BASELINE_STREAMS[name]
    actual_tail = stream[-16:].hex()
    if len(stream) != expected_len:
        raise SystemExit(
            f"[FAIL] CHRAC_THIRD_PAYLOAD_VALUE {name} stream length {len(stream)}, expected {expected_len}"
        )
    if actual_tail != expected_tail_hex:
        raise SystemExit(
            f"[FAIL] CHRAC_THIRD_PAYLOAD_VALUE {name} final tail drifted:\n"
            f"  got      {actual_tail}\n"
            f"  expected {expected_tail_hex}"
        )


def payload_indices(stream: bytes, name: str) -> tuple[int, int, int]:
    last_start = stream.rfind(b"\x00\x00\x00\x01")
    if last_start < 0:
        raise SystemExit(f"[FAIL] CHRAC_THIRD_PAYLOAD_VALUE {name} missing final Annex-B start code")
    header_tail_idx = last_start + 8
    first_idx = last_start + 9
    second_idx = last_start + 10
    third_idx = last_start + 11
    if third_idx >= len(stream):
        raise SystemExit(f"[FAIL] CHRAC_THIRD_PAYLOAD_VALUE {name} missing third CABAC payload byte")
    if stream[header_tail_idx] != EXPECTED_HEADER_TAIL:
        raise SystemExit(
            f"[FAIL] CHRAC_THIRD_PAYLOAD_VALUE {name} header tail 0x{stream[header_tail_idx]:02x}, "
            f"expected 0x{EXPECTED_HEADER_TAIL:02x}"
        )
    if stream[first_idx] != BASELINE_FIRST_PAYLOAD:
        raise SystemExit(
            f"[FAIL] CHRAC_THIRD_PAYLOAD_VALUE {name} baseline first payload 0x{stream[first_idx]:02x}, "
            f"expected 0x{BASELINE_FIRST_PAYLOAD:02x}"
        )
    return first_idx, second_idx, third_idx


def decode_raw(stream: bytes) -> tuple[bytes, str]:
    with tempfile.NamedTemporaryFile(prefix="h264_chrac_third_value_sweep_", suffix=".h264", delete=False) as h264_tmp:
        h264_tmp.write(stream)
        h264_path = Path(h264_tmp.name)
    with tempfile.NamedTemporaryFile(prefix="h264_chrac_third_value_sweep_", suffix=".yuv", delete=False) as raw_tmp:
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


def check_case(sim: Path, name: str, spec: dict[str, int]) -> None:
    fixture = make_fixture(name, spec["cb_mask"], spec["cr_mask"])
    stream = run_case(sim, name, fixture)
    check_baseline_stream(stream, name)
    _, second_idx, third_idx = payload_indices(stream, name)
    baseline_second_payload = spec["baseline_second_payload"]
    baseline_third_payload = spec["baseline_third_payload"]
    if stream[second_idx] != baseline_second_payload:
        raise SystemExit(
            f"[FAIL] CHRAC_THIRD_PAYLOAD_VALUE {name} baseline second payload 0x{stream[second_idx]:02x}, "
            f"expected 0x{baseline_second_payload:02x}"
        )
    if stream[third_idx] != baseline_third_payload:
        raise SystemExit(
            f"[FAIL] CHRAC_THIRD_PAYLOAD_VALUE {name} baseline third payload 0x{stream[third_idx]:02x}, "
            f"expected 0x{baseline_third_payload:02x}"
        )

    pass_values: list[int] = []
    for value in range(256):
        mutated = bytearray(stream)
        mutated[third_idx] = value
        raw, err = decode_raw(bytes(mutated))
        if is_expected_decode(raw, err, fixture, spec["u_sad"], spec["v_sad"]):
            pass_values.append(value)

    actual_ranges = compact_ranges(pass_values)
    if len(pass_values) != spec["pass_count"]:
        raise SystemExit(
            f"[FAIL] CHRAC_THIRD_PAYLOAD_VALUE {name} pass-count {len(pass_values)}, expected {spec['pass_count']}: "
            f"{actual_ranges}"
        )
    if actual_ranges != EXPECTED_PASS_RANGES[name]:
        raise SystemExit(
            f"[FAIL] CHRAC_THIRD_PAYLOAD_VALUE {name} pass ranges drifted:\n"
            f"  got      {actual_ranges}\n"
            f"  expected {EXPECTED_PASS_RANGES[name]}"
        )
    if baseline_third_payload in pass_values:
        raise SystemExit(
            f"[FAIL] CHRAC_THIRD_PAYLOAD_VALUE {name} baseline third payload 0x{baseline_third_payload:02x} "
            "unexpectedly strict-decodes"
        )
    print(
        f"[PASS] CHRAC_THIRD_PAYLOAD_VALUE {name} pass_count={len(pass_values)} "
        f"baseline_second=0x{baseline_second_payload:02x} baseline_third=0x{baseline_third_payload:02x} "
        f"baseline_strict=False ranges={actual_ranges}"
    )


def main() -> None:
    sim = build_baseline_sim()
    for name, spec in CASES.items():
        check_case(sim, name, spec)
    print(
        "[PASS] CABAC P16x16 chroma-AC third-payload value sweep locks narrow decode-equivalence classes "
        "for representative Cb-only, Cr-only, and sparse Cb+Cr misses; baseline third payload bytes stay "
        "outside the strict expected-SAD classes, keeping the repair target on CABAC arithmetic/renormalization "
        "rather than literal bytestream patching."
    )


if __name__ == "__main__":
    main()
