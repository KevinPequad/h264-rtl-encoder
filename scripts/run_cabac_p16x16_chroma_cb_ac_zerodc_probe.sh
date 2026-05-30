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

def zero_dc_cb_for_mask(mask: int) -> bytes:
    out = []
    for y in range(H // 2):
        for x in range(W // 2):
            block = (1 if x >= 4 else 0) + (2 if y >= 4 else 0)
            if (mask >> block) & 1:
                # Balanced around 128, so each selected 4x4 chroma block has
                # non-zero AC energy without a chroma-DC residual contribution.
                out.append(136 if ((x + y) % 2) else 120)
            else:
                out.append(128)
    return bytes(out)

out_dir = Path("data")
out_dir.mkdir(parents=True, exist_ok=True)
for mask in range(0x1, 0x10):
    out = out_dir / f"smoke_16x16_2f_cabac_p16x16_chroma_residual_cb_ac_zerodc_mask_{mask:x}.yuv"
    out.write_bytes(y0 + flat_chroma + flat_chroma + y1 + zero_dc_cb_for_mask(mask) + flat_chroma)
    print(f"[INFO] CB_AC_ZERODC mask=0x{mask:x} fixture {out} size={out.stat().st_size}")
PY

BUILD_OUT="$(mktemp /tmp/h264_cabac_cb_ac_zerodc_probe_build.XXXXXX)"
python3 - <<'PY' > "$BUILD_OUT"
from scripts.rtl_runner import BuildConfig, build_sim, stage_workspace
workspace = stage_workspace('h264_cabac_cb_ac_zerodc_probe_')
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
frame_size = 16 * 16 * 3 // 2
expected_bytes = frame_size * 2
expected_short_signatures = {
    0x1: "bytestream -20",
    0x2: "bytestream -18",
    0x3: "bytestream -24",
    0x5: "bytestream -22",
    0x6: "bytestream -26",
    0x7: "bytestream -19",
    0x9: "bytestream -20",
    0xA: "bytestream -30",
    0xB: "bytestream -17",
    0xD: "bytestream -15",
    0xE: "bytestream -15",
    0xF: "bytestream -9",
}
expected_strict = {0x4, 0x8, 0xC}

for mask in range(0x1, 0x10):
    input_path = root / "data" / f"smoke_16x16_2f_cabac_p16x16_chroma_residual_cb_ac_zerodc_mask_{mask:x}.yuv"
    h264 = root / "output" / f"cabac_p16x16_chroma_residual_cb_ac_zerodc_mask_{mask:x}.h264"
    sim_log = root / "output" / f"validation_cabac_p16x16_chroma_residual_cb_ac_zerodc_mask_{mask:x}.sim.log"
    ffmpeg_log = root / "output" / f"validation_cabac_p16x16_chroma_residual_cb_ac_zerodc_mask_{mask:x}.ffmpeg.log"
    raw_yuv = Path(f"/tmp/h264_cabac_cb_ac_zerodc_mask_{mask:x}.raw.yuv")

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
        raise SystemExit(f"[FAIL] CB_AC_ZERODC mask=0x{mask:x} did not exercise integrated CABAC P16x16")
    if "cabac_chroma_dc_mbs=0" not in sim_text or "cb_ac_mbs=1" not in sim_text or "cr_ac_mbs=0" not in sim_text:
        raise SystemExit(f"[FAIL] CB_AC_ZERODC mask=0x{mask:x} did not stay zero-DC Cb-only AC")
    expected_blocks = mask.bit_count()
    if f"cb_ac_blocks={expected_blocks}" not in sim_text or "cr_ac_blocks=0" not in sim_text:
        raise SystemExit(f"[FAIL] CB_AC_ZERODC mask=0x{mask:x} did not report {expected_blocks} Cb AC block(s)")

    with ffmpeg_log.open("w") as log:
        subprocess.run(
            ["ffmpeg", "-y", "-v", "error", "-xerror", "-i", str(h264), "-f", "rawvideo", "-pix_fmt", "yuv420p", str(raw_yuv)],
            stdout=log,
            stderr=subprocess.STDOUT,
            check=False,
        )
    actual_bytes = raw_yuv.stat().st_size if raw_yuv.exists() else 0
    ff_text = ffmpeg_log.read_text(errors="ignore")

    if mask in expected_strict:
        if ff_text.strip():
            raise SystemExit(f"[FAIL] CB_AC_ZERODC mask=0x{mask:x} strict-pass FFmpeg log was not empty: {ff_text.strip()!r}")
        if actual_bytes != expected_bytes:
            raise SystemExit(f"[FAIL] CB_AC_ZERODC mask=0x{mask:x} decoded {actual_bytes}/{expected_bytes} bytes, expected full strict decode")
        src = input_path.read_bytes()
        dec = raw_yuv.read_bytes()
        u0 = frame_size + 16 * 16
        v0 = u0 + 16 * 16 // 4
        chroma_size = 16 * 16 // 4
        u_sad = sum(abs(dec[u0 + i] - src[u0 + i]) for i in range(chroma_size))
        v_sad = sum(abs(dec[v0 + i] - src[v0 + i]) for i in range(chroma_size))
        if u_sad == 0 or v_sad != 0:
            raise SystemExit(f"[FAIL] CB_AC_ZERODC mask=0x{mask:x} expected Cb-only decoded delta, got U_SAD={u_sad} V_SAD={v_sad}")
        print(f"[PASS] CB_AC_ZERODC mask=0x{mask:x} strict-decodes {actual_bytes}/{expected_bytes} with zero chroma-DC contribution, cb_ac_blocks={expected_blocks}, U_SAD={u_sad} V_SAD={v_sad}")
    else:
        expected_signature = expected_short_signatures[mask]
        if actual_bytes != frame_size:
            raise SystemExit(f"[FAIL] CB_AC_ZERODC mask=0x{mask:x} decoded {actual_bytes}/{expected_bytes} bytes, expected locked one-frame miss")
        if expected_signature not in ff_text:
            raise SystemExit(
                f"[FAIL] CB_AC_ZERODC mask=0x{mask:x} short decode did not preserve expected FFmpeg signature "
                f"{expected_signature!r}: {ff_text.strip()!r}"
            )
        print(
            f"[PASS] CB_AC_ZERODC mask=0x{mask:x} remains isolated one-frame miss "
            f"{actual_bytes}/{expected_bytes} with zero chroma-DC contribution, cb_ac_blocks={expected_blocks}, and FFmpeg signature {expected_signature}"
        )

    raw_yuv.unlink(missing_ok=True)

print("[PASS] CABAC P16x16 Cb-only chroma AC zero-DC lattice locked: only bottom-row masks 0x4/0x8/0xc strict-decode without chroma DC, while top-row and mixed masks remain exact-signature one-frame misses")
PY
