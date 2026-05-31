#!/usr/bin/env python3
"""Staged scoped CABAC queue-init probe for chroma AC.

The global `cod_i_queue` -9 -> -8 staged candidate promotes sparse chroma-AC
masks but regresses the dense Cb+Cr guard.  This probe checks the tempting
smaller source repair: add a bitstream-owned `init_queue` port and choose -8
only when the current chroma-AC scan inputs are sparse/non-dense.  Because the
CABAC core is started at slice setup, before the P-macroblock residual scan is
visible in this path, that scoped condition must currently behave like the
baseline.  Locking that negative result keeps future repair work focused below
slice-start queue selection and on the CABAC output/renormalization path.
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
    path = data_dir / f"smoke_16x16_2f_cabac_p16x16_chroma_ac_scoped_queue_{name}.yuv"
    path.write_bytes(y0 + flat + flat + y1 + checker_chroma(cb_mask) + checker_chroma(cr_mask))
    print(
        f"[INFO] CHRAC_SCOPED_QUEUE {name} fixture {path.relative_to(ROOT)} "
        f"cb=0x{cb_mask:x} cr=0x{cr_mask:x} size={path.stat().st_size}"
    )
    return path


def patch_scoped_queue(workspace: Path) -> None:
    core = workspace / "rtl" / "h264_cabac_core.v"
    bitstream = workspace / "rtl" / "h264_bitstream.v"

    core_text = core.read_text(encoding="utf-8")
    core_text = core_text.replace(
        "    input  wire         start,\n\n    input  wire         bin_valid,",
        "    input  wire         start,\n    input  wire signed [7:0] init_queue,\n\n    input  wire         bin_valid,",
    )
    core_text = core_text.replace(
        "                cod_i_queue       <= -8'sd9;\n                outstanding_count <= 8'd0;",
        "                cod_i_queue       <= init_queue;\n                outstanding_count <= 8'd0;",
        1,
    )
    if "input  wire signed [7:0] init_queue" not in core_text or "cod_i_queue       <= init_queue;" not in core_text:
        raise SystemExit("[FAIL] CHRAC_SCOPED_QUEUE failed to stage CABAC core init_queue patch")
    core.write_text(core_text, encoding="utf-8")

    bs_text = bitstream.read_text(encoding="utf-8")
    bs_text = bs_text.replace(
        "    reg        cabac_bin_terminate;\n    reg [6:0]  cabac_ctx_state_in;",
        "    reg        cabac_bin_terminate;\n    wire signed [7:0] cabac_core_init_queue;\n    reg [6:0]  cabac_ctx_state_in;",
    )
    bs_text = bs_text.replace(
        "        .start(cabac_start),\n        .bin_valid(cabac_bin_valid),",
        "        .start(cabac_start),\n        .init_queue(cabac_core_init_queue),\n        .bin_valid(cabac_bin_valid),",
    )
    assign_text = """    assign cabac_core_init_queue =
        (cabac_feature_enable && cabac_slice_enable &&
         cabac_chroma_ac_cb_plane_any_nz() && cabac_chroma_ac_cr_plane_any_nz() &&
         cabac_chroma_ac_cb_plane_full_nz() && cabac_chroma_ac_cr_plane_full_nz()) ? -8'sd9 :
        (cabac_feature_enable && cabac_slice_enable &&
         (cabac_chroma_ac_cb_plane_any_nz() || cabac_chroma_ac_cr_plane_any_nz())) ? -8'sd8 :
        -8'sd9;

"""
    bs_text = bs_text.replace(
        "    function automatic [1:0] cabac_res_chroma_ac_cbf_ctx_sel_for;",
        assign_text + "    function automatic [1:0] cabac_res_chroma_ac_cbf_ctx_sel_for;",
    )
    for needle in (
        "wire signed [7:0] cabac_core_init_queue",
        ".init_queue(cabac_core_init_queue)",
        "assign cabac_core_init_queue =",
    ):
        if needle not in bs_text:
            raise SystemExit(f"[FAIL] CHRAC_SCOPED_QUEUE failed to stage bitstream patch needle {needle}")
    bitstream.write_text(bs_text, encoding="utf-8")


def build_scoped_sim() -> Path:
    workspace = Path(stage_workspace("h264_cabac_chrac_scoped_queue_"))
    patch_scoped_queue(workspace)
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
    print(f"[INFO] CHRAC_SCOPED_QUEUE workspace={workspace} sim={sim}")
    return sim


def decode_raw(h264: Path) -> tuple[bytes, str]:
    with tempfile.NamedTemporaryFile(prefix="h264_chrac_scoped_queue_", suffix=".yuv", delete=False) as raw_tmp:
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


def run_case(sim: Path, name: str, fixture: Path) -> tuple[bytes, str, bytes, str]:
    out_dir = ROOT / "output" / "cabac_chroma_ac_scoped_queue_probe"
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
    if "cabac_p16x16_mbs=1" not in sim_text or "cabac_chroma_ac_mbs=1" not in sim_text:
        raise SystemExit(f"[FAIL] CHRAC_SCOPED_QUEUE {name} did not exercise integrated chroma AC")
    raw, err = decode_raw(h264)
    return raw, err, h264.read_bytes(), sim_text


def assert_cb_sad(name: str, fixture: Path, raw: bytes, expected_u: int) -> None:
    if len(raw) != EXPECTED_BYTES:
        raise SystemExit(f"[FAIL] CHRAC_SCOPED_QUEUE {name} decoded {len(raw)}/{EXPECTED_BYTES} bytes")
    src = fixture.read_bytes()
    if raw[:FRAME_SIZE] != src[:FRAME_SIZE]:
        raise SystemExit(f"[FAIL] CHRAC_SCOPED_QUEUE {name} changed the IDR reference")
    u0 = FRAME_SIZE + LUMA_SIZE
    v0 = u0 + CHROMA_SIZE
    u_sad = sum(abs(raw[u0 + i] - src[u0 + i]) for i in range(CHROMA_SIZE))
    v_sad = sum(abs(raw[v0 + i] - src[v0 + i]) for i in range(CHROMA_SIZE))
    if u_sad != expected_u or v_sad != 0:
        raise SystemExit(f"[FAIL] CHRAC_SCOPED_QUEUE {name} U_SAD={u_sad} V_SAD={v_sad}, expected {expected_u}/0")


def assert_both_sad(name: str, fixture: Path, raw: bytes) -> None:
    if len(raw) != EXPECTED_BYTES:
        raise SystemExit(f"[FAIL] CHRAC_SCOPED_QUEUE {name} decoded {len(raw)}/{EXPECTED_BYTES} bytes")
    src = fixture.read_bytes()
    u0 = FRAME_SIZE + LUMA_SIZE
    v0 = u0 + CHROMA_SIZE
    u_sad = sum(abs(raw[u0 + i] - src[u0 + i]) for i in range(CHROMA_SIZE))
    v_sad = sum(abs(raw[v0 + i] - src[v0 + i]) for i in range(CHROMA_SIZE))
    if u_sad != 256 or v_sad != 256:
        raise SystemExit(f"[FAIL] CHRAC_SCOPED_QUEUE {name} U_SAD={u_sad} V_SAD={v_sad}, expected 256/256")


def final_slice(stream: bytes, name: str) -> bytes:
    start = stream.rfind(b"\x00\x00\x00\x01")
    if start < 0:
        raise SystemExit(f"[FAIL] CHRAC_SCOPED_QUEUE {name} missing final Annex-B start code")
    return stream[start:]


def main() -> None:
    sim = build_scoped_sim()
    cases = {
        "cb_mask1": (make_fixture("cb_mask1", 0x1, 0x0), "short", "bytestream -19", 64),
        "cb_mask2": (make_fixture("cb_mask2", 0x2, 0x0), "short", "bytestream -21", 64),
        "cb_mask3": (make_fixture("cb_mask3", 0x3, 0x0), "strict_cb", "", 128),
        "dense_both": (make_fixture("dense_both", 0xF, 0xF), "strict_both", "", 0),
    }
    expected_tails = {
        "cb_mask1": "0000000141d008086beb2ed226",
        "cb_mask2": "0000000141d008086beb2f6b5d",
        "cb_mask3": "0000000141d008086beb3184d4899e58",
        "dense_both": "0000000141d008086beb",
    }
    for name, (fixture, mode, signature, expected_u) in cases.items():
        raw, err, stream, sim_text = run_case(sim, name, fixture)
        tail = final_slice(stream, name).hex()
        if not tail.endswith(expected_tails[name]):
            raise SystemExit(
                f"[FAIL] CHRAC_SCOPED_QUEUE {name} final-slice tail drifted: got {tail}, "
                f"expected suffix {expected_tails[name]}"
            )
        if mode == "short":
            if len(raw) != FRAME_SIZE or signature not in err:
                raise SystemExit(
                    f"[FAIL] CHRAC_SCOPED_QUEUE {name} expected baseline one-frame miss {signature}, "
                    f"decoded={len(raw)}/{EXPECTED_BYTES} err={err.strip()!r}"
                )
            print(f"[PASS] CHRAC_SCOPED_QUEUE {name} remains baseline short {len(raw)}/{EXPECTED_BYTES} {signature} tail={tail}")
        elif mode == "strict_cb":
            if err.strip():
                raise SystemExit(f"[FAIL] CHRAC_SCOPED_QUEUE {name} expected clean FFmpeg log, got {err.strip()!r}")
            assert_cb_sad(name, fixture, raw, int(expected_u))
            print(f"[PASS] CHRAC_SCOPED_QUEUE {name} remains baseline strict {len(raw)}/{EXPECTED_BYTES} tail={tail}")
        elif mode == "strict_both":
            if err.strip():
                raise SystemExit(f"[FAIL] CHRAC_SCOPED_QUEUE {name} expected clean FFmpeg log, got {err.strip()!r}")
            if "cb_ac_blocks=4" not in sim_text or "cr_ac_blocks=4" not in sim_text:
                raise SystemExit(f"[FAIL] CHRAC_SCOPED_QUEUE {name} did not preserve dense Cb+Cr counters")
            assert_both_sad(name, fixture, raw)
            print(f"[PASS] CHRAC_SCOPED_QUEUE {name} remains baseline strict {len(raw)}/{EXPECTED_BYTES} tail={tail}")
        else:
            raise SystemExit(f"internal mode error {mode}")
    print(
        "[PASS] CABAC P16x16 chroma-AC scoped queue-init probe: a staged bitstream-selected "
        "init_queue based on current chroma-AC scan contents behaves like baseline at slice start; "
        "sparse Cb masks 0x1/0x2 remain one-frame misses while current strict controls stay green, "
        "so the queue-alignment repair cannot be landed as a simple slice-start conditional on MB residual inputs."
    )


if __name__ == "__main__":
    main()
