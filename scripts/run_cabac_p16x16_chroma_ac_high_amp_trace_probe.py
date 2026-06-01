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
        "payload_emit_rows": [
            (1, 0, 46, "bb", 24, "bbecf7a6b905441e80098403", 0, 0),
            (1, 0, 46, "ec", 16, "ecf7a6b905441e8009840300", 0, 0),
            (1, 0, 46, "f7", 8, "f7a6b905441e800984030000", 0, 0),
        ],
        "residual_chunks": [
            (1, 0x05, 40),
            (1, 0x44, 48),
            (1, 0x1E, 56),
            (1, 0x80, 64),
            (4, 0x09, 72),
            (4, 0x84, 80),
            (4, 0x03, 88),
            (4, 0x0E, 96),
            (6, 0xD6, 104),
            (6, 0xE9, 112),
            (6, 0x0F, 120),
            (7, 0xB3, 0),
            (7, 0xA4, 8),
            (7, 0xB6, 16),
        ],
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
        "term_state": {
            "mb": 1,
            "count": 0,
            "bits": "000000000000000000000000",
            "bit_cnt": 0,
            "ari_low": "620e",
            "ari_range": 326,
            "ari_queue": -2,
            "ari_pending": 1,
            "ari_pbyte": "dc",
        },
    },
    "fail_cb2_crd_096_160": {
        "cb_mask": 0x2,
        "cr_mask": 0xD,
        "cb_value": 96,
        "cr_value": 160,
        "tail": "0000000141d008086bbbecf7",
        "decoded_bytes": FRAME_SIZE,
        "ffmpeg_signature": "bytestream -16",
        "expected_quality": False,
        "cbf_order": [(0, 0), (1, 1), (2, 0), (3, 0), (4, 1), (5, 0), (6, 1), (7, 1)],
        "coded_blocks": [1, 4, 6, 7],
        "payload_bytes": [0xBB, 0xEC, 0xF7],
        "payload_emit_rows": [
            (1, 0, 46, "bb", 24, "bbecf77c2b85441e80071563", 0, 0),
            (1, 0, 46, "ec", 16, "ecf77c2b85441e8007156300", 0, 0),
            (1, 0, 46, "f7", 8, "f77c2b85441e800715630000", 0, 0),
        ],
        "residual_chunks": [
            (1, 0x85, 40),
            (1, 0x44, 48),
            (1, 0x1E, 56),
            (1, 0x80, 64),
            (4, 0x07, 72),
            (4, 0x15, 80),
            (4, 0x63, 88),
            (4, 0x0E, 96),
            (6, 0xD6, 104),
            (6, 0xE9, 112),
            (6, 0x0F, 120),
            (7, 0xB3, 0),
            (7, 0xA4, 8),
            (7, 0xB6, 16),
        ],
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
        "term_state": {
            "mb": 1,
            "count": 0,
            "bits": "000000000000000000000000",
            "bit_cnt": 0,
            "ari_low": "620e",
            "ari_range": 326,
            "ari_queue": -2,
            "ari_pending": 1,
            "ari_pbyte": "dc",
        },
    },
    "fail_cb2_crd_160_096": {
        "cb_mask": 0x2,
        "cr_mask": 0xD,
        "cb_value": 160,
        "cr_value": 96,
        "tail": "0000000141d008086bbbccff",
        "decoded_bytes": FRAME_SIZE,
        "ffmpeg_signature": "bytestream -26",
        "expected_quality": False,
        "cbf_order": [(0, 0), (1, 1), (2, 0), (3, 0), (4, 1), (5, 0), (6, 1), (7, 1)],
        "coded_blocks": [1, 4, 6, 7],
        "payload_bytes": [0xBB, 0xCC, 0xFF],
        "payload_emit_rows": [
            (1, 0, 46, "bb", 24, "bbccffa6b927c7be80098403", 0, 0),
            (1, 0, 46, "cc", 16, "ccffa6b927c7be8009840300", 0, 0),
            (1, 0, 46, "ff", 8, "ffa6b927c7be800984030000", 0, 0),
        ],
        "residual_chunks": [
            (1, 0x27, 40),
            (1, 0xC7, 48),
            (1, 0xBE, 56),
            (1, 0x80, 64),
            (4, 0x09, 72),
            (4, 0x84, 80),
            (4, 0x03, 88),
            (4, 0x0E, 96),
            (6, 0xD2, 104),
            (6, 0x19, 112),
            (6, 0xCF, 120),
            (7, 0xB3, 0),
            (7, 0x48, 8),
            (7, 0x9A, 16),
        ],
        "first_payload_ctx": {
            "blk": 1,
            "kind": 22,
            "sel": 0,
            "state_in": 122,
            "state_out": 120,
            "ari_low": "1ec",
            "ari_range": 414,
            "ari_queue": -8,
            "ari_pending": 1,
            "ari_pbyte": "c7",
        },
        "term_state": {
            "mb": 1,
            "count": 0,
            "bits": "000000000000000000000000",
            "bit_cnt": 0,
            "ari_low": "3400",
            "ari_range": 326,
            "ari_queue": -2,
            "ari_pending": 1,
            "ari_pbyte": "dc",
        },
    },
    "fail_cb2_crd_096_096": {
        "cb_mask": 0x2,
        "cr_mask": 0xD,
        "cb_value": 96,
        "cr_value": 96,
        "tail": "0000000141d008086bbbccff",
        "decoded_bytes": FRAME_SIZE,
        "ffmpeg_signature": "bytestream -26",
        "expected_quality": False,
        "cbf_order": [(0, 0), (1, 1), (2, 0), (3, 0), (4, 1), (5, 0), (6, 1), (7, 1)],
        "coded_blocks": [1, 4, 6, 7],
        "payload_bytes": [0xBB, 0xCC, 0xFF],
        "payload_emit_rows": [
            (1, 0, 46, "bb", 24, "bbccff7c2ba7c7be80071563", 0, 0),
            (1, 0, 46, "cc", 16, "ccff7c2ba7c7be8007156300", 0, 0),
            (1, 0, 46, "ff", 8, "ff7c2ba7c7be800715630000", 0, 0),
        ],
        "residual_chunks": [
            (1, 0xA7, 40),
            (1, 0xC7, 48),
            (1, 0xBE, 56),
            (1, 0x80, 64),
            (4, 0x07, 72),
            (4, 0x15, 80),
            (4, 0x63, 88),
            (4, 0x0E, 96),
            (6, 0xD2, 104),
            (6, 0x19, 112),
            (6, 0xCF, 120),
            (7, 0xB3, 0),
            (7, 0x48, 8),
            (7, 0x9A, 16),
        ],
        "first_payload_ctx": {
            "blk": 1,
            "kind": 22,
            "sel": 0,
            "state_in": 122,
            "state_out": 120,
            "ari_low": "1ec",
            "ari_range": 414,
            "ari_queue": -8,
            "ari_pending": 1,
            "ari_pbyte": "c7",
        },
        "term_state": {
            "mb": 1,
            "count": 0,
            "bits": "000000000000000000000000",
            "bit_cnt": 0,
            "ari_low": "3400",
            "ari_range": 326,
            "ari_queue": -2,
            "ari_pending": 1,
            "ari_pbyte": "dc",
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
        "payload_emit_rows": [
            (1, 0, 46, "3a", 24, "3addf57c861a04bc714ac46b", 21, 6),
            (1, 0, 46, "dd", 16, "ddf57c861a04bc714ac46b00", 21, 6),
            (1, 0, 46, "f5", 8, "f57c861a04bc714ac46b0000", 21, 6),
        ],
        "residual_chunks": [
            (0, 0x1A, 40),
            (0, 0x04, 48),
            (0, 0xBC, 56),
            (0, 0x71, 64),
            (2, 0x4A, 72),
            (2, 0xC4, 80),
            (2, 0x6B, 88),
            (2, 0xE5, 96),
            (3, 0xAD, 104),
            (3, 0xAD, 112),
            (3, 0xAE, 120),
            (5, 0x12, 0),
            (5, 0x99, 8),
            (5, 0xB1, 16),
        ],
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
        "term_state": {
            "mb": 1,
            "count": 0,
            "bits": "000000000000000000000000",
            "bit_cnt": 0,
            "ari_low": "318",
            "ari_range": 312,
            "ari_queue": -8,
            "ari_pending": 1,
            "ari_pbyte": "62",
        },
    },
}


PAYLOAD_CTX_EXPECTATIONS: dict[str, dict[str, list[tuple[object, ...]] | list[tuple[int, int]]]] = {
    "fail_cb2_crd_160_160": {
        "counts": [(1, 21), (4, 21), (6, 21), (7, 20)],
        "final": [
            (1, 24, 1, 116, 114, "328", 282, -7, 0, 1, "9"),
            (4, 24, 1, 116, 114, "2b8", 266, -8, 0, 1, "d6"),
            (6, 24, 1, 116, 114, "2864", 326, -4, 0, 1, "b3"),
            (7, 24, 1, 116, 114, "3064", 326, -3, 0, 1, "dc"),
        ],
    },
    "fail_cb2_crd_096_160": {
        "counts": [(1, 21), (4, 21), (6, 21), (7, 20)],
        "final": [
            (1, 24, 1, 116, 114, "40", 282, -7, 0, 1, "7"),
            (4, 24, 1, 116, 114, "2b8", 266, -8, 0, 1, "d6"),
            (6, 24, 1, 116, 114, "2864", 326, -4, 0, 1, "b3"),
            (7, 24, 1, 116, 114, "3064", 326, -3, 0, 1, "dc"),
        ],
    },
    "fail_cb2_crd_160_096": {
        "counts": [(1, 21), (4, 21), (6, 21), (7, 20)],
        "final": [
            (1, 24, 1, 116, 114, "328", 282, -7, 0, 1, "9"),
            (4, 24, 1, 116, 114, "0", 266, -8, 0, 1, "d2"),
            (6, 24, 1, 116, 114, "1200", 326, -4, 0, 1, "b3"),
            (7, 24, 1, 116, 114, "1a00", 326, -3, 0, 1, "dc"),
        ],
    },
    "fail_cb2_crd_096_096": {
        "counts": [(1, 21), (4, 21), (6, 21), (7, 20)],
        "final": [
            (1, 24, 1, 116, 114, "40", 282, -7, 0, 1, "7"),
            (4, 24, 1, 116, 114, "0", 266, -8, 0, 1, "d2"),
            (6, 24, 1, 116, 114, "1200", 326, -4, 0, 1, "b3"),
            (7, 24, 1, 116, 114, "1a00", 326, -3, 0, 1, "dc"),
        ],
    },
    "pass_cbd_cr2_160_160": {
        "counts": [(0, 21), (2, 21), (3, 21), (5, 20)],
        "final": [
            (0, 24, 1, 116, 114, "ae4", 394, -6, 0, 1, "4a"),
            (2, 24, 1, 116, 114, "15ab8", 266, -1, 0, 1, "e5"),
            (3, 24, 1, 116, 114, "864", 326, -6, 0, 1, "12"),
            (5, 24, 1, 116, 114, "3064", 326, -3, 0, 1, "dc"),
        ],
    },
}


CBF_CTX_EXPECTATIONS: dict[str, list[tuple[object, ...]]] = {
    "fail_cb2_crd_160_160": [
        (0, 3, 105, 109, "4314", 396, -2, 0, 1, "5"),
        (1, 2, 124, 126, "87b6", 394, -1, 0, 1, "5"),
        (2, 1, 119, 123, "2040", 464, -4, 0, 1, "9"),
        (3, 2, 126, 124, "4080", 448, -3, 0, 1, "9"),
        (4, 4, 92, 100, "10774", 396, -1, 0, 1, "9"),
        (5, 7, 105, 109, "1ccc", 324, -5, 0, 1, "d6"),
        (6, 7, 109, 107, "3998", 428, -4, 0, 1, "d6"),
        (7, 5, 119, 117, "a41c", 368, -2, 0, 1, "b3"),
    ],
    "fail_cb2_crd_096_160": [
        (0, 3, 105, 109, "4314", 396, -2, 0, 1, "85"),
        (1, 2, 124, 126, "87b6", 394, -1, 0, 1, "85"),
        (2, 1, 119, 123, "498", 464, -4, 0, 1, "7"),
        (3, 2, 126, 124, "930", 448, -3, 0, 1, "7"),
        (4, 4, 92, 100, "2a34", 396, -1, 0, 1, "7"),
        (5, 7, 105, 109, "1ccc", 324, -5, 0, 1, "d6"),
        (6, 7, 109, 107, "3998", 428, -4, 0, 1, "d6"),
        (7, 5, 119, 117, "a41c", 368, -2, 0, 1, "b3"),
    ],
    "fail_cb2_crd_160_096": [
        (0, 3, 105, 109, "c6b4", 396, -2, 0, 1, "27"),
        (1, 2, 124, 126, "18ef6", 394, -1, 0, 1, "27"),
        (2, 1, 119, 123, "2040", 464, -4, 0, 1, "9"),
        (3, 2, 126, 124, "4080", 448, -3, 0, 1, "9"),
        (4, 4, 92, 100, "10774", 396, -1, 0, 1, "9"),
        (5, 7, 105, 109, "2e4", 324, -5, 0, 1, "d2"),
        (6, 7, 109, 107, "5c8", 428, -4, 0, 1, "d2"),
        (7, 5, 119, 117, "4800", 368, -2, 0, 1, "b3"),
    ],
    "fail_cb2_crd_096_096": [
        (0, 3, 105, 109, "c6b4", 396, -2, 0, 1, "a7"),
        (1, 2, 124, 126, "18ef6", 394, -1, 0, 1, "a7"),
        (2, 1, 119, 123, "498", 464, -4, 0, 1, "7"),
        (3, 2, 126, 124, "930", 448, -3, 0, 1, "7"),
        (4, 4, 92, 100, "2a34", 396, -1, 0, 1, "7"),
        (5, 7, 105, 109, "2e4", 324, -5, 0, 1, "d2"),
        (6, 7, 109, 107, "5c8", 428, -4, 0, 1, "d2"),
        (7, 5, 119, 117, "4800", 368, -2, 0, 1, "b3"),
    ],
    "pass_cbd_cr2_160_160": [
        (0, 3, 105, 103, "20914", 275, -1, 0, 1, "19"),
        (1, 3, 103, 109, "61b4", 444, -3, 0, 1, "4a"),
        (2, 3, 109, 107, "61b4", 314, -3, 0, 1, "4a"),
        (3, 1, 119, 117, "4f4", 300, -7, 0, 1, "ad"),
        (4, 7, 105, 109, "4bc4", 396, -3, 0, 1, "12"),
        (5, 6, 124, 126, "9916", 394, -2, 0, 1, "12"),
        (6, 5, 119, 123, "c58c", 284, -1, 0, 1, "dc"),
        (7, 6, 126, 124, "318", 312, -8, 0, 1, "62"),
    ],
}


P_SLICE_EMIT_TAIL = [
    (0, 3, 7, "d0", 32, "d008086b0000000000000000", 0, 0),
    (0, 3, 7, "08", 24, "08086b000000000000000000", 0, 0),
    (0, 3, 7, "08", 16, "086b00000000000000000000", 0, 0),
    (0, 3, 7, "6b", 8, "6b0000000000000000000000", 0, 0),
]


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


def parse_emit_rows(text: str) -> list[tuple[int, int, int, str, int, str, int, int]]:
    rows: list[tuple[int, int, int, str, int, str, int, int]] = []
    for line in text.splitlines():
        if "[CABACEMIT]" not in line:
            continue
        m = re.search(
            r"mb=(\d+) return_state=(\d+) return_sub=(\d+) byte=([0-9a-fA-F]+) "
            r"bit_cnt=(\d+) bit_buf=([0-9a-fA-F]+) pending_kind=(\d+) pending_sel=(\d+)",
            line,
        )
        if not m:
            continue
        rows.append(
            (
                int(m.group(1)),
                int(m.group(2)),
                int(m.group(3)),
                m.group(4)[:2].lower(),
                int(m.group(5)),
                m.group(6).lower(),
                int(m.group(7)),
                int(m.group(8)),
            )
        )
    return rows


def parse_residual_chunks(text: str) -> list[tuple[int, int, int]]:
    chunks: list[tuple[int, int, int]] = []
    for line in text.splitlines():
        if "[CABACBITS]" not in line or "cat=2" not in line:
            continue
        m = re.search(r"blk=(\d+) count=(\d+) bits=([0-9a-fA-F]+) bit_cnt=(\d+)", line)
        if not m:
            continue
        blk = int(m.group(1))
        count = int(m.group(2))
        if count != 8:
            raise SystemExit(f"[FAIL] HIGH_AMP_TRACE unexpected non-byte residual chunk: {line}")
        byte = int(m.group(3)[:2], 16)
        bit_cnt = int(m.group(4))
        chunks.append((blk, byte, bit_cnt))
    return chunks


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


def parse_cbf_context_trail(text: str) -> list[tuple[object, ...]]:
    trail: list[tuple[object, ...]] = []
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
        if kind != 21:
            continue
        trail.append(
            (
                blk,
                sel,
                state_in,
                state_out,
                m.group(6).lower(),
                int(m.group(7)),
                int(m.group(8)),
                int(m.group(9)),
                int(m.group(10)),
                m.group(11).lower(),
            )
        )
    return trail


def parse_payload_context_summary(text: str) -> tuple[list[tuple[int, int]], list[tuple[object, ...]]]:
    counts: dict[int, int] = {}
    final_by_block: dict[int, tuple[object, ...]] = {}
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
        if kind == 21:
            continue
        counts[blk] = counts.get(blk, 0) + 1
        final_by_block[blk] = (
            blk,
            kind,
            sel,
            state_in,
            state_out,
            m.group(6).lower(),
            int(m.group(7)),
            int(m.group(8)),
            int(m.group(9)),
            int(m.group(10)),
            m.group(11).lower(),
        )
    return sorted(counts.items()), [final_by_block[blk] for blk in sorted(final_by_block)]


def parse_terminate_state(text: str) -> dict[str, object]:
    marker = text.find("[CABACTERM]")
    if marker < 0:
        raise SystemExit("[FAIL] HIGH_AMP_TRACE missing CABACTERM state")

    # Verilator and the testbench can interleave stdout at byte granularity,
    # splitting the final CABACTERM line around TB progress prints. Collapse
    # just this record while dropping complete TB/banner lines so the arithmetic
    # state lock stays stable without accepting unrelated trace drift.
    segment = text[marker:]
    stop = segment.find("[PSKIP]")
    if stop >= 0:
        segment = segment[:stop]
    clean_parts: list[str] = []
    for line in segment.splitlines():
        if line.startswith("[TB]") or set(line.strip()) == {"="}:
            continue
        if "[TB]" in line:
            line = line.split("[TB]", 1)[0]
        clean_parts.append(line)
    clean = "".join(clean_parts)
    m = re.search(
        r"mb=(\d+) count=(\d+) bits=([0-9a-fA-F]+) bit_cnt=(\d+) "
        r"ari_low=([0-9a-fA-F]+) ari_range=(\d+) ari_queue=(-?\d+) "
        r"ari_outstanding=(\d+) ari_pending=(\d+) ari_pbyte=([0-9a-fA-F]+)",
        clean,
    )
    if m:
        return {
            "mb": int(m.group(1)),
            "count": int(m.group(2)),
            "bits": m.group(3).lower(),
            "bit_cnt": int(m.group(4)),
            "ari_low": m.group(5).lower(),
            "ari_range": int(m.group(6)),
            "ari_queue": int(m.group(7)),
            "ari_pending": int(m.group(9)),
            "ari_pbyte": m.group(10).lower(),
        }
    raise SystemExit("[FAIL] HIGH_AMP_TRACE missing CABACTERM state")


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

    emit_rows = parse_emit_rows(text)
    p_slice_emit_tail = [item for item in emit_rows if item[1] == 3][-4:]
    if p_slice_emit_tail != P_SLICE_EMIT_TAIL:
        raise SystemExit(
            f"[FAIL] HIGH_AMP_TRACE {name} P-slice emit tail {p_slice_emit_tail}, "
            f"expected {P_SLICE_EMIT_TAIL}"
        )

    payload_bytes = parse_payload_bytes(text)
    if payload_bytes[: len(spec["payload_bytes"])] != spec["payload_bytes"]:
        raise SystemExit(
            f"[FAIL] HIGH_AMP_TRACE {name} payload bytes {payload_bytes}, expected prefix {spec['payload_bytes']}"
        )

    payload_emit_rows = [item for item in emit_rows if item[0] == 1 and item[1] == 0 and item[2] == 46]
    if payload_emit_rows != spec["payload_emit_rows"]:
        raise SystemExit(
            f"[FAIL] HIGH_AMP_TRACE {name} payload emit rows {payload_emit_rows}, "
            f"expected {spec['payload_emit_rows']}"
        )

    residual_chunks = parse_residual_chunks(text)
    if residual_chunks != spec["residual_chunks"]:
        raise SystemExit(
            f"[FAIL] HIGH_AMP_TRACE {name} residual chunks {residual_chunks}, "
            f"expected {spec['residual_chunks']}"
        )

    first_ctx = parse_first_payload_ctx(text, coded_blocks[0])
    if first_ctx != spec["first_payload_ctx"]:
        raise SystemExit(
            f"[FAIL] HIGH_AMP_TRACE {name} first payload ctx {first_ctx}, expected {spec['first_payload_ctx']}"
        )

    cbf_ctx_trail = parse_cbf_context_trail(text)
    if cbf_ctx_trail != CBF_CTX_EXPECTATIONS[name]:
        raise SystemExit(
            f"[FAIL] HIGH_AMP_TRACE {name} CBF context trail {cbf_ctx_trail}, "
            f"expected {CBF_CTX_EXPECTATIONS[name]}"
        )

    payload_ctx_counts, payload_final_ctx = parse_payload_context_summary(text)
    expected_payload_ctx = PAYLOAD_CTX_EXPECTATIONS[name]
    if payload_ctx_counts != expected_payload_ctx["counts"]:
        raise SystemExit(
            f"[FAIL] HIGH_AMP_TRACE {name} payload ctx counts {payload_ctx_counts}, "
            f"expected {expected_payload_ctx['counts']}"
        )
    if payload_final_ctx != expected_payload_ctx["final"]:
        raise SystemExit(
            f"[FAIL] HIGH_AMP_TRACE {name} payload final ctx {payload_final_ctx}, "
            f"expected {expected_payload_ctx['final']}"
        )

    term_state = parse_terminate_state(text)
    if term_state != spec["term_state"]:
        raise SystemExit(
            f"[FAIL] HIGH_AMP_TRACE {name} terminate state {term_state}, expected {spec['term_state']}"
        )

    status = "strict expected-SAD pass" if spec["expected_quality"] else f"bounded one-frame miss {spec['ffmpeg_signature']}"
    chunk_summary = [(blk, f"0x{byte:02x}", bit_cnt) for blk, byte, bit_cnt in residual_chunks]
    print(
        f"[PASS] HIGH_AMP_TRACE {name}: {status}, tail={tail}, "
        f"CBF={cbf_order}, payload={[f'0x{b:02x}' for b in payload_bytes[:3]]}, "
        f"p_slice_emit_tail={p_slice_emit_tail}, payload_emit_rows={payload_emit_rows}, "
        f"chunks={chunk_summary}, first_ctx={first_ctx}, cbf_ctx={cbf_ctx_trail}, "
        f"payload_final_ctx={payload_final_ctx}, term={term_state}"
    )


def main() -> int:
    sim = build_debug_sim()
    for name, spec in CASES.items():
        check_case(sim, name, spec)
    print(
        "[PASS] CABAC P16x16 high-amplitude chroma-AC trace probe locks the failing "
        "Cb0x2/Cr0xd sign-family against reciprocal Cb0xd/Cr0x2 strict pass, including "
        "plane-local CBF walks/context trails, P-slice emit-tail bit-buffer rows, payload emit rows, residual output chunks, first payload bytes, and "
        "first/final-payload and terminate arithmetic context state."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
