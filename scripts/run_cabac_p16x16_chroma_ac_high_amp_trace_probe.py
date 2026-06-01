#!/usr/bin/env python3
"""Debug-trace lock for the remaining high-amplitude Cb0x2/Cr0xd AC miss.

The high-amplitude miss probe already locks the bytestream-side one-frame miss
and byte-mutation classes.  This companion probe builds the RTL with
DEBUG_CABAC_P16X16 and compares the failing Cb-singleton/Cr-all-but-one lane
against its reciprocal strict-pass lane.  It keeps the repair target pointed at
CABAC arithmetic/context state: both cases emit the expected RTL-owned stream,
but the first chroma-AC payload is reached after different plane-local CBF walks
and arithmetic states.
"""

from __future__ import annotations

import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from scripts.rtl_runner import BuildConfig, build_sim, stage_workspace  # noqa: E402
from scripts.run_cabac_p16x16_chroma_ac_cross_plane_first_payload_probe import (  # noqa: E402
    EXPECTED_BYTES,
    FRAME_SIZE,
    assert_planes,
    decode_raw,
    final_slice_hex,
    make_fixture,
)

OUT_DIR = ROOT / "output" / "cabac_high_amp_trace_probe"

CASES: dict[str, dict[str, Any]] = {
    "fail_cb2_crd_160_160": {
        "cb_mask": 0x2,
        "cr_mask": 0xD,
        "cb_value": 160,
        "cr_value": 160,
        "tail": "0000000141d008086bbbecf7",
        "decoded_bytes": FRAME_SIZE,
        "ffmpeg_signature": "bytestream -16",
        "expected_quality": False,
        "cbf_order": [(0, 0), (1, 1), (2, 0), (3, 0), (4, 1), (5, 0), (6, 1), (7, 1)],
        "coded_blocks": [1, 4, 6, 7],
        "payload_bytes": [0xBB, 0xEC, 0xF7],
        "first_payload_ctx": {
            "blk": 1,
            "kind": 22,
            "sel": 0,
            "state_in": 122,
            "state_out": 120,
            "ari_low": "36c",
            "ari_range": 414,
            "ari_queue": -8,
            "ari_pending": 1,
            "ari_pbyte": "43",
        },
    },
    "pass_cbd_cr2_160_160": {
        "cb_mask": 0xD,
        "cr_mask": 0x2,
        "cb_value": 160,
        "cr_value": 160,
        "tail": "0000000141d008086b3addf5",
        "decoded_bytes": EXPECTED_BYTES,
        "ffmpeg_signature": "",
        "expected_quality": True,
        "cbf_order": [(0, 1), (1, 0), (2, 1), (3, 1), (4, 0), (5, 1), (6, 0), (7, 0)],
        "coded_blocks": [0, 2, 3, 5],
        "payload_bytes": [0x3A, 0xDD, 0xF5],
        "first_payload_ctx": {
            "blk": 0,
            "kind": 22,
            "sel": 0,
            "state_in": 122,
            "state_out": 120,
            "ari_low": "228",
            "ari_range": 294,
            "ari_queue": -8,
            "ari_pending": 1,
            "ari_pbyte": "4",
        },
    },
}


def build_debug_sim() -> Path:
    workspace = Path(stage_workspace("h264_cabac_high_amp_trace_"))
    config = BuildConfig(
        width=16,
        height=16,
        bit_depth=8,
        chroma_format_idc=1,
        jobs=int(os.environ.get("BUILD_JOBS", "1")),
        enable_idr_ipcm=1,
        ipcm_sad_threshold=0,
        enable_cabac_p16x16=1,
        debug_cabac_p16x16=1,
    )
    sim = Path(build_sim(workspace, config))
    print(f"[INFO] HIGH_AMP_TRACE workspace={workspace} sim={sim}")
    return sim


def run_rtl_case(sim: Path, name: str, spec: dict[str, object]) -> tuple[Path, Path, Path]:
    fixture = make_fixture(
        int(spec["cb_mask"]),
        int(spec["cr_mask"]),
        int(spec["cb_value"]),
        int(spec["cr_value"]),
    )
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    h264 = OUT_DIR / f"{name}.h264"
    sim_log = OUT_DIR / f"{name}.sim.log"
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
            stdout=log,
            stderr=subprocess.STDOUT,
            check=True,
        )
    return fixture, h264, sim_log


def parse_cbf_order(text: str) -> list[tuple[int, int]]:
    order: list[tuple[int, int]] = []
    for line in text.splitlines():
        if "[CABACRES]" not in line or "cat=2" not in line:
            continue
        m = re.search(r"blk=(\d+) ctx=(\d+) val=(\d+) bypass=(\d+) coeff=(\d+)", line)
        if not m:
            continue
        blk, ctx, val, bypass, coeff = map(int, m.groups())
        if 101 <= ctx <= 104 and bypass == 0 and coeff == 0:
            order.append((blk, val))
    return order


def parse_payload_bytes(text: str) -> list[int]:
    bytes_out: list[int] = []
    for line in text.splitlines():
        if "[CABACEMIT] mb=1 return_state=0 return_sub=46" not in line:
            continue
        m = re.search(r"byte=([0-9a-fA-F]{2})", line)
        if m:
            bytes_out.append(int(m.group(1), 16))
    return bytes_out


def parse_first_payload_ctx(text: str, expected_blk: int) -> dict[str, object]:
    for line in text.splitlines():
        if "[CABACCTX]" not in line or "cat=2" not in line:
            continue
        m = re.search(
            r"blk=(\d+) kind=(\d+) sel=(\d+) in=(\d+) out=(\d+) "
            r"ari_low=([0-9a-fA-F]+) ari_range=(\d+) ari_queue=(-?\d+) "
            r"ari_outstanding=(\d+) ari_pending=(\d+) ari_pbyte=([0-9a-fA-F]+)",
            line,
        )
        if not m:
            continue
        blk, kind, sel, state_in, state_out = map(int, m.groups()[:5])
        if blk == expected_blk and kind == 22:
            return {
                "blk": blk,
                "kind": kind,
                "sel": sel,
                "state_in": state_in,
                "state_out": state_out,
                "ari_low": m.group(6).lower(),
                "ari_range": int(m.group(7)),
                "ari_queue": int(m.group(8)),
                "ari_pending": int(m.group(10)),
                "ari_pbyte": m.group(11).lower(),
            }
    raise SystemExit(f"[FAIL] HIGH_AMP_TRACE missing first payload ctx for block {expected_blk}")


def check_case(sim: Path, name: str, spec: dict[str, object]) -> None:
    fixture, h264, sim_log = run_rtl_case(sim, name, spec)
    stream = h264.read_bytes()
    tail = final_slice_hex(stream, name)
    if tail != spec["tail"]:
        raise SystemExit(f"[FAIL] HIGH_AMP_TRACE {name} tail {tail}, expected {spec['tail']}")

    raw, err = decode_raw(h264)
    err_text = err.strip()
    if len(raw) != spec["decoded_bytes"]:
        raise SystemExit(
            f"[FAIL] HIGH_AMP_TRACE {name} decoded {len(raw)} bytes, expected {spec['decoded_bytes']}: {err_text!r}"
        )
    if spec["ffmpeg_signature"]:
        if str(spec["ffmpeg_signature"]) not in err_text:
            raise SystemExit(
                f"[FAIL] HIGH_AMP_TRACE {name} FFmpeg signature {err_text!r}, "
                f"expected {spec['ffmpeg_signature']!r}"
            )
        if raw != fixture.read_bytes()[:FRAME_SIZE]:
            raise SystemExit(f"[FAIL] HIGH_AMP_TRACE {name} changed the IDR/reference frame")
    else:
        if err_text:
            raise SystemExit(f"[FAIL] HIGH_AMP_TRACE {name} expected strict FFmpeg pass, got {err_text!r}")
        assert_planes(
            int(spec["cb_mask"]),
            int(spec["cr_mask"]),
            fixture,
            raw,
            int(spec["cb_value"]),
            int(spec["cr_value"]),
        )

    text = sim_log.read_text(encoding="utf-8", errors="replace")
    cbf_order = parse_cbf_order(text)
    if cbf_order != spec["cbf_order"]:
        raise SystemExit(f"[FAIL] HIGH_AMP_TRACE {name} CBF order {cbf_order}, expected {spec['cbf_order']}")
    coded_blocks = [blk for blk, val in cbf_order if val]
    if coded_blocks != spec["coded_blocks"]:
        raise SystemExit(
            f"[FAIL] HIGH_AMP_TRACE {name} coded blocks {coded_blocks}, expected {spec['coded_blocks']}"
        )

    payload_bytes = parse_payload_bytes(text)
    if payload_bytes[: len(spec["payload_bytes"])] != spec["payload_bytes"]:
        raise SystemExit(
            f"[FAIL] HIGH_AMP_TRACE {name} payload bytes {payload_bytes}, expected prefix {spec['payload_bytes']}"
        )

    first_ctx = parse_first_payload_ctx(text, coded_blocks[0])
    if first_ctx != spec["first_payload_ctx"]:
        raise SystemExit(
            f"[FAIL] HIGH_AMP_TRACE {name} first payload ctx {first_ctx}, expected {spec['first_payload_ctx']}"
        )

    status = "strict expected-SAD pass" if spec["expected_quality"] else f"bounded one-frame miss {spec['ffmpeg_signature']}"
    print(
        f"[PASS] HIGH_AMP_TRACE {name}: {status}, tail={tail}, "
        f"CBF={cbf_order}, payload={[f'0x{b:02x}' for b in payload_bytes[:3]]}, "
        f"first_ctx={first_ctx}"
    )


def main() -> int:
    sim = build_debug_sim()
    for name, spec in CASES.items():
        check_case(sim, name, spec)
    print(
        "[PASS] CABAC P16x16 high-amplitude chroma-AC trace probe locks the failing "
        "Cb0x2/Cr0xd lane against reciprocal Cb0xd/Cr0x2 strict pass, including "
        "plane-local CBF walks, first payload bytes, and first payload arithmetic context state."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
