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
flat_chroma = bytes([128]) * ((W // 2) * (H // 2))
out_dir = Path("data")
out_dir.mkdir(parents=True, exist_ok=True)

def cb_for_mask(mask: int) -> bytes:
    out = []
    for y in range(H // 2):
        for x in range(W // 2):
            block = (1 if x >= 4 else 0) + (2 if y >= 4 else 0)
            out.append(136 if ((mask >> block) & 1 and ((x + y) % 2)) else 128)
    return bytes(out)

for mask in range(1, 16):
    out = out_dir / f"smoke_16x16_2f_cabac_p16x16_chroma_residual_cb_ac_prefix_bitflip_mask_{mask:x}.yuv"
    out.write_bytes(y0 + flat_chroma + flat_chroma + y1 + cb_for_mask(mask) + flat_chroma)
    print(f"[INFO] CB_AC_PREFIX_BITFLIP mask=0x{mask:x} fixture {out} size={out.stat().st_size}")
PY

BUILD_OUT="$(mktemp /tmp/h264_cabac_cb_ac_prefix_bitflip_build.XXXXXX)"
python3 - <<'PY' > "$BUILD_OUT"
from scripts.rtl_runner import BuildConfig, build_sim, stage_workspace
workspace = stage_workspace('h264_cabac_cb_ac_prefix_bitflip_probe_')
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
mkdir -p output/cabac_cb_ac_prefix_bitflip_probe

python3 - "$SIM" <<'PY'
from pathlib import Path
import subprocess
import sys
import tempfile

sim = sys.argv[1]
root = Path.cwd()
out_dir = root / "output" / "cabac_cb_ac_prefix_bitflip_probe"
frame_size = 16 * 16 * 3 // 2
luma_size = 16 * 16
chroma_size = 16 * 16 // 4
expected_bytes = frame_size * 2
expected_short_signatures = {
    0x1: "bytestream -19",
    0x2: "bytestream -21",
    0x5: "bytestream -22",
    0x6: "bytestream -18",
    0x9: "bytestream -14",
    0xA: "bytestream -20",
    0xC: "bytestream -18",
}
expected_full = {0x3, 0x4, 0x7, 0x8, 0xB, 0xD, 0xE, 0xF}
expected_prefix_byte = 0x6B
prefix_flips = {5: 0x4B, 7: 0xEB}


def decode_raw(data: bytes) -> tuple[bytes, str]:
    with tempfile.NamedTemporaryFile(prefix="h264_cb_ac_prefix_bitflip_", suffix=".h264", delete=False) as h:
        h.write(data)
        h264_path = Path(h.name)
    with tempfile.NamedTemporaryFile(prefix="h264_cb_ac_prefix_bitflip_", suffix=".yuv", delete=False) as y:
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
        for path in (h264_path, yuv_path):
            try:
                path.unlink()
            except FileNotFoundError:
                pass


def decoded_plane_sad(mask: int, raw: bytes) -> tuple[int, int]:
    fixture = (root / "data" / f"smoke_16x16_2f_cabac_p16x16_chroma_residual_cb_ac_prefix_bitflip_mask_{mask:x}.yuv").read_bytes()
    if len(raw) != expected_bytes:
        raise AssertionError(f"decoded {len(raw)}/{expected_bytes} bytes")
    if raw[:frame_size] != fixture[:frame_size]:
        raise AssertionError("decoded IDR reference frame changed")
    u0 = frame_size + luma_size
    v0 = u0 + chroma_size
    u_sad = sum(abs(raw[u0 + i] - fixture[u0 + i]) for i in range(chroma_size))
    v_sad = sum(abs(raw[v0 + i] - fixture[v0 + i]) for i in range(chroma_size))
    return u_sad, v_sad


for mask in range(1, 16):
    input_path = root / "data" / f"smoke_16x16_2f_cabac_p16x16_chroma_residual_cb_ac_prefix_bitflip_mask_{mask:x}.yuv"
    h264 = out_dir / f"mask_{mask:x}.h264"
    sim_log = out_dir / f"mask_{mask:x}.sim.log"
    with sim_log.open("w") as log:
        subprocess.run(
            [sim, "+frames=2", "+timeout=5000000", f"+input={input_path}", f"+output={h264}", "+idr_interval=12"],
            cwd=root,
            stdout=log,
            stderr=subprocess.STDOUT,
            check=True,
        )
    sim_text = sim_log.read_text(errors="ignore")
    if "cabac_p16x16_mbs=1" not in sim_text or "cb_ac_mbs=1" not in sim_text or "cr_ac_mbs=0" not in sim_text:
        raise SystemExit(f"[FAIL] CB_AC_PREFIX_BITFLIP mask=0x{mask:x} did not exercise Cb-only CABAC P16x16 AC")
    expected_blocks = mask.bit_count()
    if f"cb_ac_blocks={expected_blocks}" not in sim_text or "cr_ac_blocks=0" not in sim_text:
        raise SystemExit(f"[FAIL] CB_AC_PREFIX_BITFLIP mask=0x{mask:x} did not report {expected_blocks} Cb AC blocks")

    stream = h264.read_bytes()
    last_start = stream.rfind(b"\x00\x00\x00\x01")
    if last_start < 0:
        raise SystemExit(f"[FAIL] CB_AC_PREFIX_BITFLIP mask=0x{mask:x} missing final Annex-B start code")
    scan_start = last_start + 8
    if scan_start >= len(stream):
        raise SystemExit(f"[FAIL] CB_AC_PREFIX_BITFLIP mask=0x{mask:x} missing P-slice payload prefix")
    if stream[scan_start] != expected_prefix_byte:
        raise SystemExit(
            f"[FAIL] CB_AC_PREFIX_BITFLIP mask=0x{mask:x} prefix byte 0x{stream[scan_start]:02x}, "
            f"expected 0x{expected_prefix_byte:02x}"
        )

    baseline_raw, baseline_err = decode_raw(stream)
    if mask in expected_full:
        if len(baseline_raw) != expected_bytes or baseline_err.strip():
            raise SystemExit(f"[FAIL] CB_AC_PREFIX_BITFLIP mask=0x{mask:x} baseline full-decode drift")
        u_sad, v_sad = decoded_plane_sad(mask, baseline_raw)
        if u_sad != expected_blocks * 64 or v_sad != 0:
            raise SystemExit(f"[FAIL] CB_AC_PREFIX_BITFLIP mask=0x{mask:x} baseline SAD drift U={u_sad} V={v_sad}")
    else:
        signature = expected_short_signatures[mask]
        if len(baseline_raw) != frame_size or signature not in baseline_err:
            raise SystemExit(
                f"[FAIL] CB_AC_PREFIX_BITFLIP mask=0x{mask:x} baseline miss drift: "
                f"decoded {len(baseline_raw)}/{expected_bytes}, expected {signature!r}"
            )

    mutation_results = []
    for bit, mutated_byte in prefix_flips.items():
        mutated = bytearray(stream)
        mutated[scan_start] ^= 1 << bit
        if mutated[scan_start] != mutated_byte:
            raise SystemExit(f"internal prefix mutation mismatch for bit {bit}")
        raw, err = decode_raw(bytes(mutated))
        if err.strip():
            raise SystemExit(f"[FAIL] CB_AC_PREFIX_BITFLIP mask=0x{mask:x} bit{bit} FFmpeg stderr: {err.strip()!r}")
        u_sad, v_sad = decoded_plane_sad(mask, raw)
        expected_u = expected_blocks * 64
        if u_sad != expected_u or v_sad != 0:
            raise SystemExit(
                f"[FAIL] CB_AC_PREFIX_BITFLIP mask=0x{mask:x} bit{bit} SAD U={u_sad} V={v_sad}, "
                f"expected U={expected_u} V=0"
            )
        mutation_results.append(f"bit{bit}->0x{mutated_byte:02x}:U_SAD={u_sad}")

    baseline_kind = "strict" if mask in expected_full else f"short/{expected_short_signatures[mask]}"
    print(
        f"[PASS] CB_AC_PREFIX_BITFLIP mask=0x{mask:x} baseline={baseline_kind}; "
        f"common prefix 0x6b flips strict-decode ({', '.join(mutation_results)})"
    )

print("[PASS] CABAC P16x16 sparse Cb AC prefix bitflip sweep locks that common prefix-byte flips 0x6b->0x4b and 0x6b->0xeb strict-decode all 15 Cb-only AC masks while preserving Cb-only SAD")
PY
