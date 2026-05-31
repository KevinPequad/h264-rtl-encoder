#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
export PATH=/home/chudpc/.local/verilator-5.020/bin:$PATH

BUILD_OUT="$(mktemp /tmp/h264_cabac_cr_ac_shape_probe_build.XXXXXX)"
python3 - <<'PY' > "$BUILD_OUT"
from scripts.rtl_runner import BuildConfig, build_sim, stage_workspace
workspace = stage_workspace('h264_cabac_cr_ac_shape_probe_')
config = BuildConfig(
    width=16,
    height=16,
    bit_depth=8,
    chroma_format_idc=1,
    jobs=1,
    enable_idr_ipcm=1,
    ipcm_sad_threshold=0,
    enable_cabac_p16x16=1,
)
print(build_sim(workspace, config))
PY
SIM="$(tail -1 "$BUILD_OUT")"
mkdir -p output/cabac_cr_ac_shape_probe data

python3 - "$SIM" <<'PY'
from pathlib import Path
import subprocess
import sys
import tempfile

sim = sys.argv[1]
root = Path.cwd()
width = height = 16
frame_size = width * height * 3 // 2
expected_bytes = frame_size * 2
chroma_size = width * height // 4
flat_chroma = bytes([128]) * chroma_size
y0 = bytes([64]) * (width * height)
y1 = bytes([64]) * (width * height)

PATTERNS = {
    "checker_odd": lambda x, y: (x + y) & 1,
    "checker_even": lambda x, y: ((x + y) & 1) ^ 1,
    "vert_left": lambda x, y: x < 2,
    "vert_right": lambda x, y: x >= 2,
    "horiz_top": lambda x, y: y < 2,
    "horiz_bottom": lambda x, y: y >= 2,
    "diag_main": lambda x, y: x == y,
    "diag_anti": lambda x, y: x + y == 3,
}
FIRST_CABAC_PAYLOAD = 0xEB
PROMOTED_PAYLOADS = (("queue_m8_payload_0x75", 0x75), ("bit7_payload_0x6b", 0x6B))

# Cr-only low-amplitude coefficient-shape controls stay strict-decodable across
# the checker/vertical/horizontal block lattice.  High-amplitude shapes expose a
# Cr residual-tail blocker similar to the newer Cb shape probe, but with a
# different pass/miss partition: two diagonal block-1/2 cases still strict-decode
# while the high-amplitude checker/axis cases remain one-frame misses.  The
# high-amplitude axis complements are explicitly locked too; left/right and
# top/bottom currently share exact tails/signatures per block, ruling out a
# simple axis-side polarity issue.  Locking the exact final P-slice tails keeps
# the next source repair focused on residual coefficient level/suffix/order
# arithmetic instead of reclassifying the common P-slice header/CABAC boundary.
CASES = [
    # block, pattern, test_name, cr_value, expect_full, short_signature, expected_final_slice, expected_v_sad
    (0, "checker_odd", "checker_odd", 133, True, "", "0000000141d008086beb2f99af", 40),
    (0, "checker_even", "checker_even", 133, True, "", "0000000141d008086beb2f99af", 40),
    (0, "vert_left", "vert_left", 133, True, "", "0000000141d008086beb2f", 40),
    (0, "vert_right", "vert_right", 133, True, "", "0000000141d008086beb2f", 40),
    (0, "horiz_top", "horiz_top", 133, True, "", "0000000141d008086beb2f99", 40),
    (0, "horiz_bottom", "horiz_bottom", 133, True, "", "0000000141d008086beb2f99", 40),
    (1, "checker_odd", "checker_odd", 133, True, "", "0000000141d008086beb2f9a24", 40),
    (1, "checker_even", "checker_even", 133, True, "", "0000000141d008086beb2f9a24", 40),
    (1, "vert_left", "vert_left", 133, True, "", "0000000141d008086beb2f", 40),
    (1, "vert_right", "vert_right", 133, True, "", "0000000141d008086beb2f", 40),
    (1, "horiz_top", "horiz_top", 133, True, "", "0000000141d008086beb2f", 40),
    (1, "horiz_bottom", "horiz_bottom", 133, True, "", "0000000141d008086beb2f", 40),
    (2, "checker_odd", "checker_odd", 133, True, "", "0000000141d008086beb2f9860", 40),
    (2, "checker_even", "checker_even", 133, True, "", "0000000141d008086beb2f9860", 40),
    (2, "vert_left", "vert_left", 133, True, "", "0000000141d008086beb2f", 40),
    (2, "vert_right", "vert_right", 133, True, "", "0000000141d008086beb2f", 40),
    (2, "horiz_top", "horiz_top", 133, True, "", "0000000141d008086beb2f", 40),
    (2, "horiz_bottom", "horiz_bottom", 133, True, "", "0000000141d008086beb2f", 40),
    (3, "checker_odd", "checker_odd", 133, True, "", "0000000141d008086beb2f9986", 40),
    (3, "checker_even", "checker_even", 133, True, "", "0000000141d008086beb2f9986", 40),
    (3, "vert_left", "vert_left", 133, True, "", "0000000141d008086beb2f99", 40),
    (3, "vert_right", "vert_right", 133, True, "", "0000000141d008086beb2f99", 40),
    (3, "horiz_top", "horiz_top", 133, True, "", "0000000141d008086beb2f99", 40),
    (3, "horiz_bottom", "horiz_bottom", 133, True, "", "0000000141d008086beb2f99", 40),
    (0, "diag_main", "diag_main_a32", 160, False, "bytestream -11", "0000000141d008086beb305034d1bdc9b5", None),
    (0, "diag_anti", "diag_anti_a32", 160, False, "bytestream -11", "0000000141d008086beb305034d1bdc9b6", None),
    (0, "checker_odd", "checker_odd_a32", 160, False, "bytestream -16", "0000000141d008086beb304ee10ab07a", None),
    (0, "checker_even", "checker_even_a32", 160, False, "bytestream -16", "0000000141d008086beb304ee10ab07a", None),
    (0, "vert_left", "vert_left_a32", 160, False, "bytestream -7", "0000000141d008086beb304ee10b9c", None),
    (0, "vert_right", "vert_right_a32", 160, False, "bytestream -7", "0000000141d008086beb304ee10b9c", None),
    (0, "horiz_top", "horiz_top_a32", 160, False, "bytestream -11", "0000000141d008086beb304ee109fd", None),
    (0, "horiz_bottom", "horiz_bottom_a32", 160, False, "bytestream -11", "0000000141d008086beb304ee109fd", None),
    (1, "diag_main", "diag_main_a32", 160, False, "bytestream -5", "0000000141d008086beb305071ccc95af9", None),
    (1, "diag_anti", "diag_anti_a32", 160, True, "", "0000000141d008086beb305071ccc95afa", 128),
    (1, "checker_odd", "checker_odd_a32", 160, False, "bytestream -11", "0000000141d008086beb304f4d7f2500", None),
    (1, "checker_even", "checker_even_a32", 160, False, "bytestream -11", "0000000141d008086beb304f4d7f2500", None),
    (1, "vert_left", "vert_left_a32", 160, False, "bytestream -10", "0000000141d008086beb304f4d7f", None),
    (1, "vert_right", "vert_right_a32", 160, False, "bytestream -10", "0000000141d008086beb304f4d7f", None),
    (1, "horiz_top", "horiz_top_a32", 160, False, "bytestream -9", "0000000141d008086beb304f4d7eac", None),
    (1, "horiz_bottom", "horiz_bottom_a32", 160, False, "bytestream -9", "0000000141d008086beb304f4d7eac", None),
    (2, "diag_main", "diag_main_a32", 160, True, "", "0000000141d008086beb305078818eb5", 128),
    (2, "diag_anti", "diag_anti_a32", 160, True, "", "0000000141d008086beb305078818eb57d", 128),
    (2, "checker_odd", "checker_odd_a32", 160, False, "bytestream -10", "0000000141d008086beb304f5ea96142", None),
    (2, "checker_even", "checker_even_a32", 160, False, "bytestream -10", "0000000141d008086beb304f5ea96142", None),
    (2, "vert_left", "vert_left_a32", 160, False, "bytestream -10", "0000000141d008086beb304f5ea9", None),
    (2, "vert_right", "vert_right_a32", 160, False, "bytestream -10", "0000000141d008086beb304f5ea9", None),
    (2, "horiz_top", "horiz_top_a32", 160, False, "bytestream -11", "0000000141d008086beb304f5ea917", None),
    (2, "horiz_bottom", "horiz_bottom_a32", 160, False, "bytestream -11", "0000000141d008086beb304f5ea917", None),
    (3, "diag_main", "diag_main_a32", 160, False, "bytestream -11", "0000000141d008086beb30503d7cb14c9b", None),
    (3, "diag_anti", "diag_anti_a32", 160, False, "bytestream -11", "0000000141d008086beb30503d7cb14c9b", None),
    (3, "checker_odd", "checker_odd_a32", 160, False, "bytestream -10", "0000000141d008086beb304efc1e8687", None),
    (3, "checker_even", "checker_even_a32", 160, False, "bytestream -10", "0000000141d008086beb304efc1e8687", None),
    (3, "vert_left", "vert_left_a32", 160, False, "bytestream -11", "0000000141d008086beb304efc1e95", None),
    (3, "vert_right", "vert_right_a32", 160, False, "bytestream -11", "0000000141d008086beb304efc1e95", None),
    (3, "horiz_top", "horiz_top_a32", 160, False, "bytestream -11", "0000000141d008086beb304efc1e7b", None),
    (3, "horiz_bottom", "horiz_bottom_a32", 160, False, "bytestream -11", "0000000141d008086beb304efc1e7b", None),
]


def make_fixture(block: int, pattern_name: str, test_name: str, cr_value: int) -> Path:
    bx = (block & 1) * 4
    by = (block >> 1) * 4
    cr = bytearray(flat_chroma)
    pattern = PATTERNS[pattern_name]
    for ly in range(4):
        for lx in range(4):
            if pattern(lx, ly):
                cr[(by + ly) * (width // 2) + (bx + lx)] = cr_value
    out = root / "data" / f"smoke_16x16_2f_cabac_p16x16_chroma_residual_cr_ac_shape_blk{block}_{test_name}.yuv"
    out.write_bytes(y0 + flat_chroma + flat_chroma + y1 + flat_chroma + bytes(cr))
    print(f"[INFO] CR_AC_SHAPE block={block} pattern={test_name} fixture {out.relative_to(root)} size={out.stat().st_size}")
    return out


def final_nal_hex(path: Path) -> str:
    data = path.read_bytes()
    starts = []
    offset = 0
    while True:
        pos = data.find(b"\x00\x00\x00\x01", offset)
        if pos < 0:
            break
        starts.append(pos)
        offset = pos + 4
    if not starts:
        raise SystemExit(f"[FAIL] CR_AC_SHAPE {path} has no Annex-B start code")
    return data[starts[-1]:].hex()


def first_payload_index(data: bytes, label: str) -> int:
    last_start = data.rfind(b"\x00\x00\x00\x01")
    if last_start < 0:
        raise SystemExit(f"[FAIL] CR_AC_SHAPE {label} has no final Annex-B start code")
    header_tail_idx = last_start + 8
    first_idx = last_start + 9
    if first_idx >= len(data):
        raise SystemExit(f"[FAIL] CR_AC_SHAPE {label} has no first CABAC payload byte")
    if data[header_tail_idx] != 0x6B:
        raise SystemExit(
            f"[FAIL] CR_AC_SHAPE {label} header-tail byte 0x{data[header_tail_idx]:02x}, expected 0x6b"
        )
    if data[first_idx] != FIRST_CABAC_PAYLOAD:
        raise SystemExit(
            f"[FAIL] CR_AC_SHAPE {label} first CABAC payload 0x{data[first_idx]:02x}, expected 0xeb"
        )
    return first_idx


def decode_h264_bytes(data: bytes) -> tuple[bytes, str]:
    with tempfile.NamedTemporaryFile(prefix="h264_cabac_cr_ac_shape_sub_", suffix=".h264", delete=False) as h264_tmp:
        h264_tmp.write(data)
        h264_path = Path(h264_tmp.name)
    with tempfile.NamedTemporaryFile(prefix="h264_cabac_cr_ac_shape_sub_", suffix=".yuv", delete=False) as raw_tmp:
        raw_path = Path(raw_tmp.name)
    try:
        proc = subprocess.run(
            ["ffmpeg", "-y", "-v", "error", "-xerror", "-i", str(h264_path), "-f", "rawvideo", "-pix_fmt", "yuv420p", str(raw_path)],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            check=False,
        )
        raw = raw_path.read_bytes() if raw_path.exists() else b""
        return raw, proc.stderr.decode("utf-8", "replace")
    finally:
        h264_path.unlink(missing_ok=True)
        raw_path.unlink(missing_ok=True)


def mutate_first_payload(data: bytes, first_idx: int, value: int) -> bytes:
    mutated = bytearray(data)
    mutated[first_idx] = value
    return bytes(mutated)


def pattern_pixel_count(pattern_name: str) -> int:
    pattern = PATTERNS[pattern_name]
    return sum(1 for ly in range(4) for lx in range(4) if pattern(lx, ly))


def assert_first_payload_substitutions(h264: Path, input_path: Path, block: int, pattern_name: str, test_name: str, cr_value: int) -> None:
    stream = h264.read_bytes()
    first_idx = first_payload_index(stream, f"block={block} pattern={test_name}")
    expected_v_sad = pattern_pixel_count(pattern_name) * abs(cr_value - 128)
    src = input_path.read_bytes()
    u0 = frame_size + width * height
    v0 = u0 + chroma_size
    for label, value in PROMOTED_PAYLOADS:
        raw, err = decode_h264_bytes(mutate_first_payload(stream, first_idx, value))
        if err.strip():
            raise SystemExit(f"[FAIL] CR_AC_SHAPE {label} block={block} pattern={test_name} FFmpeg log {err.strip()!r}")
        if len(raw) != expected_bytes:
            raise SystemExit(
                f"[FAIL] CR_AC_SHAPE {label} block={block} pattern={test_name} decoded {len(raw)}/{expected_bytes}"
            )
        if raw[:frame_size] != src[:frame_size]:
            raise SystemExit(f"[FAIL] CR_AC_SHAPE {label} block={block} pattern={test_name} changed IDR reference")
        u_sad = sum(abs(raw[u0 + i] - src[u0 + i]) for i in range(chroma_size))
        v_sad = sum(abs(raw[v0 + i] - src[v0 + i]) for i in range(chroma_size))
        if u_sad != 0 or v_sad != expected_v_sad:
            raise SystemExit(
                f"[FAIL] CR_AC_SHAPE {label} block={block} pattern={test_name} SAD U={u_sad} V={v_sad}, "
                f"expected U=0 V={expected_v_sad}"
            )
        print(
            f"[PASS] CR_AC_SHAPE {label} block={block} pattern={test_name} promotes/stays strict "
            f"at {len(raw)}/{expected_bytes} with exact Cr-only V_SAD={v_sad}"
        )


def extract_signature(text: str) -> str:
    if "bytestream -" in text:
        return "bytestream -" + text.split("bytestream -", 1)[1].split("\n", 1)[0]
    return text.strip().split("\n")[-1] if text.strip() else ""


for block, pattern_name, test_name, cr_value, expect_full, short_signature, expected_final_slice, expected_v_sad in CASES:
    input_path = make_fixture(block, pattern_name, test_name, cr_value)
    h264 = root / "output" / "cabac_cr_ac_shape_probe" / f"blk{block}_{test_name}.h264"
    sim_log = root / "output" / "cabac_cr_ac_shape_probe" / f"blk{block}_{test_name}.sim.log"
    ffmpeg_log = root / "output" / "cabac_cr_ac_shape_probe" / f"blk{block}_{test_name}.ffmpeg.log"
    raw_yuv = Path(f"/tmp/h264_cabac_cr_ac_shape_blk{block}_{test_name}.raw.yuv")

    with sim_log.open("w", encoding="utf-8") as log:
        subprocess.run(
            [sim, "+frames=2", "+timeout=5000000", f"+input={input_path}", f"+output={h264}", "+idr_interval=12"],
            cwd=root,
            stdout=log,
            stderr=subprocess.STDOUT,
            check=True,
        )
    sim_text = sim_log.read_text(errors="ignore")
    for needle in ("cabac_p16x16_mbs=1", "cabac_chroma_ac_mbs=1", "cr_ac_mbs=1", "cr_ac_blocks=1", "cb_ac_mbs=0", "cb_ac_blocks=0"):
        if needle not in sim_text:
            raise SystemExit(f"[FAIL] CR_AC_SHAPE block={block} pattern={test_name} sim log missing {needle}")

    with ffmpeg_log.open("w", encoding="utf-8") as log:
        subprocess.run(
            ["ffmpeg", "-y", "-v", "error", "-xerror", "-i", str(h264), "-f", "rawvideo", "-pix_fmt", "yuv420p", str(raw_yuv)],
            cwd=root,
            stdout=log,
            stderr=subprocess.STDOUT,
            check=False,
        )
    actual_bytes = raw_yuv.stat().st_size if raw_yuv.exists() else 0
    ff_text = ffmpeg_log.read_text(errors="ignore")
    final_slice = final_nal_hex(h264)
    if final_slice != expected_final_slice:
        raise SystemExit(
            f"[FAIL] CR_AC_SHAPE block={block} pattern={test_name} final slice changed: "
            f"got {final_slice}, expected {expected_final_slice}"
        )
    if not final_slice.startswith("0000000141d008086b"):
        raise SystemExit(f"[FAIL] CR_AC_SHAPE block={block} pattern={test_name} lost locked P-slice header/payload prefix in {final_slice}")
    if cr_value == 160:
        assert_first_payload_substitutions(h264, input_path, block, pattern_name, test_name, cr_value)

    if expect_full:
        if ff_text.strip():
            raise SystemExit(f"[FAIL] CR_AC_SHAPE block={block} pattern={test_name} expected clean FFmpeg log, got {ff_text.strip()!r}")
        if actual_bytes != expected_bytes:
            raise SystemExit(f"[FAIL] CR_AC_SHAPE block={block} pattern={test_name} decoded {actual_bytes}/{expected_bytes}, expected strict full decode")
        dec = raw_yuv.read_bytes()
        src = input_path.read_bytes()
        u0 = frame_size + width * height
        v0 = u0 + chroma_size
        u_sad = sum(abs(dec[u0 + i] - src[u0 + i]) for i in range(chroma_size))
        v_sad = sum(abs(dec[v0 + i] - src[v0 + i]) for i in range(chroma_size))
        if u_sad != 0 or v_sad != expected_v_sad:
            raise SystemExit(f"[FAIL] CR_AC_SHAPE block={block} pattern={test_name} expected Cr-only decoded delta U_SAD=0 V_SAD={expected_v_sad}, got U_SAD={u_sad} V_SAD={v_sad}")
        print(f"[PASS] CR_AC_SHAPE block={block} pattern={test_name} strict-decodes {actual_bytes}/{expected_bytes} final_slice={final_slice} with exact Cr-only V_SAD={v_sad}")
    else:
        if actual_bytes != frame_size:
            raise SystemExit(f"[FAIL] CR_AC_SHAPE block={block} pattern={test_name} decoded {actual_bytes}/{expected_bytes}, expected one-frame miss")
        signature = extract_signature(ff_text)
        if short_signature not in signature:
            raise SystemExit(
                f"[FAIL] CR_AC_SHAPE block={block} pattern={test_name} expected FFmpeg signature "
                f"{short_signature!r}, got {ff_text.strip()!r}"
            )
        print(f"[PASS] CR_AC_SHAPE block={block} pattern={test_name} remains one-frame miss {actual_bytes}/{expected_bytes} final_slice={final_slice} with FFmpeg signature {short_signature}")

    raw_yuv.unlink(missing_ok=True)

print("[PASS] CABAC P16x16 Cr-only chroma AC shape probe locks low-amplitude checker/axis strict decodes plus high-amplitude checker/axis-complement/diagonal strict-miss partition with exact final-slice tails and first-payload substitution promotion/stability; repair target remains scoped CABAC first-payload/residual-tail arithmetic rather than CBF selector, axis-side polarity, or P-slice-boundary handling")
PY
