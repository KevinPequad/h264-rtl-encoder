#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
export PATH=/home/chudpc/.local/verilator-5.020/bin:$PATH

BUILD_OUT="$(mktemp /tmp/h264_cabac_cb_ac_shape_probe_build.XXXXXX)"
python3 - <<'PY' > "$BUILD_OUT"
from scripts.rtl_runner import BuildConfig, build_sim, stage_workspace
workspace = stage_workspace('h264_cabac_cb_ac_shape_probe_')
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
mkdir -p output/cabac_cb_ac_shape_probe data

python3 - "$SIM" <<'PY'
from pathlib import Path
import subprocess
import sys

sim = sys.argv[1]
root = Path.cwd()
width = height = 16
frame_size = width * height * 3 // 2
expected_bytes = frame_size * 2
chroma_size = width * height // 4
flat_chroma = bytes([128]) * chroma_size
y0 = bytes([64]) * (width * height)
y1 = bytes([64]) * (width * height)

# All cases use the first nonzero quantized AC step (+5) that the amplitude
# probe already locked.  This narrows the blocker from "top-row sparse Cb AC"
# to the residual coefficient shape/order itself: some top-row Cb AC shapes
# strict-decode, and some bottom-row shapes can still short-decode.
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
CASES = [
    # block, pattern, expect_full_decode, short FFmpeg signature when not full,
    # exact current final P-slice hex.  All cases share the locked
    # d0 08 08 6b header tail and first residual payload byte eb when the
    # quantized AC residual is nonzero; the strict vs miss partition is in the
    # following residual tail, not a one-byte header or payload-boundary
    # classification artifact.  The complementary checker parities plus a
    # complete vertical/horizontal sweep across all four Cb AC blocks lock that
    # the remaining short-decodes are coefficient-shape/tail sensitive, not
    # simply top-vs-bottom or left-vs-right block placement and not uniformly
    # checker-parity driven.
    (0, "checker_odd", False, "bytestream -19", "0000000141d008086beb2ed226"),
    (0, "checker_even", False, "bytestream -19", "0000000141d008086beb2ed226"),
    (0, "vert_left", True, "", "0000000141d008086beb2f"),
    (0, "vert_right", True, "", "0000000141d008086beb2f"),
    (0, "horiz_top", False, "bytestream -23", "0000000141d008086beb2e"),
    (0, "horiz_bottom", False, "bytestream -23", "0000000141d008086beb2e"),
    (1, "checker_odd", False, "bytestream -21", "0000000141d008086beb2f6b5d"),
    (1, "checker_even", False, "bytestream -21", "0000000141d008086beb2f6b5d"),
    (1, "vert_left", True, "", "0000000141d008086beb2f"),
    (1, "vert_right", True, "", "0000000141d008086beb2f"),
    (1, "horiz_top", True, "", "0000000141d008086beb2f"),
    (1, "horiz_bottom", True, "", "0000000141d008086beb2f"),
    (2, "checker_odd", True, "", "0000000141d008086beb2fa1d5"),
    (2, "checker_even", False, "bytestream -5", "0000000141d008086beb2fa1d4"),
    (2, "vert_left", True, "", "0000000141d008086beb2f"),
    (2, "vert_right", True, "", "0000000141d008086beb2f"),
    (2, "horiz_top", True, "", "0000000141d008086beb2f"),
    (2, "horiz_bottom", True, "", "0000000141d008086beb2f"),
    (3, "checker_odd", True, "", "0000000141d008086beb2fc5f8"),
    (3, "checker_even", True, "", "0000000141d008086beb2fc5f8"),
    (3, "vert_left", False, "bytestream -6", "0000000141d008086beb2fc7"),
    (3, "vert_right", False, "bytestream -6", "0000000141d008086beb2fc7"),
    (3, "horiz_top", False, "bytestream -18", "0000000141d008086beb2fc5"),
    (3, "horiz_bottom", False, "bytestream -18", "0000000141d008086beb2fc5"),
]

# Diagonal +5 samples quantize below the current Cb-AC emission threshold and
# collapse to the no-residual CABAC P-slice tail.  Use the already-probed +32
# chroma step for diagonal and axis-shape locks so this diagnostic distinguishes
# coefficient shape/order/arithmetic-tail failures from the low-amplitude
# quantizer cutoff.  The +32 axis cases are especially useful because their +5
# counterparts include several strict-decode passes; at higher amplitude all
# checker/diagonal/axis shapes now short-decode, so the remaining blocker is
# tied to multi-bin level/suffix emission rather than only sparse CBF context
# selection or the low-amplitude checker parity partition.
DIAG32_CASES = [
    (0, "diag_main", False, "bytestream -15", "0000000141d008086beb31d8697707c50a"),
    (0, "diag_anti", False, "bytestream -15", "0000000141d008086beb31d8697707c53d"),
    (1, "diag_main", False, "bytestream -11", "0000000141d008086beb31d8e37a23e285"),
    (1, "diag_anti", False, "bytestream -15", "0000000141d008086beb31d8e37a23e29e"),
    (2, "diag_main", False, "bytestream -11", "0000000141d008086beb31d8f0eab89b5f"),
    (2, "diag_anti", False, "bytestream -17", "0000000141d008086beb31d8f0eab89b6f"),
    (3, "diag_main", False, "bytestream -13", "0000000141d008086beb31d87ae4c8b5f3"),
    (3, "diag_anti", False, "bytestream -15", "0000000141d008086beb31d87ae4c8b5f4"),
]
CHECKER32_CASES = [
    (0, "checker_odd", False, "bytestream -32", "0000000141d008086beb31d5c0504295"),
    (0, "checker_even", False, "bytestream -20", "0000000141d008086beb31d5c0504292"),
    (1, "checker_odd", False, "bytestream -28", "0000000141d008086beb31d699eb0f53"),
    (1, "checker_even", False, "bytestream -26", "0000000141d008086beb31d699eb0f52"),
    (2, "checker_odd", False, "bytestream -20", "0000000141d008086beb31d6bc810002"),
    (2, "checker_even", False, "bytestream -14", "0000000141d008086beb31d6bc810001"),
    (3, "checker_odd", False, "bytestream -22", "0000000141d008086beb31d5f79710f5"),
    (3, "checker_even", False, "bytestream -22", "0000000141d008086beb31d5f79710f5"),
]
AXIS32_CASES = [
    (0, "vert_left", False, "bytestream -20", "0000000141d008086beb31d5c0ac"),
    (0, "vert_right", False, "bytestream -20", "0000000141d008086beb31d5c0ac"),
    (0, "horiz_top", False, "bytestream -21", "0000000141d008086beb31d5c008ac"),
    (0, "horiz_bottom", False, "bytestream -17", "0000000141d008086beb31d5c008a0"),
    (1, "vert_left", False, "bytestream -27", "0000000141d008086beb31d69a089c"),
    (1, "vert_right", False, "bytestream -31", "0000000141d008086beb31d69a0897"),
    (1, "horiz_top", False, "bytestream -26", "0000000141d008086beb31d699cf"),
    (1, "horiz_bottom", False, "bytestream -26", "0000000141d008086beb31d699cf"),
    (2, "vert_left", False, "bytestream -18", "0000000141d008086beb31d6bc93"),
    (2, "vert_right", False, "bytestream -18", "0000000141d008086beb31d6bc93"),
    (2, "horiz_top", False, "bytestream -16", "0000000141d008086beb31d6bc73"),
    (2, "horiz_bottom", False, "bytestream -16", "0000000141d008086beb31d6bc73"),
    (3, "vert_left", False, "bytestream -27", "0000000141d008086beb31d5f798e9"),
    (3, "vert_right", False, "bytestream -27", "0000000141d008086beb31d5f798e9"),
    (3, "horiz_top", False, "bytestream -19", "0000000141d008086beb31d5f795ab"),
    (3, "horiz_bottom", False, "bytestream -19", "0000000141d008086beb31d5f795ab"),
]
ALL_CASES = [
    (block, pattern_name, pattern_name, 133, expect_full, short_signature, expected_final_slice)
    for block, pattern_name, expect_full, short_signature, expected_final_slice in CASES
] + [
    (block, pattern_name, f"{pattern_name}_a32", 160, expect_full, short_signature, expected_final_slice)
    for block, pattern_name, expect_full, short_signature, expected_final_slice in DIAG32_CASES
] + [
    (block, pattern_name, f"{pattern_name}_a32", 160, expect_full, short_signature, expected_final_slice)
    for block, pattern_name, expect_full, short_signature, expected_final_slice in CHECKER32_CASES
] + [
    (block, pattern_name, f"{pattern_name}_a32", 160, expect_full, short_signature, expected_final_slice)
    for block, pattern_name, expect_full, short_signature, expected_final_slice in AXIS32_CASES
]


def make_fixture(block: int, pattern_name: str, test_name: str, cb_value: int) -> Path:
    bx = (block & 1) * 4
    by = (block >> 1) * 4
    cb = bytearray(flat_chroma)
    pattern = PATTERNS[pattern_name]
    for ly in range(4):
        for lx in range(4):
            if pattern(lx, ly):
                cb[(by + ly) * (width // 2) + (bx + lx)] = cb_value
    out = root / "data" / f"smoke_16x16_2f_cabac_p16x16_chroma_residual_cb_ac_shape_blk{block}_{test_name}.yuv"
    out.write_bytes(y0 + flat_chroma + flat_chroma + y1 + bytes(cb) + flat_chroma)
    print(f"[INFO] CB_AC_SHAPE block={block} pattern={test_name} fixture {out.relative_to(root)} size={out.stat().st_size}")
    return out


def extract_signature(text: str) -> str:
    if "bytestream -" in text:
        return "bytestream -" + text.split("bytestream -", 1)[1].split("\n", 1)[0]
    return text.strip().split("\n")[-1] if text.strip() else ""


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
        raise SystemExit(f"[FAIL] CB_AC_SHAPE {path} has no Annex-B start code")
    return data[starts[-1]:].hex()


for block, pattern_name, test_name, cb_value, expect_full, short_signature, expected_final_slice in ALL_CASES:
    input_path = make_fixture(block, pattern_name, test_name, cb_value)
    h264 = root / "output" / "cabac_cb_ac_shape_probe" / f"blk{block}_{test_name}.h264"
    sim_log = root / "output" / "cabac_cb_ac_shape_probe" / f"blk{block}_{test_name}.sim.log"
    ffmpeg_log = root / "output" / "cabac_cb_ac_shape_probe" / f"blk{block}_{test_name}.ffmpeg.log"
    raw_yuv = Path(f"/tmp/h264_cabac_cb_ac_shape_blk{block}_{test_name}.raw.yuv")

    with sim_log.open("w", encoding="utf-8") as log:
        subprocess.run(
            [sim, "+frames=2", "+timeout=5000000", f"+input={input_path}", f"+output={h264}", "+idr_interval=12"],
            cwd=root,
            stdout=log,
            stderr=subprocess.STDOUT,
            check=True,
        )
    sim_text = sim_log.read_text(errors="ignore")
    for needle in ("cabac_p16x16_mbs=1", "cabac_chroma_ac_mbs=1", "cb_ac_mbs=1", "cb_ac_blocks=1", "cr_ac_mbs=0", "cr_ac_blocks=0"):
        if needle not in sim_text:
            raise SystemExit(f"[FAIL] CB_AC_SHAPE block={block} pattern={test_name} sim log missing {needle}")

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
            f"[FAIL] CB_AC_SHAPE block={block} pattern={test_name} final slice changed: "
            f"got {final_slice}, expected {expected_final_slice}"
        )
    if not final_slice.startswith("0000000141d008086beb"):
        raise SystemExit(
            f"[FAIL] CB_AC_SHAPE block={block} pattern={test_name} lost locked "
            f"P-slice header tail / first residual byte in {final_slice}"
        )

    if expect_full:
        if ff_text.strip():
            raise SystemExit(f"[FAIL] CB_AC_SHAPE block={block} pattern={test_name} expected clean FFmpeg log, got {ff_text.strip()!r}")
        if actual_bytes != expected_bytes:
            raise SystemExit(f"[FAIL] CB_AC_SHAPE block={block} pattern={test_name} decoded {actual_bytes}/{expected_bytes}, expected strict full decode")
        dec = raw_yuv.read_bytes()
        src = input_path.read_bytes()
        u0 = frame_size + width * height
        v0 = u0 + chroma_size
        u_sad = sum(abs(dec[u0 + i] - src[u0 + i]) for i in range(chroma_size))
        v_sad = sum(abs(dec[v0 + i] - src[v0 + i]) for i in range(chroma_size))
        if u_sad == 0 or v_sad != 0:
            raise SystemExit(f"[FAIL] CB_AC_SHAPE block={block} pattern={test_name} expected Cb-only decoded delta, got U_SAD={u_sad} V_SAD={v_sad}")
        print(f"[PASS] CB_AC_SHAPE block={block} pattern={test_name} strict-decodes {actual_bytes}/{expected_bytes} final_slice={final_slice} with Cb-only U_SAD={u_sad}")
    else:
        if actual_bytes != frame_size:
            raise SystemExit(f"[FAIL] CB_AC_SHAPE block={block} pattern={test_name} decoded {actual_bytes}/{expected_bytes}, expected one-frame miss")
        signature = extract_signature(ff_text)
        if short_signature not in signature:
            raise SystemExit(
                f"[FAIL] CB_AC_SHAPE block={block} pattern={test_name} expected FFmpeg signature "
                f"{short_signature!r}, got {ff_text.strip()!r}"
            )
        print(f"[PASS] CB_AC_SHAPE block={block} pattern={test_name} remains one-frame miss {actual_bytes}/{expected_bytes} final_slice={final_slice} with FFmpeg signature {short_signature}")

    raw_yuv.unlink(missing_ok=True)

print("[PASS] CABAC P16x16 sparse Cb AC shape probe locks coefficient-shape-sensitive strict/miss partition, exact final-slice tails, and high-amplitude checker/diagonal/axis all-miss signatures under common first payload byte eb; repair target is residual coefficient level/suffix emission/order/arithmetic tail, not only top-row block placement, sparse CBF context selection, low-amplitude checker parity, or the P-slice boundary")
PY
