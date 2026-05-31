#!/usr/bin/env python3
"""Representative cross-plane chroma-AC first-CABAC-payload probe.

The Cb-only and Cr-only first-payload substitution probes showed that changing
only the first CABAC residual payload byte after the locked CABAC P-slice header
(`d0 08 08 6b`) from the current `0xeb` to either `0x75` or `0x6b` promotes all
single-plane sparse chroma-AC masks while preserving a dense both-plane guard.
This probe covers representative mixed Cb+Cr sparse masks so the next RTL repair
cannot accidentally solve only the single-plane fixtures.
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
EXPECTED_FIRST_PAYLOAD = 0xEB
QUEUE_M8_FIRST_PAYLOAD = 0x75
BIT7_PROMOTED_PAYLOAD = 0x6B
EXPECTED_HEADER_TAIL = 0x6B

# Representative cross-plane cases: sparse/sparse top-row, diagonal, split-row,
# bottom/top mirror pairs, plus dense-Cr and dense-Cb controls. These are
# deliberately smaller than the full 15x15 lattice so the cron gate stays bounded.
CASES = {
    (0x1, 0x1): "bytestream -13",
    (0x1, 0x2): "bytestream -9",
    (0x2, 0x1): "bytestream -27",
    (0x3, 0x3): "bytestream -15",
    (0x4, 0x1): "bytestream -13",
    (0x5, 0x5): "bytestream -9",
    (0xC, 0xC): "bytestream -17",
    (0x3, 0xC): "bytestream -7",
    (0xC, 0x3): "bytestream -21",
    (0x1, 0xF): "bytestream -5",
}
BASELINE_STRICT = {(0xF, 0x1), (0x8, 0x2), (0xF, 0xF)}

# Some mixed-plane masks already produce two decoded frames, but with wrong
# chroma-plane reconstruction. Keep one of those as a quality guard: the
# first-payload correction family must repair decoded-plane contents too, not
# merely paper over FFmpeg bytestream errors.
BASELINE_BAD_PLANES = {
    (0xE, 0x1): (240, 192),
}


def checker_chroma(mask: int) -> bytes:
    out = []
    for y in range(HEIGHT // 2):
        for x in range(WIDTH // 2):
            block = (1 if x >= 4 else 0) + (2 if y >= 4 else 0)
            out.append(136 if ((mask >> block) & 1 and ((x + y) % 2)) else 128)
    return bytes(out)


def make_fixture(cb_mask: int, cr_mask: int) -> Path:
    y0 = bytes([64]) * LUMA_SIZE
    y1 = bytes([64]) * LUMA_SIZE
    flat = bytes([128]) * CHROMA_SIZE
    data_dir = ROOT / "data"
    data_dir.mkdir(parents=True, exist_ok=True)
    path = data_dir / (
        "smoke_16x16_2f_cabac_p16x16_chroma_residual_"
        f"cbcr_ac_first_payload_cross_cb{cb_mask:x}_cr{cr_mask:x}.yuv"
    )
    path.write_bytes(y0 + flat + flat + y1 + checker_chroma(cb_mask) + checker_chroma(cr_mask))
    print(
        f"[INFO] CROSS_PLANE_FIRST_PAYLOAD cb=0x{cb_mask:x} cr=0x{cr_mask:x} "
        f"fixture {path} size={path.stat().st_size}"
    )
    return path


def decode_raw(data: bytes) -> tuple[bytes, str]:
    with tempfile.NamedTemporaryFile(prefix="h264_cross_plane_first_payload_", suffix=".h264", delete=False) as h264_tmp:
        h264_tmp.write(data)
        h264_path = Path(h264_tmp.name)
    with tempfile.NamedTemporaryFile(prefix="h264_cross_plane_first_payload_", suffix=".yuv", delete=False) as raw_tmp:
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


def build_baseline_sim() -> Path:
    workspace = Path(stage_workspace("h264_cabac_cross_plane_first_payload_"))
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
    print(f"[INFO] CROSS_PLANE_FIRST_PAYLOAD workspace={workspace} sim={sim}")
    return sim


def run_case(sim: Path, cb_mask: int, cr_mask: int, fixture: Path) -> tuple[bytes, str]:
    out_dir = ROOT / "output" / "cabac_cross_plane_first_payload_probe"
    out_dir.mkdir(parents=True, exist_ok=True)
    case_name = f"cb{cb_mask:x}_cr{cr_mask:x}"
    h264 = out_dir / f"{case_name}.h264"
    sim_log = out_dir / f"{case_name}.sim.log"
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
    for needle in (
        "cabac_p16x16_mbs=1",
        "cb_ac_mbs=1",
        "cr_ac_mbs=1",
        f"cb_ac_blocks={cb_mask.bit_count()}",
        f"cr_ac_blocks={cr_mask.bit_count()}",
    ):
        if needle not in sim_text:
            raise SystemExit(
                f"[FAIL] CROSS_PLANE_FIRST_PAYLOAD cb=0x{cb_mask:x} cr=0x{cr_mask:x} sim log missing {needle}"
            )
    return h264.read_bytes(), sim_text


def first_payload_index(stream: bytes, label: str) -> int:
    last_start = stream.rfind(b"\x00\x00\x00\x01")
    if last_start < 0:
        raise SystemExit(f"[FAIL] CROSS_PLANE_FIRST_PAYLOAD {label} missing final Annex-B start code")
    header_tail_idx = last_start + 8
    first_idx = last_start + 9
    if first_idx >= len(stream):
        raise SystemExit(f"[FAIL] CROSS_PLANE_FIRST_PAYLOAD {label} missing first CABAC payload byte")
    if stream[header_tail_idx] != EXPECTED_HEADER_TAIL:
        raise SystemExit(
            f"[FAIL] CROSS_PLANE_FIRST_PAYLOAD {label} header tail 0x{stream[header_tail_idx]:02x}, "
            f"expected 0x{EXPECTED_HEADER_TAIL:02x}"
        )
    if stream[first_idx] != EXPECTED_FIRST_PAYLOAD:
        raise SystemExit(
            f"[FAIL] CROSS_PLANE_FIRST_PAYLOAD {label} first payload 0x{stream[first_idx]:02x}, "
            f"expected 0x{EXPECTED_FIRST_PAYLOAD:02x}"
        )
    return first_idx


def assert_planes(cb_mask: int, cr_mask: int, fixture: Path, raw: bytes, label: str) -> tuple[int, int]:
    if len(raw) != EXPECTED_BYTES:
        raise SystemExit(
            f"[FAIL] CROSS_PLANE_FIRST_PAYLOAD {label} cb=0x{cb_mask:x} cr=0x{cr_mask:x} "
            f"decoded {len(raw)}/{EXPECTED_BYTES}"
        )
    src = fixture.read_bytes()
    if raw[:FRAME_SIZE] != src[:FRAME_SIZE]:
        raise SystemExit(
            f"[FAIL] CROSS_PLANE_FIRST_PAYLOAD {label} cb=0x{cb_mask:x} cr=0x{cr_mask:x} changed IDR reference"
        )
    u0 = FRAME_SIZE + LUMA_SIZE
    v0 = u0 + CHROMA_SIZE
    u_sad = sum(abs(raw[u0 + i] - src[u0 + i]) for i in range(CHROMA_SIZE))
    v_sad = sum(abs(raw[v0 + i] - src[v0 + i]) for i in range(CHROMA_SIZE))
    expected_u = cb_mask.bit_count() * 64
    expected_v = cr_mask.bit_count() * 64
    if u_sad != expected_u or v_sad != expected_v:
        raise SystemExit(
            f"[FAIL] CROSS_PLANE_FIRST_PAYLOAD {label} cb=0x{cb_mask:x} cr=0x{cr_mask:x} "
            f"SAD U={u_sad} V={v_sad}, expected U={expected_u} V={expected_v}"
        )
    return u_sad, v_sad


def assert_idr_reference(fixture: Path, raw: bytes, label: str) -> None:
    if len(raw) < FRAME_SIZE:
        raise SystemExit(
            f"[FAIL] CROSS_PLANE_FIRST_PAYLOAD {label} decoded only {len(raw)} bytes, "
            f"expected at least the {FRAME_SIZE}-byte IDR frame"
        )
    src = fixture.read_bytes()
    if raw[:FRAME_SIZE] != src[:FRAME_SIZE]:
        raise SystemExit(
            f"[FAIL] CROSS_PLANE_FIRST_PAYLOAD {label} changed IDR reference frame"
        )


def mutate_first_payload(stream: bytes, first_idx: int, value: int) -> bytes:
    mutated = bytearray(stream)
    mutated[first_idx] = value
    return bytes(mutated)


def check_case(
    sim: Path,
    cb_mask: int,
    cr_mask: int,
    expected_short: str | None,
    expected_bad_planes: tuple[int, int] | None = None,
) -> None:
    fixture = make_fixture(cb_mask, cr_mask)
    stream, _sim_text = run_case(sim, cb_mask, cr_mask, fixture)
    first_idx = first_payload_index(stream, f"cb=0x{cb_mask:x} cr=0x{cr_mask:x}")

    baseline_raw, baseline_err = decode_raw(stream)
    if expected_short is None and expected_bad_planes is None:
        if baseline_err.strip():
            raise SystemExit(
                f"[FAIL] CROSS_PLANE_FIRST_PAYLOAD cb=0x{cb_mask:x} cr=0x{cr_mask:x} "
                f"baseline FFmpeg log {baseline_err.strip()!r}"
            )
        base_u, base_v = assert_planes(cb_mask, cr_mask, fixture, baseline_raw, "baseline")
        baseline = f"strict U_SAD={base_u} V_SAD={base_v}"
    elif expected_bad_planes is not None:
        if baseline_err.strip():
            raise SystemExit(
                f"[FAIL] CROSS_PLANE_FIRST_PAYLOAD cb=0x{cb_mask:x} cr=0x{cr_mask:x} "
                f"baseline quality guard FFmpeg log {baseline_err.strip()!r}"
            )
        if len(baseline_raw) != EXPECTED_BYTES:
            raise SystemExit(
                f"[FAIL] CROSS_PLANE_FIRST_PAYLOAD cb=0x{cb_mask:x} cr=0x{cr_mask:x} "
                f"baseline quality guard decoded {len(baseline_raw)}/{EXPECTED_BYTES}"
            )
        src = fixture.read_bytes()
        if baseline_raw[:FRAME_SIZE] != src[:FRAME_SIZE]:
            raise SystemExit(
                f"[FAIL] CROSS_PLANE_FIRST_PAYLOAD cb=0x{cb_mask:x} cr=0x{cr_mask:x} "
                "baseline quality guard changed IDR reference"
            )
        u0 = FRAME_SIZE + LUMA_SIZE
        v0 = u0 + CHROMA_SIZE
        base_u = sum(abs(baseline_raw[u0 + i] - src[u0 + i]) for i in range(CHROMA_SIZE))
        base_v = sum(abs(baseline_raw[v0 + i] - src[v0 + i]) for i in range(CHROMA_SIZE))
        if (base_u, base_v) != expected_bad_planes:
            raise SystemExit(
                f"[FAIL] CROSS_PLANE_FIRST_PAYLOAD cb=0x{cb_mask:x} cr=0x{cr_mask:x} "
                f"baseline quality drift U_SAD={base_u} V_SAD={base_v}, "
                f"expected U_SAD={expected_bad_planes[0]} V_SAD={expected_bad_planes[1]}"
            )
        expected_u = cb_mask.bit_count() * 64
        expected_v = cr_mask.bit_count() * 64
        if (base_u, base_v) == (expected_u, expected_v):
            raise SystemExit(
                f"[FAIL] CROSS_PLANE_FIRST_PAYLOAD cb=0x{cb_mask:x} cr=0x{cr_mask:x} "
                "baseline quality guard unexpectedly matches source-plane SAD"
            )
        baseline = (
            f"strict-bad-plane U_SAD={base_u} V_SAD={base_v} "
            f"expected U_SAD={expected_u} V_SAD={expected_v}"
        )
    else:
        assert expected_short is not None
        if len(baseline_raw) != FRAME_SIZE or expected_short not in baseline_err:
            raise SystemExit(
                f"[FAIL] CROSS_PLANE_FIRST_PAYLOAD cb=0x{cb_mask:x} cr=0x{cr_mask:x} baseline drift: "
                f"decoded={len(baseline_raw)}/{EXPECTED_BYTES} err={baseline_err.strip()!r}"
            )
        assert_idr_reference(fixture, baseline_raw, "baseline-short")
        baseline = f"short/{expected_short}"

    for label, value in (("queue_m8_payload_0x75", QUEUE_M8_FIRST_PAYLOAD), ("bit7_payload_0x6b", BIT7_PROMOTED_PAYLOAD)):
        raw, err = decode_raw(mutate_first_payload(stream, first_idx, value))
        if err.strip():
            raise SystemExit(
                f"[FAIL] CROSS_PLANE_FIRST_PAYLOAD {label} cb=0x{cb_mask:x} cr=0x{cr_mask:x} FFmpeg log {err.strip()!r}"
            )
        u_sad, v_sad = assert_planes(cb_mask, cr_mask, fixture, raw, label)
        print(
            f"[PASS] CROSS_PLANE_FIRST_PAYLOAD cb=0x{cb_mask:x} cr=0x{cr_mask:x} baseline={baseline}; "
            f"{label} strict {len(raw)}/{EXPECTED_BYTES} U_SAD={u_sad} V_SAD={v_sad}"
        )


def main() -> None:
    sim = build_baseline_sim()
    for (cb_mask, cr_mask), signature in CASES.items():
        check_case(sim, cb_mask, cr_mask, signature)
    for cb_mask, cr_mask in BASELINE_STRICT:
        check_case(sim, cb_mask, cr_mask, None)
    for (cb_mask, cr_mask), bad_planes in BASELINE_BAD_PLANES.items():
        check_case(sim, cb_mask, cr_mask, None, bad_planes)
    print(
        "[PASS] CABAC P16x16 cross-plane chroma-AC first-payload probe: representative sparse, "
        "bottom/top mirror, split-row, and dense/sparse Cb+Cr masks preserve their locked baseline "
        "outcomes, while exact 0xeb->0x75 and bit7 0xeb->0x6b first-payload substitutions promote "
        "the sparse miss cases and the strict-but-wrong-plane quality guard to strict two-frame decode "
        "with expected plane-local SAD while preserving the strict dense controls."
    )


if __name__ == "__main__":
    main()
