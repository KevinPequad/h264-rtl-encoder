#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
export PATH=/home/chudpc/.local/verilator-5.020/bin:$PATH

python3 - <<'PY'
from pathlib import Path

W = H = 16
y0 = bytes([64]) * (W * H)
y1 = bytes([64]) * (W * H)
flat = bytes([128]) * ((W // 2) * (H // 2))
out_dir = Path("data")
out_dir.mkdir(parents=True, exist_ok=True)

for mask in range(0x1, 0x10):
    cb = bytes(
        136
        if (((mask >> ((y // 4) * 2 + (x // 4))) % 2) and ((x + y) % 2))
        else 128
        for y in range(H // 2)
        for x in range(W // 2)
    )
    out = out_dir / f"smoke_16x16_2f_cabac_p16x16_chroma_residual_cb_ac_arith_mask_{mask:x}.yuv"
    out.write_bytes(y0 + flat + flat + y1 + cb + flat)
    print(f"[INFO] CB_AC_ARITH mask=0x{mask:x} fixture {out} size={out.stat().st_size}")
PY

BUILD_OUT="$(mktemp /tmp/h264_cabac_cb_ac_arith_build.XXXXXX)"
python3 - <<'PY' > "$BUILD_OUT"
from scripts.rtl_runner import BuildConfig, build_sim, stage_workspace
workspace = stage_workspace('h264_cabac_cb_ac_arith_probe_')
config = BuildConfig(
    width=16,
    height=16,
    bit_depth=8,
    chroma_format_idc=1,
    enable_idr_ipcm=1,
    ipcm_sad_threshold=0,
    enable_cabac_p16x16=1,
    debug_cabac_p16x16=1,
)
print(build_sim(workspace, config))
PY
SIM="$(tail -1 "$BUILD_OUT")"
mkdir -p output/cabac_cb_ac_arith_probe

for mask in 1 2 3 4 5 6 7 8 9 a b c d e f; do
  "$SIM" \
    +frames=2 \
    +timeout=5000000 \
    +input="$ROOT/data/smoke_16x16_2f_cabac_p16x16_chroma_residual_cb_ac_arith_mask_${mask}.yuv" \
    +output="$ROOT/output/cabac_cb_ac_arith_probe/mask_${mask}.h264" \
    +idr_interval=12 \
    > "output/cabac_cb_ac_arith_probe/mask_${mask}.sim.log" 2>&1

  ffmpeg -y -v error -xerror -i "output/cabac_cb_ac_arith_probe/mask_${mask}.h264" \
    -f rawvideo -pix_fmt yuv420p "/tmp/h264_cb_ac_arith_mask_${mask}.yuv" \
    > "output/cabac_cb_ac_arith_probe/mask_${mask}.ffmpeg.log" 2>&1 || true
  bytes=$(wc -c < "/tmp/h264_cb_ac_arith_mask_${mask}.yuv")
  rm -f "/tmp/h264_cb_ac_arith_mask_${mask}.yuv"
  echo "[INFO] CB_AC_ARITH mask=0x${mask} decoded_bytes=${bytes}/768"
done

python3 - <<'PY'
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path("output/cabac_cb_ac_arith_probe")
EXPECTED = {
    "1": {
        "bytes": 768,
        "signature": "",
        "u_sad": 64,
        "cbf": [(0, 1, 119, 117, 392, -7, "cb"), (1, 1, 117, 119, 320, -4, "89"), (2, 3, 105, 109, 396, -2, "89"), (3, 0, 92, 90, 310, -2, "89"), (4, 7, 105, 109, 324, -8, "a7"), (5, 6, 124, 122, 314, -7, "a7"), (6, 5, 119, 123, 464, -5, "a7"), (7, 4, 92, 90, 365, -5, "a7")],
        "order": [("cbf", 0), ("payload", 0), ("cbf", 1), ("cbf", 2), ("cbf", 3), ("cbf", 4), ("cbf", 5), ("cbf", 6), ("cbf", 7)],
        "first_payload": (0, 22, 0, 122, 120, 410, -6, "cb"),
        "bits": [(2, 0, 8, "3a", 0), (2, 0, 8, "cb", 8), (2, 0, 8, "b4", 16), (2, 5, 8, "89", 24)],
        "emit_tail": [("3a", 32), ("cb", 24), ("b4", 16), ("89", 8)],
        "term": [(0, "00", 0, 3640, 365, -5, 0, 1, "a7")],
        "stream": (449, "808080808080808080808080808080808080800000000141d008086b3acbb489"),
    },
    "2": {
        "bytes": 768,
        "signature": "",
        "u_sad": 64,
        "cbf": [(0, 1, 119, 123, 464, -6, "cb"), (1, 1, 123, 121, 496, -5, "cb"), (2, 3, 105, 109, 468, -1, "d7"), (3, 0, 92, 90, 369, -1, "d7"), (4, 7, 105, 109, 396, -7, "45"), (5, 6, 124, 122, 398, -6, "45"), (6, 5, 119, 123, 338, -5, "45"), (7, 4, 92, 90, 266, -5, "45")],
        "order": [("cbf", 0), ("cbf", 1), ("payload", 1), ("cbf", 2), ("cbf", 3), ("cbf", 4), ("cbf", 5), ("cbf", 6), ("cbf", 7)],
        "first_payload": (1, 22, 0, 122, 120, 280, -5, "cb"),
        "bits": [(2, 0, 8, "3a", 0), (2, 1, 8, "cb", 8), (2, 1, 8, "da", 16), (2, 5, 8, "d7", 24)],
        "emit_tail": [("3a", 32), ("cb", 24), ("da", 16), ("d7", 8)],
        "term": [(0, "00", 0, 5482, 266, -5, 0, 1, "45")],
        "stream": (449, "808080808080808080808080808080808080800000000141d008086b3acbdad7"),
    },
    "3": {
        "bytes": 768,
        "signature": "",
        "u_sad": 128,
        "cbf": [(0, 1, 119, 117, 392, -5, "61"), (1, 1, 117, 115, 496, -2, "22"), (2, 3, 105, 109, 270, -8, "12"), (3, 0, 92, 90, 422, -7, "12"), (5, 6, 124, 122, 482, -4, "12"), (6, 5, 119, 123, 390, -3, "12"), (7, 4, 92, 90, 304, -3, "12")],
        "order": [("cbf", 0), ("payload", 0), ("cbf", 1), ("payload", 1), ("cbf", 2), ("cbf", 3), ("cbf", 5), ("cbf", 6), ("cbf", 7)],
        "first_payload": (0, 22, 0, 122, 120, 410, -4, "61"),
        "bits": [(1, 0, 8, "3a", 0), (1, 0, 8, "cc", 8), (2, 0, 8, "61", 16), (2, 0, 8, "35", 24), (2, 1, 8, "22", 32), (2, 1, 8, "67", 40), (2, 3, 8, "96", 48)],
        "emit_tail": [("3a", 56), ("cc", 48), ("61", 40), ("35", 32), ("22", 24), ("67", 16), ("96", 8)],
        "term": [(0, "00", 0, 23438, 304, -3, 0, 1, "12")],
        "stream": (452, "808080808080808080808080808080800000000141d008086b3acc6135226796"),
    },
    "4": {
        "bytes": 768,
        "signature": "",
        "u_sad": 64,
        "cbf": [(0, 1, 119, 123, 464, -6, "cb"), (1, 1, 123, 125, 432, -5, "cb"), (2, 3, 105, 103, 315, -5, "cb"), (3, 0, 92, 90, 466, -2, "75"), (4, 7, 105, 109, 270, -1, "75"), (5, 6, 124, 122, 284, -8, "40"), (6, 5, 119, 123, 464, -6, "40"), (7, 4, 92, 90, 365, -6, "40")],
        "order": [("cbf", 0), ("cbf", 1), ("cbf", 2), ("payload", 2), ("cbf", 3), ("cbf", 4), ("cbf", 5), ("cbf", 6), ("cbf", 7)],
        "first_payload": (2, 22, 0, 122, 120, 374, -4, "cb"),
        "bits": [(2, 0, 8, "3a", 0), (2, 2, 8, "cb", 8), (2, 2, 8, "e8", 16), (2, 6, 8, "75", 24)],
        "emit_tail": [("3a", 32), ("cb", 24), ("e8", 16), ("75", 8)],
        "term": [(0, "00", 0, 1232, 365, -6, 0, 1, "40")],
        "stream": (449, "808080808080808080808080808080808080800000000141d008086b3acbe875"),
    },
    "5": {
        "bytes": 768,
        "signature": "",
        "u_sad": 128,
        "cbf": [(0, 1, 119, 117, 309, -5, "6f"), (1, 1, 117, 119, 444, -1, "45"), (2, 3, 105, 103, 327, -1, "45"), (3, 0, 92, 90, 397, -7, "a4"), (4, 7, 105, 109, 468, -5, "a4"), (5, 6, 124, 122, 482, -4, "a4"), (6, 5, 119, 123, 390, -3, "a4"), (7, 4, 92, 90, 304, -3, "a4")],
        "order": [("cbf", 0), ("payload", 0), ("cbf", 1), ("cbf", 2), ("payload", 2), ("cbf", 3), ("cbf", 4), ("cbf", 5), ("cbf", 6), ("cbf", 7)],
        "first_payload": (0, 22, 0, 122, 120, 362, -4, "6f"),
        "bits": [(1, 0, 8, "3a", 0), (1, 0, 8, "cc", 8), (2, 0, 8, "6f", 16), (2, 0, 8, "78", 24), (2, 2, 8, "45", 32), (2, 2, 8, "40", 40), (2, 2, 8, "7b", 48)],
        "emit_tail": [("3a", 56), ("cc", 48), ("6f", 40), ("78", 32), ("45", 24), ("40", 16), ("7b", 8)],
        "term": [(0, "00", 0, 20158, 304, -3, 0, 1, "a4")],
        "stream": (452, "808080808080808080808080808080800000000141d008086b3acc6f7845407b"),
    },
    "6": {
        "bytes": 768,
        "signature": "",
        "u_sad": 128,
        "cbf": [(0, 1, 119, 123, 390, -3, "68"), (1, 1, 123, 121, 406, -2, "68"), (2, 3, 105, 103, 291, -8, "4c"), (3, 0, 92, 90, 397, -6, "92"), (4, 7, 105, 109, 468, -4, "92"), (5, 6, 124, 122, 482, -3, "92"), (6, 5, 119, 123, 390, -2, "92"), (7, 4, 92, 90, 304, -2, "92")],
        "order": [("cbf", 0), ("cbf", 1), ("payload", 1), ("cbf", 2), ("payload", 2), ("cbf", 3), ("cbf", 4), ("cbf", 5), ("cbf", 6), ("cbf", 7)],
        "first_payload": (1, 22, 0, 122, 120, 438, -1, "68"),
        "bits": [(1, 0, 8, "3a", 0), (1, 0, 8, "cc", 8), (2, 1, 8, "69", 16), (2, 1, 8, "3b", 24), (2, 1, 8, "a6", 32), (2, 2, 8, "4c", 40), (2, 2, 8, "f4", 48)],
        "emit_tail": [("3a", 56), ("cc", 48), ("69", 40), ("3b", 32), ("a6", 24), ("4c", 16), ("f4", 8)],
        "term": [(0, "00", 0, 20158, 304, -2, 0, 1, "92")],
        "stream": (452, "808080808080808080808080808080800000000141d008086b3acc693ba64cf4"),
    },
    "8": {
        "bytes": 768,
        "signature": "",
        "u_sad": 64,
        "cbf": [(0, 1, 119, 123, 464, -6, "cb"), (1, 1, 123, 125, 432, -5, "cb"), (2, 3, 105, 109, 468, -3, "cb"), (3, 0, 92, 100, 396, -1, "cb"), (4, 7, 105, 109, 468, -5, "26"), (5, 6, 124, 122, 482, -4, "26"), (6, 5, 119, 123, 390, -3, "26"), (7, 4, 92, 90, 304, -3, "26")],
        "order": [("cbf", 0), ("cbf", 1), ("cbf", 2), ("cbf", 3), ("payload", 3), ("cbf", 4), ("cbf", 5), ("cbf", 6), ("cbf", 7)],
        "first_payload": (3, 22, 0, 122, 120, 418, -8, "f1"),
        "bits": [(2, 0, 8, "3a", 0), (2, 3, 8, "cb", 8), (2, 3, 8, "f1", 16), (2, 3, 8, "7e", 24)],
        "emit_tail": [("3a", 32), ("cb", 24), ("f1", 16), ("7e", 8)],
        "term": [(0, "00", 0, 19182, 304, -3, 0, 1, "26")],
        "stream": (449, "808080808080808080808080808080808080800000000141d008086b3acbf17e"),
    },
    "c": {
        "bytes": 768,
        "signature": "",
        "u_sad": 128,
        "cbf": [(0, 1, 119, 123, 284, -5, "62"), (1, 1, 123, 125, 256, -4, "62"), (2, 3, 105, 103, 350, -3, "62"), (3, 0, 92, 100, 344, -7, "9a"), (5, 6, 124, 122, 284, -4, "19"), (6, 5, 119, 123, 464, -2, "19"), (7, 4, 92, 90, 365, -2, "19")],
        "order": [("cbf", 0), ("cbf", 1), ("cbf", 2), ("payload", 2), ("cbf", 3), ("payload", 3), ("cbf", 5), ("cbf", 6), ("cbf", 7)],
        "first_payload": (2, 22, 0, 122, 120, 384, -2, "62"),
        "bits": [(1, 0, 8, "3a", 0), (1, 0, 8, "cc", 8), (2, 2, 8, "62", 16), (2, 2, 8, "65", 24), (2, 3, 8, "0e", 32), (2, 3, 8, "9a", 40), (2, 3, 8, "64", 48)],
        "emit_tail": [("3a", 56), ("cc", 48), ("62", 40), ("65", 32), ("0e", 24), ("9a", 16), ("64", 8)],
        "term": [(0, "00", 0, 21552, 365, -2, 0, 1, "19")],
        "stream": (452, "808080808080808080808080808080800000000141d008086b3acc62650e9a64"),
    },
    "7": {
        "bytes": 768,
        "signature": "",
        "u_sad": 192,
        "cbf": [(0, 1, 119, 117, 336, -3, "cc"), (1, 1, 117, 115, 362, -8, "4f"), (2, 3, 105, 103, 361, -7, "b2"), (3, 0, 92, 90, 334, -7, "ae"), (4, 7, 105, 109, 396, -5, "ae"), (5, 6, 124, 122, 398, -4, "ae"), (6, 5, 119, 123, 338, -3, "ae"), (7, 4, 92, 90, 266, -3, "ae")],
        "order": [("cbf", 0), ("payload", 0), ("cbf", 1), ("payload", 1), ("cbf", 2), ("payload", 2), ("cbf", 3), ("cbf", 4), ("cbf", 5), ("cbf", 6), ("cbf", 7)],
        "first_payload": (0, 22, 0, 122, 120, 356, -2, "cc"),
        "bits": [(1, 0, 8, "3a", 0), (2, 0, 8, "cc", 8), (2, 0, 8, "32", 16), (2, 1, 8, "eb", 24), (2, 1, 8, "4f", 32), (2, 1, 8, "d8", 40), (2, 2, 8, "b2", 48), (2, 2, 8, "88", 56)],
        "emit_tail": [("3a", 64), ("cc", 56), ("32", 48), ("eb", 40), ("4f", 32), ("d8", 24), ("b2", 16), ("88", 8)],
        "term": [(0, "00", 0, 25402, 266, -3, 0, 1, "ae")],
        "stream": (453, "8080808080808080808080808080800000000141d008086b3acc32eb4fd8b288"),
    },
    "9": {
        "bytes": 768,
        "signature": "",
        "u_sad": 128,
        "cbf": [(0, 1, 119, 117, 309, -4, "68"), (1, 1, 117, 119, 444, -8, "a0"), (2, 3, 105, 109, 468, -6, "a0"), (3, 0, 92, 100, 396, -4, "a0"), (4, 7, 105, 109, 270, -2, "13"), (5, 6, 124, 122, 284, -1, "13"), (6, 5, 119, 123, 464, -7, "2a"), (7, 4, 92, 90, 365, -7, "2a")],
        "order": [("cbf", 0), ("payload", 0), ("cbf", 1), ("cbf", 2), ("cbf", 3), ("payload", 3), ("cbf", 4), ("cbf", 5), ("cbf", 6), ("cbf", 7)],
        "first_payload": (0, 22, 0, 122, 120, 362, -3, "68"),
        "bits": [(1, 0, 8, "3a", 0), (1, 0, 8, "cc", 8), (2, 0, 8, "68", 16), (2, 0, 8, "c0", 24), (2, 2, 8, "22", 32), (2, 3, 8, "a0", 40), (2, 3, 8, "8c", 48), (2, 7, 8, "13", 56)],
        "emit_tail": [("3a", 64), ("cc", 56), ("68", 48), ("c0", 40), ("22", 32), ("a0", 24), ("8c", 16), ("13", 8)],
        "term": [(0, "00", 0, 1072, 365, -7, 0, 1, "2a")],
        "stream": (453, "8080808080808080808080808080800000000141d008086b3acc68c022a08c13"),
    },
    "a": {
        "bytes": 768,
        "signature": "",
        "u_sad": 128,
        "cbf": [(0, 1, 119, 123, 390, -4, "70"), (1, 1, 123, 121, 406, -3, "70"), (2, 3, 105, 109, 468, -7, "9a"), (3, 0, 92, 100, 396, -5, "9a"), (4, 7, 105, 109, 270, -3, "26"), (5, 6, 124, 122, 284, -2, "26"), (6, 5, 119, 123, 464, -8, "55"), (7, 4, 92, 90, 365, -8, "55")],
        "order": [("cbf", 0), ("cbf", 1), ("payload", 1), ("cbf", 2), ("cbf", 3), ("payload", 3), ("cbf", 4), ("cbf", 5), ("cbf", 6), ("cbf", 7)],
        "first_payload": (1, 22, 0, 122, 120, 438, -2, "70"),
        "bits": [(1, 0, 8, "3a", 0), (1, 0, 8, "cc", 8), (2, 1, 8, "70", 16), (2, 1, 8, "6f", 24), (2, 3, 8, "4c", 32), (2, 3, 8, "9a", 40), (2, 3, 8, "78", 48), (2, 7, 8, "26", 56)],
        "emit_tail": [("3a", 64), ("cc", 56), ("70", 48), ("6f", 40), ("4c", 32), ("9a", 24), ("78", 16), ("26", 8)],
        "term": [(0, "00", 0, 48, 365, -8, 0, 1, "55")],
        "stream": (453, "8080808080808080808080808080800000000141d008086b3acc706f4c9a7826"),
    },
    "b": {
        "bytes": 768,
        "signature": "",
        "u_sad": 192,
        "cbf": [(0, 1, 119, 117, 336, -3, "cc"), (1, 1, 117, 115, 362, -8, "4f"), (2, 3, 105, 109, 270, -6, "b2"), (3, 0, 92, 100, 472, -3, "b2"), (4, 7, 105, 109, 324, -2, "c8"), (5, 6, 124, 122, 314, -1, "c8"), (6, 5, 119, 123, 464, -7, "ac"), (7, 4, 92, 90, 365, -7, "ac")],
        "order": [("cbf", 0), ("payload", 0), ("cbf", 1), ("payload", 1), ("cbf", 2), ("cbf", 3), ("payload", 3), ("cbf", 4), ("cbf", 5), ("cbf", 6), ("cbf", 7)],
        "first_payload": (0, 22, 0, 122, 120, 356, -2, "cc"),
        "bits": [(1, 0, 8, "3a", 0), (2, 0, 8, "cc", 8), (2, 0, 8, "32", 16), (2, 1, 8, "eb", 24), (2, 1, 8, "4f", 32), (2, 1, 8, "d8", 40), (2, 3, 8, "b2", 48), (2, 3, 8, "b1", 56), (2, 7, 8, "c8", 64)],
        "emit_tail": [("3a", 72), ("cc", 64), ("32", 56), ("eb", 48), ("4f", 40), ("d8", 32), ("b2", 24), ("b1", 16), ("c8", 8)],
        "term": [(0, "00", 0, 248, 365, -7, 0, 1, "ac")],
        "stream": (454, "80808080808080808080808080800000000141d008086b3acc32eb4fd8b2b1c8"),
    },
    "d": {
        "bytes": 768,
        "signature": "",
        "u_sad": 192,
        "cbf": [(0, 1, 119, 117, 336, -3, "cc"), (1, 1, 117, 119, 444, -7, "50"), (2, 3, 105, 103, 327, -7, "50"), (3, 0, 92, 100, 396, -3, "e9"), (4, 7, 105, 109, 324, -2, "8"), (5, 6, 124, 122, 314, -1, "8"), (6, 5, 119, 123, 464, -7, "ac"), (7, 4, 92, 90, 365, -7, "ac")],
        "order": [("cbf", 0), ("payload", 0), ("cbf", 1), ("cbf", 2), ("payload", 2), ("cbf", 3), ("payload", 3), ("cbf", 4), ("cbf", 5), ("cbf", 6), ("cbf", 7)],
        "first_payload": (0, 22, 0, 122, 120, 356, -2, "cc"),
        "bits": [(1, 0, 8, "3a", 0), (2, 0, 8, "cc", 8), (2, 0, 8, "32", 16), (2, 2, 8, "eb", 24), (2, 2, 8, "50", 32), (2, 2, 8, "1e", 40), (2, 3, 8, "e9", 48), (2, 3, 8, "2b", 56), (2, 7, 8, "08", 64)],
        "emit_tail": [("3a", 72), ("cc", 64), ("32", 56), ("eb", 48), ("50", 40), ("1e", 32), ("e9", 24), ("2b", 16), ("08", 8)],
        "term": [(0, "00", 0, 248, 365, -7, 0, 1, "ac")],
        "stream": (454, "80808080808080808080808080800000000141d008086b3acc32eb501ee92b08"),
    },
    "e": {
        "bytes": 768,
        "signature": "",
        "u_sad": 192,
        "cbf": [(0, 1, 119, 123, 464, -2, "cc"), (1, 1, 123, 121, 496, -1, "cc"), (2, 3, 105, 103, 291, -7, "73"), (3, 0, 92, 100, 396, -3, "49"), (4, 7, 105, 109, 324, -2, "8"), (5, 6, 124, 122, 314, -1, "8"), (6, 5, 119, 123, 464, -7, "ac"), (7, 4, 92, 90, 365, -7, "ac")],
        "order": [("cbf", 0), ("cbf", 1), ("payload", 1), ("cbf", 2), ("payload", 2), ("cbf", 3), ("payload", 3), ("cbf", 4), ("cbf", 5), ("cbf", 6), ("cbf", 7)],
        "first_payload": (1, 22, 0, 122, 120, 280, -1, "cc"),
        "bits": [(1, 0, 8, "3a", 0), (2, 1, 8, "cc", 8), (2, 1, 8, "34", 16), (2, 1, 8, "fd", 24), (2, 2, 8, "74", 32), (2, 2, 8, "3a", 40), (2, 3, 8, "49", 48), (2, 3, 8, "2b", 56), (2, 7, 8, "08", 64)],
        "emit_tail": [("3a", 72), ("cc", 64), ("34", 56), ("fd", 48), ("74", 40), ("3a", 32), ("49", 24), ("2b", 16), ("08", 8)],
        "term": [(0, "00", 0, 248, 365, -7, 0, 1, "ac")],
        "stream": (454, "80808080808080808080808080800000000141d008086b3acc34fd743a492b08"),
    },
    "f": {
        "bytes": 768,
        "signature": "",
        "u_sad": 256,
        "cbf": [(0, 3, 105, 103, 406, -3, "cc"), (1, 3, 103, 101, 297, -1, "24"), (2, 3, 101, 99, 374, -7, "24"), (3, 3, 99, 97, 446, -7, "aa"), (4, 7, 105, 109, 324, -7, "ed"), (5, 6, 124, 122, 314, -6, "ed"), (6, 5, 119, 123, 464, -4, "ed"), (7, 4, 92, 90, 365, -4, "ed")],
        "order": [("cbf", 0), ("payload", 0), ("cbf", 1), ("payload", 1), ("cbf", 2), ("payload", 2), ("cbf", 3), ("payload", 3), ("cbf", 4), ("cbf", 5), ("cbf", 6), ("cbf", 7)],
        "first_payload": (0, 22, 0, 122, 120, 438, -2, "cc"),
        "bits": [(1, 0, 8, "3a", 0), (2, 0, 8, "cc", 8), (2, 0, 8, "33", 16), (2, 1, 8, "24", 24), (2, 1, 8, "99", 32), (2, 1, 8, "ec", 40), (2, 2, 8, "24", 48), (2, 2, 8, "88", 56), (2, 3, 8, "aa", 64), (2, 5, 8, "9f", 72)],
        "emit_tail": [("3a", 80), ("cc", 72), ("33", 64), ("24", 56), ("99", 48), ("ec", 40), ("24", 32), ("88", 24), ("aa", 16), ("9f", 8)],
        "term": [(0, "00", 0, 12792, 365, -4, 0, 1, "ed")],
        "stream": (455, "808080808080808080808080800000000141d008086b3acc332499ec2488aa9f"),
    },
}

def decoded_raw(path: Path) -> bytes:
    with tempfile.NamedTemporaryFile(prefix="h264_cb_ac_arith_decode_", suffix=".yuv", delete=False) as tmp:
        tmp_path = Path(tmp.name)
    try:
        subprocess.run([
            "ffmpeg", "-y", "-v", "error", "-xerror", "-i", str(path),
            "-f", "rawvideo", "-pix_fmt", "yuv420p", str(tmp_path),
        ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
        return tmp_path.read_bytes() if tmp_path.exists() else b""
    finally:
        try:
            tmp_path.unlink()
        except FileNotFoundError:
            pass

FRAME_SIZE = 16 * 16 * 3 // 2
LUMA_SIZE = 16 * 16
CHROMA_SIZE = 16 * 16 // 4
P_SLICE_EMIT_TAIL = [
    (0, 3, 7, "d0", 32, "d008086b0000000000000000", 0, 0),
    (0, 3, 7, "08", 24, "08086b000000000000000000", 0, 0),
    (0, 3, 7, "08", 16, "086b00000000000000000000", 0, 0),
    (0, 3, 7, "6b", 8, "6b0000000000000000000000", 0, 0),
]
HEADER_DEBUG_TRAIL = [
    (33, "skip ctx=0 state=115 bin=0"),
    (34, "skip outstate=119 bits_valid=0 bits_count=0"),
    (36, "mbtype14 state=20"),
    (37, "mbtype15 state=98"),
    (38, "mbtype16 state=114"),
    (39, "mvdx ctx=0 state=127"),
    (40, "mvdy ctx=0 state=116"),
    (41, "cbp0 sel=3 state=91"),
    (42, "cbp1 sel=2 state=104"),
    (43, "cbp2 sel=1 state=120"),
    (44, "cbp3 state=58"),
    (45, "cbpchroma state=72"),
    (64, "cbpchroma_ac state=122"),
]

for mask, exp in EXPECTED.items():
    sim_log = ROOT / f"mask_{mask}.sim.log"
    h264 = ROOT / f"mask_{mask}.h264"
    ffmpeg_log = ROOT / f"mask_{mask}.ffmpeg.log"
    fixture = Path(f"data/smoke_16x16_2f_cabac_p16x16_chroma_residual_cb_ac_arith_mask_{mask}.yuv")
    text = sim_log.read_text(encoding="utf-8", errors="replace")
    cbf = []
    order = []
    bits_chunks = []
    payload_blocks = set()
    first_payload = None
    term = []
    emit = []
    header_debug = []
    for line in text.splitlines():
        if "[CABACDBG]" in line:
            m_dbg = re.search(r"\[CABACDBG\] mb=(\d+) sub=(\d+) (.*)", line)
            if m_dbg:
                mb, sub_i, rest = m_dbg.groups()
                if mb == "0":
                    header_debug.append((int(sub_i), rest))
            continue
        if "[CABACEMIT]" in line:
            m_emit = re.search(
                r"mb=(\d+) return_state=(\d+) return_sub=(\d+) byte=([0-9a-f]+) "
                r"bit_cnt=(\d+) bit_buf=([0-9a-f]+) pending_kind=(\d+) pending_sel=(\d+)",
                line,
            )
            if m_emit:
                mb, return_state, return_sub, byte, emit_bit_cnt, bit_buf_hex, pending_kind, pending_sel = m_emit.groups()
                emit.append((
                    int(mb), int(return_state), int(return_sub), byte[:2],
                    int(emit_bit_cnt), bit_buf_hex, int(pending_kind), int(pending_sel),
                ))
            continue
        if "[CABACTERM]" in line:
            m_term = re.search(
                r"count=(\d+) bits=([0-9a-f]+) bit_cnt=(\d+) ari_low=([0-9a-f]+) "
                r"ari_range=(\d+) ari_queue=(-?\d+) ari_outstanding=(\d+) "
                r"ari_pending=(\d+) ari_pbyte=([0-9a-f]+)",
                line,
            )
            if m_term:
                count, bits, bit_cnt, low, ari_range, ari_queue, outstanding, pending, pbyte = m_term.groups()
                term.append((
                    int(count), bits[:2], int(bit_cnt), int(low, 16), int(ari_range),
                    int(ari_queue), int(outstanding), int(pending), pbyte,
                ))
            continue
        if "[CABACBITS]" in line:
            m_bits = re.search(
                r"cat=(\d+) blk=(\d+) count=(\d+) bits=([0-9a-f]+) bit_cnt=(\d+)",
                line,
            )
            if m_bits:
                cat, blk, count, bits, bit_cnt = m_bits.groups()
                # Only the leading emitted byte is meaningful for these byte-aligned chunks;
                # the remaining printed hex digits are zero padding from the 96-bit bus.
                bits_chunks.append((int(cat), int(blk), int(count), bits[:2], int(bit_cnt)))
            continue
        if "[CABACCTX]" not in line:
            continue
        m = re.search(
            r"cat=(\d+) blk=(\d+) kind=(\d+) sel=(\d+) in=(\d+) out=(\d+) "
            r"ari_low=([0-9a-f]+) ari_range=(\d+) ari_queue=(-?\d+) "
            r"ari_outstanding=(\d+) ari_pending=(\d+) ari_pbyte=([0-9a-f]+)",
            line,
        )
        if not m or m.group(1) != "2":
            continue
        blk = int(m.group(2))
        kind = int(m.group(3))
        sel = int(m.group(4))
        state_in = int(m.group(5))
        state_out = int(m.group(6))
        ari_range = int(m.group(8))
        ari_queue = int(m.group(9))
        ari_pbyte = m.group(12)
        if kind == 21:
            cbf.append((blk, sel, state_in, state_out, ari_range, ari_queue, ari_pbyte))
            order.append(("cbf", blk))
        elif kind in (22, 23, 24):
            if blk not in payload_blocks:
                order.append(("payload", blk))
                payload_blocks.add(blk)
            if first_payload is None:
                first_payload = (blk, kind, sel, state_in, state_out, ari_range, ari_queue, ari_pbyte)

    decoded = decoded_raw(h264)
    got_bytes = len(decoded)
    if got_bytes != exp["bytes"]:
        raise SystemExit(f"[FAIL] CB_AC_ARITH mask=0x{mask} decoded {got_bytes}/768 bytes, expected {exp['bytes']}/768")
    src = fixture.read_bytes()
    if got_bytes >= FRAME_SIZE and decoded[:FRAME_SIZE] != src[:FRAME_SIZE]:
        raise SystemExit(f"[FAIL] CB_AC_ARITH mask=0x{mask} changed the IDR reference frame")
    if got_bytes == 2 * FRAME_SIZE:
        u0 = FRAME_SIZE + LUMA_SIZE
        v0 = u0 + CHROMA_SIZE
        u_sad = sum(abs(decoded[u0 + i] - src[u0 + i]) for i in range(CHROMA_SIZE))
        v_sad = sum(abs(decoded[v0 + i] - src[v0 + i]) for i in range(CHROMA_SIZE))
        if u_sad != exp["u_sad"] or v_sad != 0:
            raise SystemExit(
                f"[FAIL] CB_AC_ARITH mask=0x{mask} decoded-plane drift: "
                f"U_SAD={u_sad} V_SAD={v_sad}, expected U_SAD={exp['u_sad']} V_SAD=0"
            )
    ffmpeg_text = ffmpeg_log.read_text(encoding="utf-8", errors="replace")
    if exp["signature"]:
        if exp["signature"] not in ffmpeg_text:
            raise SystemExit(f"[FAIL] CB_AC_ARITH mask=0x{mask} missing FFmpeg signature {exp['signature']!r}")
    elif ffmpeg_text.strip():
        raise SystemExit(f"[FAIL] CB_AC_ARITH mask=0x{mask} expected clean FFmpeg log, got {ffmpeg_text.strip()!r}")
    if cbf != exp["cbf"] and cbf != exp.get("cbf_alt"):
        raise SystemExit(f"[FAIL] CB_AC_ARITH mask=0x{mask} CBF arithmetic trail {cbf}, expected {exp['cbf']}")
    if header_debug != HEADER_DEBUG_TRAIL:
        raise SystemExit(
            f"[FAIL] CB_AC_ARITH mask=0x{mask} early CABAC header debug trail "
            f"{header_debug}, expected {HEADER_DEBUG_TRAIL}"
        )
    if bits_chunks != exp["bits"] and bits_chunks != exp.get("bits_alt"):
        raise SystemExit(f"[FAIL] CB_AC_ARITH mask=0x{mask} CABAC output byte chunks {bits_chunks}, expected {exp['bits']}")
    got_p_slice_emit_tail = [item for item in emit if item[1] == 3][-4:]
    if got_p_slice_emit_tail != P_SLICE_EMIT_TAIL:
        raise SystemExit(
            f"[FAIL] CB_AC_ARITH mask=0x{mask} P-slice emit tail {got_p_slice_emit_tail}, "
            f"expected {P_SLICE_EMIT_TAIL}"
        )
    got_emit_tail = [(item[3], item[4]) for item in emit if item[1] == 0 and item[2] == 46]
    if got_emit_tail != exp["emit_tail"]:
        raise SystemExit(
            f"[FAIL] CB_AC_ARITH mask=0x{mask} emitted residual tail {got_emit_tail}, "
            f"expected {exp['emit_tail']}"
        )
    if term != exp["term"]:
        raise SystemExit(f"[FAIL] CB_AC_ARITH mask=0x{mask} CABAC terminate pre-state {term}, expected {exp['term']}")
    expected_size, expected_tail = exp["stream"]
    data = h264.read_bytes()
    got_tail = data[-32:].hex()
    if len(data) != expected_size or got_tail != expected_tail:
        raise SystemExit(
            f"[FAIL] CB_AC_ARITH mask=0x{mask} stream tail/size "
            f"size={len(data)} tail={got_tail}, expected size={expected_size} tail={expected_tail}"
        )
    if order != exp["order"] and order != exp.get("order_alt"):
        raise SystemExit(f"[FAIL] CB_AC_ARITH mask=0x{mask} CBF/payload order {order}, expected {exp['order']}")
    if first_payload != exp["first_payload"]:
        raise SystemExit(f"[FAIL] CB_AC_ARITH mask=0x{mask} first payload arithmetic row {first_payload}, expected {exp['first_payload']}")
    print(
        f"[PASS] CB_AC_ARITH mask=0x{mask} decoded {got_bytes}/768, "
        f"early header trail, P-slice emit tail/bit-buffer rows, CBF arithmetic trail, output/emit byte chunks, stream tail, terminate pre-state, first-payload state, and decoded-plane SAD locked"
    )

print("[PASS] CABAC P16x16 Cb-only chroma AC arithmetic trace probe locks all 15 nonzero Cb AC block masks, including early header debug state, P-slice emit tail/bit-buffer rows, residual output/emit byte chunks, stream tails, terminate pre-state, first-payload state, and decoded-plane SAD")
PY
