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

def cb_for_mask(mask: int) -> bytes:
    out = []
    for y in range(H // 2):
        for x in range(W // 2):
            block = (1 if x >= 4 else 0) + (2 if y >= 4 else 0)
            out.append(136 if ((mask >> block) & 1 and ((x + y) % 2)) else 128)
    return bytes(out)

out_dir = Path("data")
out_dir.mkdir(parents=True, exist_ok=True)
for mask in range(1, 16):
    out = out_dir / f"smoke_16x16_2f_cabac_p16x16_chroma_residual_cb_ac_mask_{mask:01x}.yuv"
    out.write_bytes(y0 + flat_chroma + flat_chroma + y1 + cb_for_mask(mask) + flat_chroma)
    print(f"[INFO] CB_AC mask=0x{mask:x} fixture {out} size={out.stat().st_size}")
PY

BUILD_OUT="$(mktemp /tmp/h264_cabac_cb_ac_mask_probe_build.XXXXXX)"
python3 - <<'PY' > "$BUILD_OUT"
from scripts.rtl_runner import BuildConfig, build_sim, stage_workspace
workspace = stage_workspace('h264_cabac_cb_ac_mask_probe_')
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
mkdir -p output

python3 - "$SIM" <<'PY'
import subprocess
import sys
from pathlib import Path

sim = sys.argv[1]
root = Path.cwd()
# The checked-in CABAC core `cod_i_queue=-7` initializer promotes the full
# nonzero Cb-only 2x2 chroma-AC mask lattice.  Lock every mask as a strict
# two-frame decode and exact plane-local Cb SAD instead of preserving the older
# pre-`-7` one-frame miss partition.
expected_full = set(range(1, 16))
frame_size = 16 * 16 * 3 // 2
expected_bytes = frame_size * 2

for mask in range(1, 16):
    input_path = root / "data" / f"smoke_16x16_2f_cabac_p16x16_chroma_residual_cb_ac_mask_{mask:x}.yuv"
    h264 = root / "output" / f"cabac_p16x16_chroma_residual_cb_ac_mask_{mask:x}.h264"
    sim_log = root / "output" / f"validation_cabac_p16x16_chroma_residual_cb_ac_mask_{mask:x}.sim.log"
    ffmpeg_log = root / "output" / f"validation_cabac_p16x16_chroma_residual_cb_ac_mask_{mask:x}.ffmpeg.log"
    raw_yuv = Path(f"/tmp/h264_cabac_cb_ac_mask_{mask:x}.raw.yuv")

    with sim_log.open("w") as log:
        subprocess.run(
            [sim, "+frames=2", "+timeout=5000000", f"+input={input_path}", f"+output={h264}", "+idr_interval=12"],
            cwd=root,
            stdout=log,
            stderr=subprocess.STDOUT,
            check=True,
        )
    sim_text = sim_log.read_text(errors="ignore")
    if "cabac_p16x16_mbs=1" not in sim_text:
        raise SystemExit(f"[FAIL] CB_AC mask=0x{mask:x} did not exercise integrated CABAC P16x16")
    if "cb_ac_mbs=1" not in sim_text or "cr_ac_mbs=0" not in sim_text:
        raise SystemExit(f"[FAIL] CB_AC mask=0x{mask:x} did not stay Cb-only")
    expected_blocks = bin(mask).count("1")
    if f"cb_ac_blocks={expected_blocks}" not in sim_text or "cr_ac_blocks=0" not in sim_text:
        raise SystemExit(f"[FAIL] CB_AC mask=0x{mask:x} did not report expected Cb AC block count {expected_blocks}")

    with ffmpeg_log.open("w") as log:
        subprocess.run(["ffmpeg", "-v", "error", "-xerror", "-i", str(h264), "-f", "null", "-"], stdout=log, stderr=subprocess.STDOUT)
    subprocess.run(
        ["ffmpeg", "-y", "-v", "error", "-xerror", "-i", str(h264), "-f", "rawvideo", "-pix_fmt", "yuv420p", str(raw_yuv)],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    actual_bytes = raw_yuv.stat().st_size if raw_yuv.exists() else 0

    if mask in expected_full:
        if actual_bytes != expected_bytes:
            raise SystemExit(f"[FAIL] CB_AC mask=0x{mask:x} decoded {actual_bytes}/{expected_bytes} bytes, expected full strict decode")
        src = input_path.read_bytes()
        dec = raw_yuv.read_bytes()
        u0 = frame_size + 16 * 16
        v0 = u0 + 16 * 16 // 4
        chroma_size = 16 * 16 // 4
        u_sad = sum(abs(dec[u0 + i] - src[u0 + i]) for i in range(chroma_size))
        v_sad = sum(abs(dec[v0 + i] - src[v0 + i]) for i in range(chroma_size))
        expected_u = expected_blocks * 64
        if u_sad != expected_u or v_sad != 0:
            raise SystemExit(f"[FAIL] CB_AC mask=0x{mask:x} expected exact Cb-only decoded delta U_SAD={expected_u} V_SAD=0, got U_SAD={u_sad} V_SAD={v_sad}")
        print(f"[PASS] CB_AC mask=0x{mask:x} strict-decodes {actual_bytes}/{expected_bytes} with cb_ac_blocks={expected_blocks} U_SAD={u_sad} V_SAD={v_sad}")
    else:
        raise SystemExit(f"internal expected mask partition missed 0x{mask:x}")

    raw_yuv.unlink(missing_ok=True)

print("[PASS] CABAC P16x16 Cb-only chroma AC mask lattice promoted: all 15 nonzero 2x2 Cb AC masks strict-decode two frames with exact plane-local Cb SAD under the checked-in -7 CABAC queue initializer")
PY
