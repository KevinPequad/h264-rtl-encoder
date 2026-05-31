#!/usr/bin/env python3
"""Staged CABAC core queue-alignment probe for sparse Cb-only chroma AC.

The current integrated CABAC P16x16 source still has a sparse-Cb AC mask
partition where several masks short-decode.  This probe keeps the canonical
checkout untouched, stages an isolated workspace that changes only the CABAC
core initial output queue from -9 to -8, and verifies that the candidate
promotes every 16x16 Cb-only AC mask.  It also locks the important negative
finding that applying that queue shift globally is not yet committable: the
same candidate regresses a both-plane Cb+Cr AC control.
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
QUEUE_ANCHOR = "cod_i_queue       <= -8'sd9;"
QUEUE_CANDIDATE = "cod_i_queue       <= -8'sd8;"


def checker_chroma(mask: int = 0xF) -> bytes:
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
    out_dir = ROOT / "data"
    out_dir.mkdir(parents=True, exist_ok=True)
    fixtures: dict[int, Path] = {}
    for mask in range(1, 16):
        path = out_dir / f"smoke_16x16_2f_cabac_p16x16_chroma_residual_cb_ac_queue_align_mask_{mask:x}.yuv"
        path.write_bytes(y0 + flat + flat + y1 + checker_chroma(mask) + flat)
        fixtures[mask] = path
        print(f"[INFO] CB_AC_QUEUE_ALIGN mask=0x{mask:x} fixture {path} size={path.stat().st_size}")
    both = out_dir / "smoke_16x16_2f_cabac_p16x16_chroma_residual_cbcr_ac_queue_align_guard.yuv"
    both.write_bytes(y0 + flat + flat + y1 + checker_chroma(0xF) + checker_chroma(0xF))
    print(f"[INFO] CB_AC_QUEUE_ALIGN both-plane guard fixture {both} size={both.stat().st_size}")
    return fixtures, both


def patch_queue_alignment(workspace: Path) -> None:
    core = workspace / "rtl" / "h264_cabac_core.v"
    text = core.read_text(encoding="utf-8")
    count = text.count(QUEUE_ANCHOR)
    if count != 2:
        raise SystemExit(f"[FAIL] expected exactly two CABAC queue init anchors, found {count}")
    core.write_text(text.replace(QUEUE_ANCHOR, QUEUE_CANDIDATE), encoding="utf-8")


def decode_raw(h264_path: Path) -> tuple[bytes, str]:
    with tempfile.NamedTemporaryFile(prefix="h264_cb_ac_queue_align_", suffix=".yuv", delete=False) as raw_tmp:
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
        raw_path.unlink(missing_ok=True)


def build_candidate(name: str, patch_queue: bool) -> Path:
    workspace = Path(stage_workspace(f"h264_cabac_cb_ac_queue_align_{name}_"))
    if patch_queue:
        patch_queue_alignment(workspace)
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
    print(f"[INFO] CB_AC_QUEUE_ALIGN {name} workspace={workspace} sim={sim}")
    return sim


def run_case(sim: Path, name: str, case_name: str, fixture: Path) -> tuple[bytes, str, Path, str]:
    out_dir = ROOT / "output" / "cabac_cb_ac_queue_align_probe" / name
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
    raw, err = decode_raw(h264)
    return raw, err, h264, sim_text


def run_mask_case(sim: Path, name: str, mask: int, fixture: Path) -> tuple[bytes, str, Path, str]:
    raw, err, h264, sim_text = run_case(sim, name, f"mask_{mask:x}", fixture)
    expected_blocks = mask.bit_count()
    for needle in (
        "cabac_p16x16_mbs=1",
        "cb_ac_mbs=1",
        "cr_ac_mbs=0",
        f"cb_ac_blocks={expected_blocks}",
        "cr_ac_blocks=0",
    ):
        if needle not in sim_text:
            raise SystemExit(f"[FAIL] CB_AC_QUEUE_ALIGN {name} mask=0x{mask:x} sim log missing {needle}")
    return raw, err, h264, sim_text


def assert_cb_only(mask: int, fixture: Path, raw: bytes, label: str) -> tuple[int, int]:
    if len(raw) != EXPECTED_BYTES:
        raise SystemExit(f"[FAIL] CB_AC_QUEUE_ALIGN {label} mask=0x{mask:x} decoded {len(raw)}/{EXPECTED_BYTES} bytes")
    src = fixture.read_bytes()
    if raw[:FRAME_SIZE] != src[:FRAME_SIZE]:
        raise SystemExit(f"[FAIL] CB_AC_QUEUE_ALIGN {label} mask=0x{mask:x} changed the IDR reference frame")
    u0 = FRAME_SIZE + LUMA_SIZE
    v0 = u0 + CHROMA_SIZE
    u_sad = sum(abs(raw[u0 + i] - src[u0 + i]) for i in range(CHROMA_SIZE))
    v_sad = sum(abs(raw[v0 + i] - src[v0 + i]) for i in range(CHROMA_SIZE))
    expected_u = mask.bit_count() * 64
    if u_sad != expected_u or v_sad != 0:
        raise SystemExit(
            f"[FAIL] CB_AC_QUEUE_ALIGN {label} mask=0x{mask:x} decoded-plane SAD "
            f"U={u_sad} V={v_sad}, expected U={expected_u} V=0"
        )
    return u_sad, v_sad


def check_baseline(sim: Path, fixtures: dict[int, Path]) -> None:
    for mask, fixture in fixtures.items():
        raw, err, h264, _ = run_mask_case(sim, "baseline", mask, fixture)
        if mask in BASELINE_FULL:
            u_sad, v_sad = assert_cb_only(mask, fixture, raw, "baseline")
            if err.strip():
                raise SystemExit(f"[FAIL] CB_AC_QUEUE_ALIGN baseline mask=0x{mask:x} expected clean FFmpeg log, got {err.strip()!r}")
            print(
                f"[PASS] CB_AC_QUEUE_ALIGN baseline mask=0x{mask:x} remains strict "
                f"{len(raw)}/{EXPECTED_BYTES} size={h264.stat().st_size} U_SAD={u_sad} V_SAD={v_sad}"
            )
        else:
            signature = BASELINE_SHORT[mask]
            if len(raw) != FRAME_SIZE or signature not in err:
                raise SystemExit(
                    f"[FAIL] CB_AC_QUEUE_ALIGN baseline mask=0x{mask:x} drifted from locked short miss: "
                    f"decoded={len(raw)}/{EXPECTED_BYTES} expected_signature={signature!r} err={err.strip()!r}"
                )
            print(
                f"[PASS] CB_AC_QUEUE_ALIGN baseline mask=0x{mask:x} remains short "
                f"{len(raw)}/{EXPECTED_BYTES} with {signature}"
            )


def check_queue_m8(sim: Path, fixtures: dict[int, Path], both_plane_fixture: Path) -> None:
    first_payload_bytes: set[int] = set()
    for mask, fixture in fixtures.items():
        raw, err, h264, _ = run_mask_case(sim, "queue_m8", mask, fixture)
        if err.strip():
            raise SystemExit(f"[FAIL] CB_AC_QUEUE_ALIGN queue_m8 mask=0x{mask:x} expected clean FFmpeg log, got {err.strip()!r}")
        u_sad, v_sad = assert_cb_only(mask, fixture, raw, "queue_m8")
        stream = h264.read_bytes()
        last_start = stream.rfind(b"\x00\x00\x00\x01")
        if last_start < 0 or last_start + 9 >= len(stream):
            raise SystemExit(f"[FAIL] CB_AC_QUEUE_ALIGN queue_m8 mask=0x{mask:x} missing final slice payload")
        if stream[last_start + 8] != 0x6B:
            raise SystemExit(
                f"[FAIL] CB_AC_QUEUE_ALIGN queue_m8 mask=0x{mask:x} header-tail byte "
                f"0x{stream[last_start + 8]:02x}, expected 0x6b"
            )
        first_payload_bytes.add(stream[last_start + 9])
        print(
            f"[PASS] CB_AC_QUEUE_ALIGN queue_m8 mask=0x{mask:x} strict-decodes "
            f"{len(raw)}/{EXPECTED_BYTES} size={h264.stat().st_size} first_payload=0x{stream[last_start + 9]:02x} "
            f"U_SAD={u_sad} V_SAD={v_sad}"
        )
    if first_payload_bytes != {0x75}:
        raise SystemExit(
            f"[FAIL] CB_AC_QUEUE_ALIGN queue_m8 first payload bytes {sorted(first_payload_bytes)}, expected [0x75]"
        )

    raw, err, _h264, sim_text = run_case(sim, "queue_m8", "both_planes_guard", both_plane_fixture)
    for needle in (
        "cabac_p16x16_mbs=1",
        "cb_ac_mbs=1",
        "cr_ac_mbs=1",
        "cb_ac_blocks=4",
        "cr_ac_blocks=4",
    ):
        if needle not in sim_text:
            raise SystemExit(f"[FAIL] CB_AC_QUEUE_ALIGN queue_m8 both-plane guard sim log missing {needle}")
    if len(raw) != FRAME_SIZE or "bytestream -9" not in err:
        raise SystemExit(
            "[FAIL] CB_AC_QUEUE_ALIGN queue_m8 both-plane guard no longer locks the global -8 regression: "
            f"decoded={len(raw)}/{EXPECTED_BYTES} err={err.strip()!r}"
        )
    print(
        "[PASS] CB_AC_QUEUE_ALIGN queue_m8 both-plane guard confirms global -8 remains non-committable: "
        f"decoded={len(raw)}/{EXPECTED_BYTES} with bytestream -9"
    )


def main() -> None:
    fixtures, both_plane_fixture = make_fixtures()
    baseline = build_candidate("baseline", patch_queue=False)
    check_baseline(baseline, fixtures)
    queue_m8 = build_candidate("queue_m8", patch_queue=True)
    check_queue_m8(queue_m8, fixtures, both_plane_fixture)
    print(
        "[PASS] CABAC P16x16 Cb-only chroma-AC queue-alignment staged probe: "
        "baseline sparse-Cb partition is unchanged; globally changing h264_cabac_core "
        "cod_i_queue initialization from -9 to -8 promotes all 15 Cb-only AC masks to strict "
        "two-frame FFmpeg decode, but is explicitly blocked from source promotion by the both-plane "
        "Cb+Cr AC regression guard"
    )


if __name__ == "__main__":
    main()
