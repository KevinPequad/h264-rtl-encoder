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

sim = sys.argv[1]
root = Path.cwd()
width = height = 16
frame_size = width * height * 3 // 2
expected_bytes = frame_size * 2
chroma_size = width * height // 4
flat_chroma = bytes([128]) * chroma_size
y0 = bytes([64]) * (width * height)
y1 = bytes([64]) * (width * height)

# Post-cod_i_queue=-7 promotion gate for Cr-only chroma AC coefficient shapes.
# The prior diagnostic locked low-amplitude strict controls plus a high-amplitude
# strict/miss partition under the d0 08 08 6b eb prefix.  The checked-in CABAC
# core now emits plane-safe Cr tails under d0 08 08 6b 3a..., so every bounded
# low-amplitude and high-amplitude Cr shape below must strict-decode two FFmpeg
# frames with byte-identical IDR and exact Cr-only second-frame SAD.
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

# block, pattern source, test name, Cr sample value, expected V SAD, exact final P-slice
CASES = [
    (0, "checker_odd", "checker_odd", 133, 40, "0000000141d008086b3acbe66b"),
    (0, "checker_even", "checker_even", 133, 40, "0000000141d008086b3acbe66b"),
    (0, "vert_left", "vert_left", 133, 40, "0000000141d008086b3acbe6"),
    (0, "vert_right", "vert_right", 133, 40, "0000000141d008086b3acbe6"),
    (0, "horiz_top", "horiz_top", 133, 40, "0000000141d008086b3acbe6"),
    (0, "horiz_bottom", "horiz_bottom", 133, 40, "0000000141d008086b3acbe6"),
    (1, "checker_odd", "checker_odd", 133, 40, "0000000141d008086b3acbe689"),
    (1, "checker_even", "checker_even", 133, 40, "0000000141d008086b3acbe689"),
    (1, "vert_left", "vert_left", 133, 40, "0000000141d008086b3acbe6"),
    (1, "vert_right", "vert_right", 133, 40, "0000000141d008086b3acbe6"),
    (1, "horiz_top", "horiz_top", 133, 40, "0000000141d008086b3acbe6"),
    (1, "horiz_bottom", "horiz_bottom", 133, 40, "0000000141d008086b3acbe6"),
    (2, "checker_odd", "checker_odd", 133, 40, "0000000141d008086b3acbe618"),
    (2, "checker_even", "checker_even", 133, 40, "0000000141d008086b3acbe618"),
    (2, "vert_left", "vert_left", 133, 40, "0000000141d008086b3acbe6"),
    (2, "vert_right", "vert_right", 133, 40, "0000000141d008086b3acbe6"),
    (2, "horiz_top", "horiz_top", 133, 40, "0000000141d008086b3acbe6"),
    (2, "horiz_bottom", "horiz_bottom", 133, 40, "0000000141d008086b3acbe6"),
    (3, "checker_odd", "checker_odd", 133, 40, "0000000141d008086b3acbe661"),
    (3, "checker_even", "checker_even", 133, 40, "0000000141d008086b3acbe661"),
    (3, "vert_left", "vert_left", 133, 40, "0000000141d008086b3acbe6"),
    (3, "vert_right", "vert_right", 133, 40, "0000000141d008086b3acbe6"),
    (3, "horiz_top", "horiz_top", 133, 40, "0000000141d008086b3acbe6"),
    (3, "horiz_bottom", "horiz_bottom", 133, 40, "0000000141d008086b3acbe6"),
    (0, "diag_main", "diag_main_a32", 160, 128, "0000000141d008086b3acc140d346f726d"),
    (0, "diag_anti", "diag_anti_a32", 160, 128, "0000000141d008086b3acc140d346f726d"),
    (1, "diag_main", "diag_main_a32", 160, 128, "0000000141d008086b3acc141c733256be"),
    (1, "diag_anti", "diag_anti_a32", 160, 128, "0000000141d008086b3acc141c733256be"),
    (2, "diag_main", "diag_main_a32", 160, 128, "0000000141d008086b3acc141e2063ad5f"),
    (2, "diag_anti", "diag_anti_a32", 160, 128, "0000000141d008086b3acc141e2063ad5f"),
    (3, "diag_main", "diag_main_a32", 160, 128, "0000000141d008086b3acc140f5f2c5326"),
    (3, "diag_anti", "diag_anti_a32", 160, 128, "0000000141d008086b3acc140f5f2c5326"),
    (0, "checker_odd", "checker_odd_a32", 160, 256, "0000000141d008086b3acc13b842ac1e"),
    (0, "checker_even", "checker_even_a32", 160, 256, "0000000141d008086b3acc13b842ac1e"),
    (1, "checker_odd", "checker_odd_a32", 160, 256, "0000000141d008086b3acc13d35fc940"),
    (1, "checker_even", "checker_even_a32", 160, 256, "0000000141d008086b3acc13d35fc940"),
    (2, "checker_odd", "checker_odd_a32", 160, 256, "0000000141d008086b3acc13d7aa5850"),
    (2, "checker_even", "checker_even_a32", 160, 256, "0000000141d008086b3acc13d7aa5850"),
    (3, "checker_odd", "checker_odd_a32", 160, 256, "0000000141d008086b3acc13bf07a1a1"),
    (3, "checker_even", "checker_even_a32", 160, 256, "0000000141d008086b3acc13bf07a1a1"),
    (0, "vert_left", "vert_left_a32", 160, 256, "0000000141d008086b3acc13b842e7"),
    (0, "vert_right", "vert_right_a32", 160, 256, "0000000141d008086b3acc13b842e7"),
    (0, "horiz_top", "horiz_top_a32", 160, 256, "0000000141d008086b3acc13b8427f"),
    (0, "horiz_bottom", "horiz_bottom_a32", 160, 256, "0000000141d008086b3acc13b8427f"),
    (1, "vert_left", "vert_left_a32", 160, 256, "0000000141d008086b3acc13d35ff2"),
    (1, "vert_right", "vert_right_a32", 160, 256, "0000000141d008086b3acc13d35ff2"),
    (1, "horiz_top", "horiz_top_a32", 160, 256, "0000000141d008086b3acc13d35fab"),
    (1, "horiz_bottom", "horiz_bottom_a32", 160, 256, "0000000141d008086b3acc13d35fab"),
    (2, "vert_left", "vert_left_a32", 160, 256, "0000000141d008086b3acc13d7aa6f"),
    (2, "vert_right", "vert_right_a32", 160, 256, "0000000141d008086b3acc13d7aa6f"),
    (2, "horiz_top", "horiz_top_a32", 160, 256, "0000000141d008086b3acc13d7aa45"),
    (2, "horiz_bottom", "horiz_bottom_a32", 160, 256, "0000000141d008086b3acc13d7aa45"),
    (3, "vert_left", "vert_left_a32", 160, 256, "0000000141d008086b3acc13bf07a5"),
    (3, "vert_right", "vert_right_a32", 160, 256, "0000000141d008086b3acc13bf07a5"),
    (3, "horiz_top", "horiz_top_a32", 160, 256, "0000000141d008086b3acc13bf079e"),
    (3, "horiz_bottom", "horiz_bottom_a32", 160, 256, "0000000141d008086b3acc13bf079e"),
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


for block, pattern_name, test_name, cr_value, expected_v_sad, expected_final_slice in CASES:
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
    ff_text = ffmpeg_log.read_text(errors="ignore")
    if ff_text.strip():
        raise SystemExit(f"[FAIL] CR_AC_SHAPE block={block} pattern={test_name} expected clean FFmpeg log, got {ff_text.strip()!r}")
    actual_bytes = raw_yuv.stat().st_size if raw_yuv.exists() else 0
    if actual_bytes != expected_bytes:
        raise SystemExit(f"[FAIL] CR_AC_SHAPE block={block} pattern={test_name} decoded {actual_bytes}/{expected_bytes}, expected strict full decode")
    final_slice = final_nal_hex(h264)
    if final_slice != expected_final_slice:
        raise SystemExit(
            f"[FAIL] CR_AC_SHAPE block={block} pattern={test_name} final slice changed: "
            f"got {final_slice}, expected {expected_final_slice}"
        )
    if not final_slice.startswith("0000000141d008086b3a"):
        raise SystemExit(
            f"[FAIL] CR_AC_SHAPE block={block} pattern={test_name} lost post-queue-init "
            f"P-slice header/tail prefix in {final_slice}"
        )

    dec = raw_yuv.read_bytes()
    src = input_path.read_bytes()
    if dec[:frame_size] != src[:frame_size]:
        raise SystemExit(f"[FAIL] CR_AC_SHAPE block={block} pattern={test_name} changed IDR reference")
    u0 = frame_size + width * height
    v0 = u0 + chroma_size
    u_sad = sum(abs(dec[u0 + i] - src[u0 + i]) for i in range(chroma_size))
    v_sad = sum(abs(dec[v0 + i] - src[v0 + i]) for i in range(chroma_size))
    if u_sad != 0 or v_sad != expected_v_sad:
        raise SystemExit(
            f"[FAIL] CR_AC_SHAPE block={block} pattern={test_name} SAD U={u_sad} V={v_sad}, "
            f"expected U=0 V={expected_v_sad}"
        )
    print(
        f"[PASS] CR_AC_SHAPE block={block} pattern={test_name} strict-decodes {actual_bytes}/{expected_bytes} "
        f"final_slice={final_slice} with exact Cr-only V_SAD={v_sad}"
    )
    raw_yuv.unlink(missing_ok=True)

print("[PASS] CABAC P16x16 Cr-only chroma-AC shape gate promoted post-cod_i_queue=-7: low-amplitude checker/axis shapes and high-amplitude checker/axis/diagonal shapes all strict-decode two FFmpeg frames with exact Cr-only SAD and locked final P-slice tails")
PY
