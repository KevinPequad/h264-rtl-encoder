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

for mask in (0x1, 0x2, 0x3, 0x4, 0x8, 0xC):
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

for mask in 1 2 3 4 8 c; do
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
        "bytes": 384,
        "signature": "bytestream -19",
        "cbf": [(0, 1, 119, 117, 392, -1, "ea"), (1, 1, 117, 119, 320, -6, "26"), (2, 3, 105, 109, 396, -4, "26"), (3, 0, 92, 90, 310, -4, "26"), (4, 7, 105, 109, 324, -2, "26"), (5, 6, 124, 122, 314, -1, "26"), (6, 5, 119, 123, 464, -7, "9d"), (7, 4, 92, 90, 365, -7, "9d")],
        "order": [("cbf", 0), ("payload", 0), ("cbf", 1), ("cbf", 2), ("cbf", 3), ("cbf", 4), ("cbf", 5), ("cbf", 6), ("cbf", 7)],
        "first_payload": (0, 22, 0, 122, 120, 410, -8, "2e"),
        "bits": [(2, 0, 8, "eb", 0), (2, 0, 8, "2e", 8), (2, 0, 8, "d2", 16), (2, 7, 8, "26", 24)],
    },
    "2": {
        "bytes": 384,
        "signature": "bytestream -21",
        "cbf": [(0, 1, 119, 123, 464, -8, "2f"), (1, 1, 123, 121, 496, -7, "2f"), (2, 3, 105, 109, 468, -3, "5c"), (3, 0, 92, 90, 369, -3, "5c"), (4, 7, 105, 109, 396, -1, "5c"), (5, 6, 124, 122, 398, -8, "16"), (6, 5, 119, 123, 338, -7, "16"), (7, 4, 92, 90, 266, -7, "16")],
        "order": [("cbf", 0), ("cbf", 1), ("payload", 1), ("cbf", 2), ("cbf", 3), ("cbf", 4), ("cbf", 5), ("cbf", 6), ("cbf", 7)],
        "first_payload": (1, 22, 0, 122, 120, 280, -7, "2f"),
        "bits": [(2, 1, 8, "eb", 0), (2, 1, 8, "2f", 8), (2, 1, 8, "6b", 16), (2, 6, 8, "5d", 24)],
    },
    "3": {
        "bytes": 768,
        "signature": "",
        "cbf": [(0, 1, 119, 117, 392, -7, "84"), (1, 1, 117, 115, 496, -4, "89"), (2, 3, 105, 109, 270, -2, "58"), (3, 0, 92, 90, 422, -1, "58"), (4, 7, 105, 109, 468, -7, "4a"), (5, 6, 124, 122, 482, -6, "4a"), (6, 5, 119, 123, 390, -5, "4a"), (7, 4, 92, 90, 304, -5, "4a")],
        "order": [("cbf", 0), ("payload", 0), ("cbf", 1), ("payload", 1), ("cbf", 2), ("cbf", 3), ("cbf", 4), ("cbf", 5), ("cbf", 6), ("cbf", 7)],
        "first_payload": (0, 22, 0, 122, 120, 410, -6, "84"),
        "bits": [(1, 0, 8, "eb", 0), (2, 0, 8, "31", 8), (2, 0, 8, "84", 16), (2, 0, 8, "d4", 24), (2, 1, 8, "89", 32), (2, 1, 8, "9e", 40), (2, 5, 8, "58", 48)],
    },
    "4": {
        "bytes": 768,
        "signature": "",
        "cbf": [(0, 1, 119, 123, 464, -8, "2f"), (1, 1, 123, 125, 432, -7, "2f"), (2, 3, 105, 103, 315, -7, "2f"), (3, 0, 92, 90, 466, -4, "d4"), (4, 7, 105, 109, 270, -3, "d4"), (5, 6, 124, 122, 284, -2, "d4"), (6, 5, 119, 123, 464, -8, "1"), (7, 4, 92, 90, 365, -8, "1")],
        "order": [("cbf", 0), ("cbf", 1), ("cbf", 2), ("payload", 2), ("cbf", 3), ("cbf", 4), ("cbf", 5), ("cbf", 6), ("cbf", 7)],
        "first_payload": (2, 22, 0, 122, 120, 374, -6, "2f"),
        "bits": [(2, 1, 8, "eb", 0), (2, 2, 8, "2f", 8), (2, 2, 8, "a1", 16), (2, 7, 8, "d5", 24)],
    },
    "8": {
        "bytes": 768,
        "signature": "",
        "cbf": [(0, 1, 119, 123, 464, -8, "2f"), (1, 1, 123, 125, 432, -7, "2f"), (2, 3, 105, 109, 468, -5, "2f"), (3, 0, 92, 100, 396, -3, "2f"), (4, 7, 105, 109, 468, -7, "9a"), (5, 6, 124, 122, 482, -6, "9a"), (6, 5, 119, 123, 390, -5, "9a"), (7, 4, 92, 90, 304, -5, "9a")],
        "order": [("cbf", 0), ("cbf", 1), ("cbf", 2), ("cbf", 3), ("payload", 3), ("cbf", 4), ("cbf", 5), ("cbf", 6), ("cbf", 7)],
        "first_payload": (3, 22, 0, 122, 120, 418, -2, "2f"),
        "bits": [(2, 1, 8, "eb", 0), (2, 3, 8, "2f", 8), (2, 3, 8, "c5", 16), (2, 5, 8, "f8", 24)],
    },
    "c": {
        "bytes": 384,
        "signature": "bytestream -18",
        "cbf": [(0, 1, 119, 123, 284, -7, "89"), (1, 1, 123, 125, 256, -6, "89"), (2, 3, 105, 103, 350, -5, "89"), (3, 0, 92, 100, 344, -1, "3a"), (4, 7, 105, 109, 270, -7, "64"), (5, 6, 124, 122, 284, -6, "64"), (6, 5, 119, 123, 464, -4, "64"), (7, 4, 92, 90, 365, -4, "64")],
        "order": [("cbf", 0), ("cbf", 1), ("cbf", 2), ("payload", 2), ("cbf", 3), ("payload", 3), ("cbf", 4), ("cbf", 5), ("cbf", 6), ("cbf", 7)],
        "first_payload": (2, 22, 0, 122, 120, 384, -4, "89"),
        "bits": [(1, 0, 8, "eb", 0), (2, 0, 8, "31", 8), (2, 2, 8, "89", 16), (2, 2, 8, "94", 24), (2, 3, 8, "69", 40), (2, 3, 8, "90", 48)],
    },
}

def decoded_bytes(path: Path) -> int:
    with tempfile.NamedTemporaryFile(prefix="h264_cb_ac_arith_decode_", suffix=".yuv", delete=False) as tmp:
        tmp_path = Path(tmp.name)
    try:
        subprocess.run([
            "ffmpeg", "-y", "-v", "error", "-xerror", "-i", str(path),
            "-f", "rawvideo", "-pix_fmt", "yuv420p", str(tmp_path),
        ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
        return tmp_path.stat().st_size if tmp_path.exists() else 0
    finally:
        try:
            tmp_path.unlink()
        except FileNotFoundError:
            pass

for mask, exp in EXPECTED.items():
    sim_log = ROOT / f"mask_{mask}.sim.log"
    h264 = ROOT / f"mask_{mask}.h264"
    ffmpeg_log = ROOT / f"mask_{mask}.ffmpeg.log"
    text = sim_log.read_text(encoding="utf-8", errors="replace")
    cbf = []
    order = []
    bits_chunks = []
    payload_blocks = set()
    first_payload = None
    for line in text.splitlines():
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

    got_bytes = decoded_bytes(h264)
    if got_bytes != exp["bytes"]:
        raise SystemExit(f"[FAIL] CB_AC_ARITH mask=0x{mask} decoded {got_bytes}/768 bytes, expected {exp['bytes']}/768")
    ffmpeg_text = ffmpeg_log.read_text(encoding="utf-8", errors="replace")
    if exp["signature"]:
        if exp["signature"] not in ffmpeg_text:
            raise SystemExit(f"[FAIL] CB_AC_ARITH mask=0x{mask} missing FFmpeg signature {exp['signature']!r}")
    elif ffmpeg_text.strip():
        raise SystemExit(f"[FAIL] CB_AC_ARITH mask=0x{mask} expected clean FFmpeg log, got {ffmpeg_text.strip()!r}")
    if cbf != exp["cbf"]:
        raise SystemExit(f"[FAIL] CB_AC_ARITH mask=0x{mask} CBF arithmetic trail {cbf}, expected {exp['cbf']}")
    if bits_chunks != exp["bits"]:
        raise SystemExit(f"[FAIL] CB_AC_ARITH mask=0x{mask} CABAC output byte chunks {bits_chunks}, expected {exp['bits']}")
    if order != exp["order"]:
        raise SystemExit(f"[FAIL] CB_AC_ARITH mask=0x{mask} CBF/payload order {order}, expected {exp['order']}")
    if first_payload != exp["first_payload"]:
        raise SystemExit(f"[FAIL] CB_AC_ARITH mask=0x{mask} first payload arithmetic row {first_payload}, expected {exp['first_payload']}")
    print(
        f"[PASS] CB_AC_ARITH mask=0x{mask} decoded {got_bytes}/768, "
        f"CBF arithmetic trail, output byte chunks, and first-payload state locked"
    )

print("[PASS] CABAC P16x16 Cb-only chroma AC arithmetic trace probe locks failing top/split masks against passing top-pair and bottom-single controls, including residual output byte chunks")
PY
