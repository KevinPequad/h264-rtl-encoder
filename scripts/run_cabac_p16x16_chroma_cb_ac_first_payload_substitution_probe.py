#!/usr/bin/env python3
"""Exact first-CABAC-payload byte substitution probe for Cb-only chroma AC.

This is a bytestream-side diagnostic for the sparse Cb-only CABAC P16x16
chroma-AC blocker.  Earlier probes showed that a staged CABAC core queue init
shift changes the first residual payload byte from 0xeb to 0x75 and promotes all
Cb-only masks, but also regresses a dense Cb+Cr guard.  This probe keeps the RTL
checkout unchanged, generates the canonical streams, and mutates only the first
CABAC payload byte after the locked P-slice header tail.  It proves the exact
0x75 payload substitution has the same all-Cb-mask promotion signature without
regressing the dense both-plane guard, so the staged queue-shift guard failure
must come from later arithmetic/output state instead of the first byte alone.
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
BASELINE_FULL = {0x3, 0x4, 0x7, 0x8, 0xB, 0xD, 0xE, 0xF}
BASELINE_SHORT = {
    0x1: "bytestream -19",
    0x2: "bytestream -21",
    0x5: "bytestream -22",
    0x6: "bytestream -18",
    0x9: "bytestream -14",
    0xA: "bytestream -20",
    0xC: "bytestream -18",
}


def checker_chroma(mask: int) -> bytes:
    out = []
    for y in range(HEIGHT // 2):
        for x in range(WIDTH // 2):
            block = (1 if x >= 4 else 0) + (2 if y >= 4 else 0)
            out.append(136 if ((mask >> block) & 1 and ((x + y) % 2)) else 128)
    return bytes(out)


def make_fixtures() -> tuple[dict[int, Path], Path]:
    y0 = bytes([64]) * LUMA_SIZE
    y1 = bytes([64]) * LUMA_SIZE
    flat = bytes([128]) * CHROMA_SIZE
    data_dir = ROOT / "data"
    data_dir.mkdir(parents=True, exist_ok=True)
    fixtures: dict[int, Path] = {}
    for mask in range(1, 16):
        path = data_dir / f"smoke_16x16_2f_cabac_p16x16_chroma_residual_cb_ac_first_payload_sub_mask_{mask:x}.yuv"
        path.write_bytes(y0 + flat + flat + y1 + checker_chroma(mask) + flat)
        fixtures[mask] = path
        print(f"[INFO] CB_AC_FIRST_PAYLOAD_SUB mask=0x{mask:x} fixture {path} size={path.stat().st_size}")
    both = data_dir / "smoke_16x16_2f_cabac_p16x16_chroma_residual_cbcr_ac_first_payload_sub_guard.yuv"
    both.write_bytes(y0 + flat + flat + y1 + checker_chroma(0xF) + checker_chroma(0xF))
    print(f"[INFO] CB_AC_FIRST_PAYLOAD_SUB both-plane guard fixture {both} size={both.stat().st_size}")
    return fixtures, both


def decode_raw(data: bytes) -> tuple[bytes, str]:
    with tempfile.NamedTemporaryFile(prefix="h264_cb_ac_first_payload_sub_", suffix=".h264", delete=False) as h264_tmp:
        h264_tmp.write(data)
        h264_path = Path(h264_tmp.name)
    with tempfile.NamedTemporaryFile(prefix="h264_cb_ac_first_payload_sub_", suffix=".yuv", delete=False) as raw_tmp:
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
    workspace = Path(stage_workspace("h264_cabac_cb_ac_first_payload_sub_"))
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
    print(f"[INFO] CB_AC_FIRST_PAYLOAD_SUB workspace={workspace} sim={sim}")
    return sim


def run_case(sim: Path, case_name: str, fixture: Path) -> tuple[bytes, str]:
    out_dir = ROOT / "output" / "cabac_cb_ac_first_payload_sub_probe"
    out_dir.mkdir(parents=True, exist_ok=True)
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
    for needle in ("cabac_p16x16_mbs=1", "cb_ac_mbs=1"):
        if needle not in sim_text:
            raise SystemExit(f"[FAIL] CB_AC_FIRST_PAYLOAD_SUB {case_name} sim log missing {needle}")
    return h264.read_bytes(), sim_text


def first_payload_index(stream: bytes, case_name: str) -> int:
    last_start = stream.rfind(b"\x00\x00\x00\x01")
    if last_start < 0:
        raise SystemExit(f"[FAIL] CB_AC_FIRST_PAYLOAD_SUB {case_name} missing final Annex-B start code")
    header_tail_idx = last_start + 8
    first_idx = last_start + 9
    if first_idx >= len(stream):
        raise SystemExit(f"[FAIL] CB_AC_FIRST_PAYLOAD_SUB {case_name} missing first CABAC payload byte")
    if stream[header_tail_idx] != EXPECTED_HEADER_TAIL:
        raise SystemExit(
            f"[FAIL] CB_AC_FIRST_PAYLOAD_SUB {case_name} header tail 0x{stream[header_tail_idx]:02x}, "
            f"expected 0x{EXPECTED_HEADER_TAIL:02x}"
        )
    if stream[first_idx] != EXPECTED_FIRST_PAYLOAD:
        raise SystemExit(
            f"[FAIL] CB_AC_FIRST_PAYLOAD_SUB {case_name} first payload 0x{stream[first_idx]:02x}, "
            f"expected 0x{EXPECTED_FIRST_PAYLOAD:02x}"
        )
    return first_idx


def assert_cb_only(mask: int, fixture: Path, raw: bytes, label: str) -> tuple[int, int]:
    if len(raw) != EXPECTED_BYTES:
        raise SystemExit(f"[FAIL] CB_AC_FIRST_PAYLOAD_SUB {label} mask=0x{mask:x} decoded {len(raw)}/{EXPECTED_BYTES}")
    src = fixture.read_bytes()
    if raw[:FRAME_SIZE] != src[:FRAME_SIZE]:
        raise SystemExit(f"[FAIL] CB_AC_FIRST_PAYLOAD_SUB {label} mask=0x{mask:x} changed IDR reference")
    u0 = FRAME_SIZE + LUMA_SIZE
    v0 = u0 + CHROMA_SIZE
    u_sad = sum(abs(raw[u0 + i] - src[u0 + i]) for i in range(CHROMA_SIZE))
    v_sad = sum(abs(raw[v0 + i] - src[v0 + i]) for i in range(CHROMA_SIZE))
    expected_u = mask.bit_count() * 64
    if u_sad != expected_u or v_sad != 0:
        raise SystemExit(
            f"[FAIL] CB_AC_FIRST_PAYLOAD_SUB {label} mask=0x{mask:x} SAD U={u_sad} V={v_sad}, "
            f"expected U={expected_u} V=0"
        )
    return u_sad, v_sad


def mutate_first_payload(stream: bytes, first_idx: int, value: int) -> bytes:
    mutated = bytearray(stream)
    mutated[first_idx] = value
    return bytes(mutated)


def assert_idr_reference(mask: int, fixture: Path, raw: bytes, label: str) -> None:
    if len(raw) < FRAME_SIZE:
        raise SystemExit(
            f"[FAIL] CB_AC_FIRST_PAYLOAD_SUB {label} mask=0x{mask:x} decoded only {len(raw)} bytes, "
            f"expected at least the {FRAME_SIZE}-byte IDR frame"
        )
    src = fixture.read_bytes()
    if raw[:FRAME_SIZE] != src[:FRAME_SIZE]:
        raise SystemExit(f"[FAIL] CB_AC_FIRST_PAYLOAD_SUB {label} mask=0x{mask:x} changed IDR reference")


def check_mask(sim: Path, mask: int, fixture: Path) -> None:
    stream, sim_text = run_case(sim, f"mask_{mask:x}", fixture)
    expected_blocks = mask.bit_count()
    for needle in (f"cb_ac_blocks={expected_blocks}", "cr_ac_mbs=0", "cr_ac_blocks=0"):
        if needle not in sim_text:
            raise SystemExit(f"[FAIL] CB_AC_FIRST_PAYLOAD_SUB mask=0x{mask:x} sim log missing {needle}")
    first_idx = first_payload_index(stream, f"mask=0x{mask:x}")

    baseline_raw, baseline_err = decode_raw(stream)
    if mask in BASELINE_FULL:
        u_sad, v_sad = assert_cb_only(mask, fixture, baseline_raw, "baseline")
        if baseline_err.strip():
            raise SystemExit(f"[FAIL] CB_AC_FIRST_PAYLOAD_SUB mask=0x{mask:x} baseline FFmpeg log {baseline_err.strip()!r}")
        baseline = f"strict U_SAD={u_sad} V_SAD={v_sad}"
    else:
        signature = BASELINE_SHORT[mask]
        if len(baseline_raw) != FRAME_SIZE or signature not in baseline_err:
            raise SystemExit(
                f"[FAIL] CB_AC_FIRST_PAYLOAD_SUB mask=0x{mask:x} baseline drift: "
                f"decoded={len(baseline_raw)}/{EXPECTED_BYTES} err={baseline_err.strip()!r}"
            )
        assert_idr_reference(mask, fixture, baseline_raw, "baseline-short")
        baseline = f"short/{signature}"

    for label, value in (("queue_m8_payload_0x75", QUEUE_M8_FIRST_PAYLOAD), ("bit7_payload_0x6b", BIT7_PROMOTED_PAYLOAD)):
        raw, err = decode_raw(mutate_first_payload(stream, first_idx, value))
        if err.strip():
            raise SystemExit(f"[FAIL] CB_AC_FIRST_PAYLOAD_SUB {label} mask=0x{mask:x} FFmpeg log {err.strip()!r}")
        u_sad, v_sad = assert_cb_only(mask, fixture, raw, label)
        print(
            f"[PASS] CB_AC_FIRST_PAYLOAD_SUB mask=0x{mask:x} baseline={baseline}; "
            f"{label} promotes to {len(raw)}/{EXPECTED_BYTES} U_SAD={u_sad} V_SAD={v_sad}"
        )


def assert_both_planes(fixture: Path, raw: bytes, label: str) -> tuple[int, int]:
    if len(raw) != EXPECTED_BYTES:
        raise SystemExit(f"[FAIL] CB_AC_FIRST_PAYLOAD_SUB {label} decoded {len(raw)}/{EXPECTED_BYTES}")
    src = fixture.read_bytes()
    if raw[:FRAME_SIZE] != src[:FRAME_SIZE]:
        raise SystemExit(f"[FAIL] CB_AC_FIRST_PAYLOAD_SUB {label} changed IDR reference")
    u0 = FRAME_SIZE + LUMA_SIZE
    v0 = u0 + CHROMA_SIZE
    u_sad = sum(abs(raw[u0 + i] - src[u0 + i]) for i in range(CHROMA_SIZE))
    v_sad = sum(abs(raw[v0 + i] - src[v0 + i]) for i in range(CHROMA_SIZE))
    if u_sad != 256 or v_sad != 256:
        raise SystemExit(
            f"[FAIL] CB_AC_FIRST_PAYLOAD_SUB {label} SAD U={u_sad} V={v_sad}, expected U=256 V=256"
        )
    return u_sad, v_sad


def check_both_plane_guard(sim: Path, fixture: Path) -> None:
    stream, sim_text = run_case(sim, "both_planes_guard", fixture)
    for needle in ("cb_ac_mbs=1", "cr_ac_mbs=1", "cb_ac_blocks=4", "cr_ac_blocks=4"):
        if needle not in sim_text:
            raise SystemExit(f"[FAIL] CB_AC_FIRST_PAYLOAD_SUB both-plane guard sim log missing {needle}")
    first_idx = first_payload_index(stream, "both-plane guard")

    raw, err = decode_raw(stream)
    if err.strip():
        raise SystemExit(f"[FAIL] CB_AC_FIRST_PAYLOAD_SUB both-plane guard baseline FFmpeg log {err.strip()!r}")
    base_u, base_v = assert_both_planes(fixture, raw, "both-plane baseline")

    for label, value in (("0x75", QUEUE_M8_FIRST_PAYLOAD), ("0x6b", BIT7_PROMOTED_PAYLOAD)):
        raw_sub, err_sub = decode_raw(mutate_first_payload(stream, first_idx, value))
        if err_sub.strip():
            raise SystemExit(
                f"[FAIL] CB_AC_FIRST_PAYLOAD_SUB both-plane guard {label} FFmpeg log {err_sub.strip()!r}"
            )
        sub_u, sub_v = assert_both_planes(fixture, raw_sub, f"both-plane {label} substitution")
        print(
            f"[PASS] CB_AC_FIRST_PAYLOAD_SUB both-plane guard stays strict under {label} first-payload "
            f"substitution: baseline U_SAD={base_u} V_SAD={base_v}; sub U_SAD={sub_u} V_SAD={sub_v}"
        )


def main() -> None:
    fixtures, both_fixture = make_fixtures()
    sim = build_baseline_sim()
    for mask, fixture in fixtures.items():
        check_mask(sim, mask, fixture)
    check_both_plane_guard(sim, both_fixture)
    print(
        "[PASS] CABAC P16x16 Cb-only chroma-AC first-payload substitution probe: exact 0xeb->0x75 "
        "mutation promotes all Cb-only AC masks like the staged queue_m8 candidate; the bit7 0xeb->0x6b "
        "mutation also promotes them; and the dense Cb+Cr guard still strict-decodes under both one-byte "
        "substitutions.  This separates useful first-byte corrections from the non-committable global queue-shift side effect, so the next fix should target "
        "CABAC first-payload generation while preserving later both-plane arithmetic/output state"
    )


if __name__ == "__main__":
    main()
