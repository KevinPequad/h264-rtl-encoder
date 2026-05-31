#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
export PATH=/home/chudpc/.local/verilator-5.020/bin:$PATH

BUILD_OUT="$(mktemp /tmp/h264_cabac_cr_ac_phase_probe_build.XXXXXX)"
python3 - <<'PY' > "$BUILD_OUT"
from scripts.rtl_runner import BuildConfig, build_sim, stage_workspace
workspace = stage_workspace('h264_cabac_cr_ac_phase_probe_')
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
mkdir -p output/cabac_cr_ac_phase_probe data

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

# Cr-only single-block AC does not reproduce the sparse top-row Cb-only
# short-decode blocker.  Lock the matching first-nonzero residual phase/sign
# lattice as strict controls so the Cb repair can stay plane/order scoped rather
# than chasing a generic chroma-AC threshold or singleton issue.
CASES = [
    # name, block, delta, checker_parity, expect_ac, expected V-plane SAD
    ("top_left_quantized_even", 0, 4, 0, False, 32),
    ("top_right_quantized_even", 1, 4, 0, False, 32),
    ("bottom_left_quantized_even", 2, 4, 0, False, 32),
    ("bottom_right_quantized_even", 3, 4, 0, False, 32),
    ("top_left_pos_even", 0, 5, 0, True, 40),
    ("top_left_pos_odd", 0, 5, 1, True, 40),
    ("top_left_neg_even", 0, -5, 0, True, 40),
    ("top_left_neg_odd", 0, -5, 1, True, 40),
    ("top_right_pos_even", 1, 5, 0, True, 40),
    ("top_right_pos_odd", 1, 5, 1, True, 40),
    ("top_right_neg_even", 1, -5, 0, True, 40),
    ("top_right_neg_odd", 1, -5, 1, True, 40),
    ("bottom_left_pos_even", 2, 5, 0, True, 40),
    ("bottom_left_pos_odd", 2, 5, 1, True, 40),
    ("bottom_left_neg_even", 2, -5, 0, True, 40),
    ("bottom_left_neg_odd", 2, -5, 1, True, 40),
    ("bottom_right_pos_even", 3, 5, 0, True, 40),
    ("bottom_right_pos_odd", 3, 5, 1, True, 40),
    ("bottom_right_neg_even", 3, -5, 0, True, 40),
    ("bottom_right_neg_odd", 3, -5, 1, True, 40),
    ("top_left_pos8_odd", 0, 8, 1, True, 64),
    ("top_right_pos8_odd", 1, 8, 1, True, 64),
    ("bottom_left_pos8_odd", 2, 8, 1, True, 64),
    ("bottom_right_pos8_odd", 3, 8, 1, True, 64),
]

def make_fixture(name: str, block: int, delta: int, parity: int) -> Path:
    bx = (block & 1) * 4
    by = (block >> 1) * 4
    cr = []
    for y in range(height // 2):
        for x in range(width // 2):
            if bx <= x < bx + 4 and by <= y < by + 4 and ((x + y) & 1) == parity:
                cr.append(max(0, min(255, 128 + delta)))
            else:
                cr.append(128)
    out = root / "data" / f"smoke_16x16_2f_cabac_p16x16_chroma_residual_cr_ac_phase_{name}.yuv"
    out.write_bytes(y0 + flat_chroma + flat_chroma + y1 + flat_chroma + bytes(cr))
    print(f"[INFO] CR_AC_PHASE {name} fixture {out.relative_to(root)} size={out.stat().st_size}")
    return out

for name, block, delta, parity, expect_ac, expected_v_sad in CASES:
    input_path = make_fixture(name, block, delta, parity)
    h264 = root / "output" / "cabac_cr_ac_phase_probe" / f"{name}.h264"
    sim_log = root / "output" / "cabac_cr_ac_phase_probe" / f"{name}.sim.log"
    ffmpeg_log = root / "output" / "cabac_cr_ac_phase_probe" / f"{name}.ffmpeg.log"
    raw_yuv = Path(f"/tmp/h264_cabac_cr_ac_phase_{name}.raw.yuv")

    with sim_log.open("w", encoding="utf-8") as log:
        subprocess.run(
            [sim, "+frames=2", "+timeout=5000000", f"+input={input_path}", f"+output={h264}", "+idr_interval=12"],
            cwd=root,
            stdout=log,
            stderr=subprocess.STDOUT,
            check=True,
        )
    sim_text = sim_log.read_text(errors="ignore")
    expected_needles = ["cabac_p16x16_mbs=1", "cb_ac_mbs=0", "cb_ac_blocks=0"]
    if expect_ac:
        expected_needles.extend(["cr_ac_mbs=1", "cabac_chroma_ac_mbs=1", "cr_ac_blocks=1"])
    else:
        expected_needles.extend(["cr_ac_mbs=0", "cabac_chroma_ac_mbs=0", "cr_ac_blocks=0"])
    for needle in expected_needles:
        if needle not in sim_text:
            raise SystemExit(f"[FAIL] CR_AC_PHASE {name} sim log missing {needle}")

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
    if ff_text.strip():
        raise SystemExit(f"[FAIL] CR_AC_PHASE {name} expected clean FFmpeg log, got {ff_text.strip()!r}")
    if actual_bytes != expected_bytes:
        raise SystemExit(f"[FAIL] CR_AC_PHASE {name} decoded {actual_bytes}/{expected_bytes}, expected strict full decode")

    src = input_path.read_bytes()
    dec = raw_yuv.read_bytes()
    u0 = frame_size + width * height
    v0 = u0 + width * height // 4
    chroma_size = width * height // 4
    u_sad = sum(abs(dec[u0 + i] - src[u0 + i]) for i in range(chroma_size))
    v_sad = sum(abs(dec[v0 + i] - src[v0 + i]) for i in range(chroma_size))
    if u_sad != 0 or v_sad != expected_v_sad:
        raise SystemExit(f"[FAIL] CR_AC_PHASE {name} expected Cr-only decoded delta U_SAD=0 V_SAD={expected_v_sad}, got U_SAD={u_sad} V_SAD={v_sad}")
    if not expect_ac:
        print(f"[PASS] CR_AC_PHASE {name} quantizes below Cr AC threshold and strict-decodes {actual_bytes}/{expected_bytes} with U_SAD={u_sad} V_SAD={v_sad}")
    else:
        print(f"[PASS] CR_AC_PHASE {name} strict-decodes {actual_bytes}/{expected_bytes} with Cr AC U_SAD={u_sad} V_SAD={v_sad}")

    raw_yuv.unlink(missing_ok=True)

print("[PASS] CABAC P16x16 Cr-only chroma AC phase/polarity probe locks +4 no-AC controls plus +5/+8 singleton strict decodes across all quadrants; sparse top-row short-decode behavior remains Cb/mixed-plane scoped")
PY
