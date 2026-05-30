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
flat_chroma = bytes([128]) * ((width // 2) * (height // 2))
y0 = bytes([64]) * (width * height)
y1 = bytes([64]) * (width * height)

# Lock the threshold around the sparse Cb singleton blocker.  A +4 checker
# perturbation is quantized out and must stay a no-AC full-decode control.  The
# first non-zero residual step (+5) already reproduces the top-row short-decode
# miss, while the same bottom-row singleton blocks strict-decode at +5/+8.
CASES = [
    # block, amplitude, expect_ac, expect_full, expected FFmpeg signature when short
    (0, 4, False, True, ""),
    (1, 4, False, True, ""),
    (2, 4, False, True, ""),
    (3, 4, False, True, ""),
    (0, 5, True, False, "bytestream -19"),
    (1, 5, True, False, "bytestream -21"),
    (2, 5, True, True, ""),
    (3, 5, True, True, ""),
    (0, 8, True, False, "bytestream -19"),
    (1, 8, True, False, "bytestream -21"),
    (2, 8, True, True, ""),
    (3, 8, True, True, ""),
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

for block, amp, expect_ac, expect_full, short_signature in CASES:
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
    actual_bytes = raw_yuv.stat().st_size if raw_yuv.exists() else 0
    ff_text = ffmpeg_log.read_text(errors="ignore")

    if expect_full:
        if ff_text.strip():
            raise SystemExit(f"[FAIL] CB_AC_AMP block={block} amp={amp} expected clean FFmpeg log, got {ff_text.strip()!r}")
        if actual_bytes != expected_bytes:
            raise SystemExit(f"[FAIL] CB_AC_AMP block={block} amp={amp} decoded {actual_bytes}/{expected_bytes}, expected strict full decode")
        if expect_ac:
            src = input_path.read_bytes()
            dec = raw_yuv.read_bytes()
            u0 = frame_size + width * height
            v0 = u0 + width * height // 4
            chroma_size = width * height // 4
            u_sad = sum(abs(dec[u0 + i] - src[u0 + i]) for i in range(chroma_size))
            v_sad = sum(abs(dec[v0 + i] - src[v0 + i]) for i in range(chroma_size))
            if u_sad == 0 or v_sad != 0:
                raise SystemExit(f"[FAIL] CB_AC_AMP block={block} amp={amp} expected Cb-only decoded delta, got U_SAD={u_sad} V_SAD={v_sad}")
            print(f"[PASS] CB_AC_AMP block={block} amp={amp} strict-decodes {actual_bytes}/{expected_bytes} with Cb AC U_SAD={u_sad} V_SAD={v_sad}")
        else:
            print(f"[PASS] CB_AC_AMP block={block} amp={amp} quantizes below Cb AC threshold and full-decodes {actual_bytes}/{expected_bytes}")
    else:
        if actual_bytes != frame_size:
            raise SystemExit(f"[FAIL] CB_AC_AMP block={block} amp={amp} decoded {actual_bytes}/{expected_bytes}, expected locked one-frame miss")
        if short_signature not in ff_text:
            raise SystemExit(
                f"[FAIL] CB_AC_AMP block={block} amp={amp} expected FFmpeg signature "
                f"{short_signature!r}, got {ff_text.strip()!r}"
            )
        print(f"[PASS] CB_AC_AMP block={block} amp={amp} remains isolated one-frame miss {actual_bytes}/{expected_bytes} with FFmpeg signature {short_signature}")

    raw_yuv.unlink(missing_ok=True)

print("[PASS] CABAC P16x16 sparse Cb AC amplitude threshold probe locks +4 no-AC controls, +5/+8 top-row singleton short misses, and +5/+8 bottom-row singleton strict controls; next fix should target first-nonzero chroma AC residual emission/context state for top-row Cb blocks")
PY
