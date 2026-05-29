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
flat = bytes([128]) * ((W // 2) * (H // 2))
single_tl = bytes(136 if (x < 4 and y < 4 and ((x + y) % 2)) else 128 for y in range(H // 2) for x in range(W // 2))
single_tr = bytes(136 if (x >= 4 and y < 4 and ((x + y) % 2)) else 128 for y in range(H // 2) for x in range(W // 2))
single_bl = bytes(136 if (x < 4 and y >= 4 and ((x + y) % 2)) else 128 for y in range(H // 2) for x in range(W // 2))
single_br = bytes(136 if (x >= 4 and y >= 4 and ((x + y) % 2)) else 128 for y in range(H // 2) for x in range(W // 2))
patterns = {
    "single_tl": (flat, single_tl),
    "single_tr": (flat, single_tr),
    "single_bl": (flat, single_bl),
    "cb_mirror_single_tl": (single_tl, flat),
    "cb_mirror_single_tr": (single_tr, flat),
    "cb_mirror_single_bl": (single_bl, flat),
    "cb_mirror_single_br": (single_br, flat),
}
out_dir = Path("data")
out_dir.mkdir(parents=True, exist_ok=True)
for name, (cb, cr) in patterns.items():
    (out_dir / f"smoke_16x16_2f_cabac_p16x16_chroma_residual_cr_ac_{name}.yuv").write_bytes(
        y0 + flat + flat + y1 + cb + cr
    )
PY

BUILD_OUT="$(mktemp /tmp/h264_cabac_chroma_ac_debug_build.XXXXXX)"
python3 - <<'PY' > "$BUILD_OUT"
from scripts.rtl_runner import BuildConfig, build_sim, stage_workspace
workspace = stage_workspace('h264_cabac_chroma_ac_debug_')
config = BuildConfig(
    width=16,
    height=16,
    bit_depth=8,
    chroma_format_idc=1,
    enable_idr_ipcm=1,
    ipcm_sad_threshold=0,
    enable_cabac_p16x16=1,
    debug_cabac_p16x16=1,
)
print(build_sim(workspace, config))
PY
SIM="$(tail -1 "$BUILD_OUT")"
mkdir -p output/cabac_chroma_ac_debug

for name in single_tl single_tr single_bl cb_mirror_single_tl cb_mirror_single_tr cb_mirror_single_bl cb_mirror_single_br; do
  "$SIM" \
    +frames=2 \
    +timeout=5000000 \
    +input="$ROOT/data/smoke_16x16_2f_cabac_p16x16_chroma_residual_cr_ac_${name}.yuv" \
    +output="$ROOT/output/cabac_chroma_ac_debug/${name}.h264" \
    +idr_interval=12 \
    > "output/cabac_chroma_ac_debug/${name}.sim.log" 2>&1

  ffmpeg -y -v error -xerror -i "output/cabac_chroma_ac_debug/${name}.h264" \
    -f rawvideo -pix_fmt yuv420p "/tmp/h264_${name}_debug_decode.yuv" \
    > "output/cabac_chroma_ac_debug/${name}.ffmpeg.log" 2>&1 || true
  bytes=$(wc -c < "/tmp/h264_${name}_debug_decode.yuv")
  rm -f "/tmp/h264_${name}_debug_decode.yuv"
  echo "[INFO] ${name} decoded_bytes=${bytes}/768"
done

python3 - <<'PY'
from pathlib import Path
import re

expected = {
    "single_tl": {"first_coded": 4, "decode_bytes": 768},
    "single_tr": {"first_coded": 5, "decode_bytes": 768},
    "single_bl": {"first_coded": 6, "decode_bytes": 768},
    "cb_mirror_single_tl": {"first_coded": 0, "decode_bytes": 384},
    "cb_mirror_single_tr": {"first_coded": 1, "decode_bytes": 384},
    "cb_mirror_single_bl": {"first_coded": 2, "decode_bytes": 384},
    "cb_mirror_single_br": {"first_coded": 3, "decode_bytes": 768},
}
root = Path("output/cabac_chroma_ac_debug")
for name, exp in expected.items():
    sim_log = root / f"{name}.sim.log"
    ffmpeg_log = root / f"{name}.ffmpeg.log"
    lines = sim_log.read_text(encoding="utf-8", errors="replace").splitlines()
    res = []
    ctx = []
    for line in lines:
        if "[CABACRES]" in line:
            m = re.search(r"cat=(\d+) blk=(\d+) ctx=(\d+) val=(\d+) bypass=(\d+) coeff=(\d+).*state_in=(\d+)", line)
            if m and m.group(1) == "2":
                res.append(tuple(map(int, m.groups()[1:])))
        elif "[CABACCTX]" in line:
            m = re.search(r"cat=(\d+) blk=(\d+) kind=(\d+) sel=(\d+) in=(\d+) out=(\d+)", line)
            if m and m.group(1) == "2":
                ctx.append(tuple(map(int, m.groups()[1:])))
    coded = [row for row in res if row[1] == 101 and row[2] == 1 and row[3] == 0]
    if not coded:
        raise SystemExit(f"[FAIL] {name}: no coded chroma AC CBF bin found in debug trace")
    first_blk = coded[0][0]
    if first_blk != exp["first_coded"]:
        raise SystemExit(f"[FAIL] {name}: first coded block {first_blk}, expected {exp['first_coded']}")
    if not any(row[0] == first_blk and row[1] == 21 for row in ctx):
        raise SystemExit(f"[FAIL] {name}: missing CHRAC_CBF context-state write for first coded block {first_blk}")
    debug_text = sim_log.read_text(encoding="utf-8", errors="replace")
    if "[CABACRES]" not in debug_text or "[CABACCTX]" not in debug_text:
        raise SystemExit(f"[FAIL] {name}: debug trace did not include both residual-bin and context-update lines")
    # FFmpeg emits a short raw file for the remaining known miss signature and full
    # 768-byte output for the strict-pass controls; lock those signatures so
    # this remains a diagnostic compare rather than silently promoting/demoting.
    raw_path = Path(f"/tmp/nonexistent_{name}")
    # Decode bytes were printed by the shell loop; recompute from the h264 to keep
    # this parser self-checking.
    import subprocess, tempfile, os
    with tempfile.NamedTemporaryFile(prefix=f"h264_{name}_dbg_", suffix=".yuv", delete=False) as tmp:
        tmp_path = Path(tmp.name)
    try:
        subprocess.run([
            "ffmpeg", "-y", "-v", "error", "-xerror", "-i", str(root / f"{name}.h264"),
            "-f", "rawvideo", "-pix_fmt", "yuv420p", str(tmp_path),
        ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
        got_bytes = tmp_path.stat().st_size if tmp_path.exists() else 0
    finally:
        try:
            tmp_path.unlink()
        except FileNotFoundError:
            pass
    if got_bytes != exp["decode_bytes"]:
        raise SystemExit(f"[FAIL] {name}: decoded {got_bytes} bytes, expected {exp['decode_bytes']}")
    print(f"[PASS] {name}: first coded chroma-AC block {first_blk}, decoded {got_bytes}/768 bytes, CABACRES/CABACCTX trace present")

print("[PASS] CABAC P16x16 sparse chroma AC debug compare locks promoted Cr top/left strict passes and the full remaining sparse Cb top/left miss trace set")
PY
