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
# Legacy-named probe note: the common 0x6b byte is the final byte of the
# P-slice header plus CABAC alignment, not the first residual/CABAC payload
# byte.  For the generated 2-frame P-slice this byte packs
# adaptive_ref_pic_marking_mode_flag, cabac_init_idc, slice_qp_delta,
# disable_deblocking_filter_idc, and the two cabac_alignment_one_bits.  The
# next byte is the first CABAC-coded MB/payload byte.
expected_header_tail_byte = 0x6B
expected_first_cabac_byte = 0xEB
# Bit positions are MSB-first in the four-byte CABAC P-slice header RBSP
# (d0 08 08 6b for the generated second frame):
#   0      first_mb_in_slice = ue(0)
#   1      slice_type        = ue(P=0)
#   2..4   pic_parameter_set_id = ue(1), selecting the CABAC PPS
#   5..12  frame_num
#   13..21 pic_order_cnt_lsb
#   22     num_ref_idx_active_override_flag
#   23     ref_pic_list_reordering_flag_l0
#   24     adaptive_ref_pic_marking_mode_flag
#   25     cabac_init_idc = ue(0)
#   26     slice_qp_delta = se(0)
#   27..29 disable_deblocking_filter_idc = ue(1)
#   30..31 cabac_alignment_one_bit, cabac_alignment_one_bit
expected_header_field_bits = {
    "first_mb_in_slice": (0, "1"),
    "slice_type_p": (1, "1"),
    "pic_parameter_set_id_1": (2, "010"),
    "num_ref_idx_active_override_flag": (22, "0"),
    "ref_pic_list_reordering_flag_l0": (23, "0"),
    "adaptive_ref_pic_marking_mode_flag": (24, "0"),
    "cabac_init_idc_0": (25, "1"),
    "slice_qp_delta_0": (26, "1"),
    "disable_deblocking_filter_idc_1": (27, "010"),
    "cabac_alignment_one_bits": (30, "11"),
}
header_tail_flips = {
    5: (0x4B, "slice_qp_delta_prefix"),
    7: (0xEB, "adaptive_ref_pic_marking_mode_flag"),
}


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


def assert_header_field_bits(mask: int, header_bytes: bytes) -> None:
    bits = "".join(f"{byte:08b}" for byte in header_bytes)
    if len(bits) != 32:
        raise SystemExit(f"[FAIL] CB_AC_PREFIX_BITFLIP mask=0x{mask:x} header bit length {len(bits)}, expected 32")
    for name, (start, expected) in expected_header_field_bits.items():
        got = bits[start:start + len(expected)]
        if got != expected:
            raise SystemExit(
                f"[FAIL] CB_AC_PREFIX_BITFLIP mask=0x{mask:x} header field {name} bits {got}, expected {expected}"
            )


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
    header_tail_idx = last_start + 8
    first_cabac_idx = last_start + 9
    if first_cabac_idx >= len(stream):
        raise SystemExit(f"[FAIL] CB_AC_PREFIX_BITFLIP mask=0x{mask:x} missing P-slice CABAC payload byte")
    assert_header_field_bits(mask, stream[last_start + 5:first_cabac_idx])
    if stream[header_tail_idx] != expected_header_tail_byte:
        raise SystemExit(
            f"[FAIL] CB_AC_PREFIX_BITFLIP mask=0x{mask:x} slice-header tail byte "
            f"0x{stream[header_tail_idx]:02x}, expected 0x{expected_header_tail_byte:02x}"
        )
    if stream[first_cabac_idx] != expected_first_cabac_byte:
        raise SystemExit(
            f"[FAIL] CB_AC_PREFIX_BITFLIP mask=0x{mask:x} first CABAC payload byte "
            f"0x{stream[first_cabac_idx]:02x}, expected 0x{expected_first_cabac_byte:02x}"
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
    for bit, (mutated_byte, field_name) in header_tail_flips.items():
        mutated = bytearray(stream)
        mutated[header_tail_idx] ^= 1 << bit
        if mutated[header_tail_idx] != mutated_byte:
            raise SystemExit(f"internal slice-header-tail mutation mismatch for bit {bit}")
        raw, err = decode_raw(bytes(mutated))
        if err.strip():
            raise SystemExit(f"[FAIL] CB_AC_PREFIX_BITFLIP mask=0x{mask:x} {field_name} bit{bit} FFmpeg stderr: {err.strip()!r}")
        u_sad, v_sad = decoded_plane_sad(mask, raw)
        expected_u = expected_blocks * 64
        if u_sad != expected_u or v_sad != 0:
            raise SystemExit(
                f"[FAIL] CB_AC_PREFIX_BITFLIP mask=0x{mask:x} {field_name} bit{bit} SAD U={u_sad} V={v_sad}, "
                f"expected U={expected_u} V=0"
            )
        mutation_results.append(f"{field_name}/bit{bit}->0x{mutated_byte:02x}:U_SAD={u_sad}")

    baseline_kind = "strict" if mask in expected_full else f"short/{expected_short_signatures[mask]}"
    print(
        f"[PASS] CB_AC_PREFIX_BITFLIP mask=0x{mask:x} baseline={baseline_kind}; "
        f"slice-header fields match d0 08 08 6b layout with first CABAC byte 0xeb; "
        f"header-tail flips strict-decode ({', '.join(mutation_results)})"
    )

print("[PASS] CABAC P16x16 sparse Cb AC legacy prefix bitflip sweep now locks the d0 08 08 6b P-slice header field layout, the first CABAC payload byte as 0xeb, and the two header-tail flips that strict-decode all 15 Cb-only AC masks while preserving Cb-only SAD")
PY
