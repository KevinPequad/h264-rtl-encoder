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

for mask in (0x1, 0x2, 0xC):
    cb = bytes(
        136
        if (((mask >> ((y // 4) * 2 + (x // 4))) & 1) and ((x + y) % 2))
        else 128
        for y in range(H // 2)
        for x in range(W // 2)
    )
    out = out_dir / f"smoke_16x16_2f_cabac_p16x16_chroma_residual_cb_ac_tail_bitflip_mask_{mask:x}.yuv"
    out.write_bytes(y0 + flat + flat + y1 + cb + flat)
    print(f"[INFO] CB_AC_TAIL_BITFLIP mask=0x{mask:x} fixture {out} size={out.stat().st_size}")
PY

BUILD_OUT="$(mktemp /tmp/h264_cabac_cb_ac_tail_bitflip_build.XXXXXX)"
python3 - <<'PY' > "$BUILD_OUT"
from scripts.rtl_runner import BuildConfig, build_sim, stage_workspace
workspace = stage_workspace('h264_cabac_cb_ac_tail_bitflip_probe_')
config = BuildConfig(
    width=16,
    height=16,
    bit_depth=8,
    chroma_format_idc=1,
    enable_idr_ipcm=1,
    ipcm_sad_threshold=0,
    enable_cabac_p16x16=1,
)
print(build_sim(workspace, config))
PY
SIM="$(tail -1 "$BUILD_OUT")"
mkdir -p output/cabac_cb_ac_tail_bitflip_probe

for mask in 1 2 c; do
  "$SIM" \
    +frames=2 \
    +timeout=5000000 \
    +input="$ROOT/data/smoke_16x16_2f_cabac_p16x16_chroma_residual_cb_ac_tail_bitflip_mask_${mask}.yuv" \
    +output="$ROOT/output/cabac_cb_ac_tail_bitflip_probe/mask_${mask}.h264" \
    +idr_interval=12 \
    > "output/cabac_cb_ac_tail_bitflip_probe/mask_${mask}.sim.log" 2>&1
  ffmpeg -y -v error -xerror -i "output/cabac_cb_ac_tail_bitflip_probe/mask_${mask}.h264" \
    -f rawvideo -pix_fmt yuv420p "/tmp/h264_cb_ac_tail_bitflip_mask_${mask}.yuv" \
    > "output/cabac_cb_ac_tail_bitflip_probe/mask_${mask}.ffmpeg.log" 2>&1 || true
  bytes=$(wc -c < "/tmp/h264_cb_ac_tail_bitflip_mask_${mask}.yuv")
  rm -f "/tmp/h264_cb_ac_tail_bitflip_mask_${mask}.yuv"
  echo "[INFO] CB_AC_TAIL_BITFLIP mask=0x${mask} baseline_decoded_bytes=${bytes}/768"
done

python3 - <<'PY'
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(".")
OUT = ROOT / "output" / "cabac_cb_ac_tail_bitflip_probe"
FRAME_SIZE = 16 * 16 * 3 // 2
LUMA_SIZE = 16 * 16
CHROMA_SIZE = 16 * 16 // 4
EXPECTED_BASE = {
    "1": (384, "bytestream -19"),
    "2": (384, "bytestream -21"),
    "c": (384, "bytestream -18"),
}
# Entries are: CABAC payload byte offset from the locked post-slice-header scan
# start, original byte, flipped bit, mutated byte, expected Cb-plane SAD.
# Offset 0 is the common pre-residual CABAC prefix byte for these one-MB
# P16x16 streams; the residual byte chunks observed by the DEBUG_CABAC_P16X16
# arithmetic trace begin at offset 1.  Keep both classes locked so a future
# repair can distinguish early-CABAC-prefix fixes from residual-tail fixes.
EXPECTED_PROMOTIONS = {
    "1": {
        (0, 0x6B, 5, 0x4B, 64),
        (0, 0x6B, 7, 0xEB, 64),
        (1, 0xEB, 7, 0x6B, 64),
        (2, 0x2E, 0, 0x2F, 64),
        (2, 0x2E, 2, 0x2A, 64),
    },
    "2": {
        (0, 0x6B, 5, 0x4B, 64),
        (0, 0x6B, 7, 0xEB, 64),
        (1, 0xEB, 2, 0xEF, 64),
        (1, 0xEB, 7, 0x6B, 64),
        (2, 0x2F, 0, 0x2E, 64),
        (2, 0x2F, 2, 0x2B, 64),
    },
    "c": {
        (0, 0x6B, 5, 0x4B, 128),
        (0, 0x6B, 7, 0xEB, 128),
        (1, 0xEB, 7, 0x6B, 128),
    },
}


def decode_raw(data: bytes) -> tuple[bytes, str]:
    with tempfile.NamedTemporaryFile(prefix="h264_cb_ac_tail_bitflip_", suffix=".h264", delete=False) as h:
        h.write(data)
        h264_path = Path(h.name)
    with tempfile.NamedTemporaryFile(prefix="h264_cb_ac_tail_bitflip_", suffix=".yuv", delete=False) as y:
        yuv_path = Path(y.name)
    try:
        proc = subprocess.run(
            [
                "ffmpeg", "-y", "-v", "error", "-xerror", "-i", str(h264_path),
                "-f", "rawvideo", "-pix_fmt", "yuv420p", str(yuv_path),
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            check=False,
        )
        raw = yuv_path.read_bytes() if yuv_path.exists() else b""
        return raw, proc.stderr.decode("utf-8", "replace")
    finally:
        for p in (h264_path, yuv_path):
            try:
                p.unlink()
            except FileNotFoundError:
                pass


def plane_sad(mask: str, raw: bytes) -> tuple[int, int]:
    fixture = (ROOT / "data" / f"smoke_16x16_2f_cabac_p16x16_chroma_residual_cb_ac_tail_bitflip_mask_{mask}.yuv").read_bytes()
    if len(raw) != 2 * FRAME_SIZE:
        raise AssertionError(f"decoded {len(raw)}/768 bytes")
    if raw[:FRAME_SIZE] != fixture[:FRAME_SIZE]:
        raise AssertionError("mutated stream changed the IDR reference frame")
    u0 = FRAME_SIZE + LUMA_SIZE
    v0 = u0 + CHROMA_SIZE
    u_sad = sum(abs(raw[u0 + i] - fixture[u0 + i]) for i in range(CHROMA_SIZE))
    v_sad = sum(abs(raw[v0 + i] - fixture[v0 + i]) for i in range(CHROMA_SIZE))
    return u_sad, v_sad

for mask, (base_bytes, signature) in EXPECTED_BASE.items():
    stream = (OUT / f"mask_{mask}.h264").read_bytes()
    ffmpeg_text = (OUT / f"mask_{mask}.ffmpeg.log").read_text(encoding="utf-8", errors="replace")
    baseline_raw, _ = decode_raw(stream)
    if len(baseline_raw) != base_bytes or signature not in ffmpeg_text:
        raise SystemExit(
            f"[FAIL] CB_AC_TAIL_BITFLIP mask=0x{mask} baseline drift: "
            f"decoded {len(baseline_raw)}/768, expected {base_bytes}/768 with {signature!r}"
        )
    last_start = stream.rfind(b"\x00\x00\x00\x01")
    if last_start < 0:
        raise SystemExit(f"[FAIL] CB_AC_TAIL_BITFLIP mask=0x{mask} missing final Annex-B start code")
    # Skip the final NAL start code, NAL header, and fixed small slice-header prefix.
    scan_start = last_start + 8
    promotions = set()
    for pos in range(scan_start, len(stream)):
        original = stream[pos]
        for bit in range(8):
            mutated = bytearray(stream)
            mutated[pos] ^= 1 << bit
            raw, err = decode_raw(bytes(mutated))
            if len(raw) != 2 * FRAME_SIZE:
                continue
            try:
                u_sad, v_sad = plane_sad(mask, raw)
            except AssertionError:
                continue
            if u_sad != 0 and v_sad == 0 and not err.strip():
                promotions.add((pos - scan_start, original, bit, mutated[pos], u_sad))
    expected = EXPECTED_PROMOTIONS[mask]
    if promotions != expected:
        raise SystemExit(
            f"[FAIL] CB_AC_TAIL_BITFLIP mask=0x{mask} promotions {sorted(promotions)}, "
            f"expected {sorted(expected)}"
        )
    prefix_promotions = {item for item in promotions if item[0] == 0}
    residual_promotions = promotions - prefix_promotions
    expected_prefix = {item for item in expected if item[0] == 0}
    if prefix_promotions != expected_prefix:
        raise SystemExit(
            f"[FAIL] CB_AC_TAIL_BITFLIP mask=0x{mask} prefix promotions "
            f"{sorted(prefix_promotions)}, expected {sorted(expected_prefix)}"
        )
    print(
        f"[PASS] CB_AC_TAIL_BITFLIP mask=0x{mask} baseline stays short at {base_bytes}/768; "
        f"locked {len(prefix_promotions)} prefix and {len(residual_promotions)} residual-byte "
        f"one-bit mutations that strict-decode with Cb-only delta"
    )

print("[PASS] CABAC P16x16 sparse Cb AC payload bitflip probe locks strict-decodable pre-residual-prefix and residual-byte mutations for masks 0x1, 0x2, and 0xc")
PY
