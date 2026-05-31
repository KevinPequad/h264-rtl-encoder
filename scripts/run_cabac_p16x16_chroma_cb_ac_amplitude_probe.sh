#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
export PATH=/home/chudpc/.local/verilator-5.020/bin:$PATH

BUILD_OUT="$(mktemp /tmp/h264_cabac_cb_ac_amplitude_probe_build.XXXXXX)"
python3 - <<'PY' > "$BUILD_OUT"
from scripts.rtl_runner import BuildConfig, build_sim, stage_workspace
workspace = stage_workspace('h264_cabac_cb_ac_amplitude_probe_')
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
mkdir -p output/cabac_cb_ac_amplitude_probe data

python3 - "$SIM" <<'PY'
from pathlib import Path
import subprocess
import sys

sim = sys.argv[1]
root = Path.cwd()
width = height = 16
frame_size = width * height * 3 // 2
expected_bytes = frame_size * 2
chroma_size = (width // 2) * (height // 2)
flat_chroma = bytes([128]) * chroma_size
y0 = bytes([64]) * (width * height)
y1 = bytes([64]) * (width * height)

# Post-cod_i_queue=-7 promotion gate for sparse Cb singleton amplitude.
# A +4 checker perturbation still quantizes below the chroma-AC emission
# threshold and full-decodes as a no-AC control with the expected Cb mismatch.
# The first nonzero residual step (+5) and +8 now strict-decode for every Cb AC
# block with exact Cb-only SAD under the d0 08 08 6b 3a... payload prefix.
CASES = [
    # block, amplitude, expect_ac, expected U SAD, exact final P-slice
    (0, 4, False, 32, "0000000141d008086b"),
    (1, 4, False, 32, "0000000141d008086b"),
    (2, 4, False, 32, "0000000141d008086b"),
    (3, 4, False, 32, "0000000141d008086b"),
    (0, 5, True, 40, "0000000141d008086b3acbb489"),
    (1, 5, True, 40, "0000000141d008086b3acbdad7"),
    (2, 5, True, 40, "0000000141d008086b3acbe875"),
    (3, 5, True, 40, "0000000141d008086b3acbf17e"),
    (0, 8, True, 64, "0000000141d008086b3acbb489"),
    (1, 8, True, 64, "0000000141d008086b3acbdad7"),
    (2, 8, True, 64, "0000000141d008086b3acbe875"),
    (3, 8, True, 64, "0000000141d008086b3acbf17e"),
]


def make_fixture(block: int, amp: int) -> Path:
    bx = (block & 1) * 4
    by = (block >> 1) * 4
    cb = []
    for y in range(height // 2):
        for x in range(width // 2):
            if bx <= x < bx + 4 and by <= y < by + 4 and ((x + y) & 1):
                cb.append(128 + amp)
            else:
                cb.append(128)
    out = root / "data" / f"smoke_16x16_2f_cabac_p16x16_chroma_residual_cb_ac_amp_blk{block}_a{amp}.yuv"
    out.write_bytes(y0 + flat_chroma + flat_chroma + y1 + bytes(cb) + flat_chroma)
    print(f"[INFO] CB_AC_AMP block={block} amp={amp} fixture {out.relative_to(root)} size={out.stat().st_size}")
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
        raise SystemExit(f"[FAIL] CB_AC_AMP {path} has no Annex-B start code")
    return data[starts[-1]:].hex()


for block, amp, expect_ac, expected_u_sad, expected_final_slice in CASES:
    input_path = make_fixture(block, amp)
    h264 = root / "output" / "cabac_cb_ac_amplitude_probe" / f"blk{block}_amp{amp}.h264"
    sim_log = root / "output" / "cabac_cb_ac_amplitude_probe" / f"blk{block}_amp{amp}.sim.log"
    ffmpeg_log = root / "output" / "cabac_cb_ac_amplitude_probe" / f"blk{block}_amp{amp}.ffmpeg.log"
    raw_yuv = Path(f"/tmp/h264_cabac_cb_ac_amp_blk{block}_a{amp}.raw.yuv")

    with sim_log.open("w", encoding="utf-8") as log:
        subprocess.run(
            [sim, "+frames=2", "+timeout=5000000", f"+input={input_path}", f"+output={h264}", "+idr_interval=12"],
            cwd=root,
            stdout=log,
            stderr=subprocess.STDOUT,
            check=True,
        )
    sim_text = sim_log.read_text(errors="ignore")
    if "cabac_p16x16_mbs=1" not in sim_text:
        raise SystemExit(f"[FAIL] CB_AC_AMP block={block} amp={amp} did not exercise integrated CABAC P16x16")
    expected_needles = (
        ("cb_ac_mbs=1", "cabac_chroma_ac_mbs=1", "cb_ac_blocks=1", "cr_ac_mbs=0", "cr_ac_blocks=0")
        if expect_ac
        else ("cb_ac_mbs=0", "cabac_chroma_ac_mbs=0", "cb_ac_blocks=0", "cr_ac_mbs=0", "cr_ac_blocks=0")
    )
    for needle in expected_needles:
        if needle not in sim_text:
            raise SystemExit(f"[FAIL] CB_AC_AMP block={block} amp={amp} sim log missing {needle}")

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
        raise SystemExit(f"[FAIL] CB_AC_AMP block={block} amp={amp} expected clean FFmpeg log, got {ff_text.strip()!r}")
    actual_bytes = raw_yuv.stat().st_size if raw_yuv.exists() else 0
    if actual_bytes != expected_bytes:
        raise SystemExit(f"[FAIL] CB_AC_AMP block={block} amp={amp} decoded {actual_bytes}/{expected_bytes}, expected strict full decode")

    final_slice = final_nal_hex(h264)
    if final_slice != expected_final_slice:
        raise SystemExit(
            f"[FAIL] CB_AC_AMP block={block} amp={amp} final slice changed: "
            f"got {final_slice}, expected {expected_final_slice}"
        )
    if expect_ac and not final_slice.startswith("0000000141d008086b3a"):
        raise SystemExit(f"[FAIL] CB_AC_AMP block={block} amp={amp} lost post-queue-init payload prefix in {final_slice}")

    dec = raw_yuv.read_bytes()
    src = input_path.read_bytes()
    if dec[:frame_size] != src[:frame_size]:
        raise SystemExit(f"[FAIL] CB_AC_AMP block={block} amp={amp} changed IDR reference")
    u0 = frame_size + width * height
    v0 = u0 + chroma_size
    u_sad = sum(abs(dec[u0 + i] - src[u0 + i]) for i in range(chroma_size))
    v_sad = sum(abs(dec[v0 + i] - src[v0 + i]) for i in range(chroma_size))
    if u_sad != expected_u_sad or v_sad != 0:
        raise SystemExit(
            f"[FAIL] CB_AC_AMP block={block} amp={amp} SAD U={u_sad} V={v_sad}, "
            f"expected U={expected_u_sad} V=0"
        )
    if expect_ac:
        print(
            f"[PASS] CB_AC_AMP block={block} amp={amp} strict-decodes {actual_bytes}/{expected_bytes} "
            f"final_slice={final_slice} with exact Cb-only U_SAD={u_sad}"
        )
    else:
        print(
            f"[PASS] CB_AC_AMP block={block} amp={amp} remains a no-AC full-decode control "
            f"final_slice={final_slice} with expected Cb-only U_SAD={u_sad}"
        )
    raw_yuv.unlink(missing_ok=True)

print("[PASS] CABAC P16x16 sparse Cb AC amplitude gate promoted post-cod_i_queue=-7: +4 no-AC controls and +5/+8 Cb AC blocks all strict-decode two FFmpeg frames with exact Cb-only SAD and locked final P-slice tails")
PY
