#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
export PATH=/home/chudpc/.local/verilator-5.020/bin:$PATH

python3 - <<'PY'
from pathlib import Path
import os
import re
import subprocess
import sys
import tempfile

from scripts.rtl_runner import BuildConfig, build_sim, stage_workspace

ROOT = Path.cwd()
WIDTH = HEIGHT = 16
FRAME_SIZE = WIDTH * HEIGHT * 3 // 2
EXPECTED_BYTES = FRAME_SIZE * 2
MASKS = (0x1, 0x2, 0x3, 0x4, 0x8, 0xC)
BIASES = (-16, -8, 0, 8, 16)
EXPECTED_FULL = {(0x3, 0), (0x4, 0), (0x8, 0)}
EXPECTED_SHORT_SIGNATURES = {
    (0x1, -16): "bytestream -26",
    (0x1, -8): "bytestream -23",
    (0x1, 0): "bytestream -19",
    (0x1, 8): "bytestream -16",
    (0x1, 16): "bytestream -22",
    (0x2, -16): "bytestream -26",
    (0x2, -8): "bytestream -29",
    (0x2, 0): "bytestream -21",
    (0x2, 8): "bytestream -26",
    (0x2, 16): "bytestream -22",
    (0x3, -16): "bytestream -14",
    (0x3, -8): "bytestream -10",
    (0x3, 8): "bytestream -12",
    (0x3, 16): "bytestream -11",
    (0x4, -16): "bytestream -22",
    (0x4, -8): "bytestream -19",
    (0x4, 8): "bytestream -27",
    (0x4, 16): "bytestream -22",
    (0x8, -16): "bytestream -22",
    (0x8, -8): "bytestream -20",
    (0x8, 8): "bytestream -26",
    (0x8, 16): "bytestream -14",
    (0xC, -16): "bytestream -17",
    (0xC, -8): "bytestream -24",
    (0xC, 0): "bytestream -18",
    (0xC, 8): "bytestream -12",
    (0xC, 16): "bytestream -25",
}


def cb_for_mask_bias(mask: int, bias: int) -> bytes:
    out = []
    for y in range(HEIGHT // 2):
        for x in range(WIDTH // 2):
            block = (1 if x >= 4 else 0) + (2 if y >= 4 else 0)
            value = 128 + bias
            if ((mask >> block) & 1) and ((x + y) & 1):
                value += 8
            out.append(max(0, min(255, value)))
    return bytes(out)


def make_fixture(mask: int, bias: int) -> Path:
    y0 = bytes([64]) * (WIDTH * HEIGHT)
    y1 = bytes([64]) * (WIDTH * HEIGHT)
    flat_chroma = bytes([128]) * ((WIDTH // 2) * (HEIGHT // 2))
    out = ROOT / "data" / f"smoke_16x16_2f_cabac_p16x16_chroma_residual_cb_ac_dc_bias_m{mask:x}_b{bias:+d}.yuv"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_bytes(y0 + flat_chroma + flat_chroma + y1 + cb_for_mask_bias(mask, bias) + flat_chroma)
    print(f"[INFO] CB_AC_DC_BIAS mask=0x{mask:x} bias={bias:+d} fixture {out.relative_to(ROOT)} size={out.stat().st_size}")
    return out


def run_case(sim: Path, mask: int, bias: int, input_path: Path) -> None:
    out_dir = ROOT / "output" / "cabac_cb_ac_dc_bias_probe"
    out_dir.mkdir(parents=True, exist_ok=True)
    tag = f"m{mask:x}_b{bias:+d}"
    h264 = out_dir / f"{tag}.h264"
    sim_log = out_dir / f"{tag}.sim.log"
    ffmpeg_log = out_dir / f"{tag}.ffmpeg.log"
    raw_yuv = Path(tempfile.mktemp(prefix=f"h264_cb_ac_dc_bias_{tag}_", suffix=".yuv"))

    with sim_log.open("w", encoding="utf-8") as log:
        subprocess.run(
            [str(sim), "+frames=2", "+timeout=5000000", f"+input={input_path}", f"+output={h264}", "+idr_interval=12"],
            cwd=ROOT,
            stdout=log,
            stderr=subprocess.STDOUT,
            check=True,
        )
    sim_text = sim_log.read_text(errors="ignore")
    expected_blocks = bin(mask).count("1")
    for needle in (
        "cabac_p16x16_mbs=1",
        "cb_ac_mbs=1",
        "cr_ac_mbs=0",
        f"cb_ac_blocks={expected_blocks}",
        "cr_ac_blocks=0",
    ):
        if needle not in sim_text:
            raise SystemExit(f"[FAIL] CB_AC_DC_BIAS mask=0x{mask:x} bias={bias:+d} sim log missing {needle}")

    with ffmpeg_log.open("w", encoding="utf-8") as log:
        subprocess.run(
            ["ffmpeg", "-y", "-v", "error", "-xerror", "-i", str(h264), "-f", "rawvideo", "-pix_fmt", "yuv420p", str(raw_yuv)],
            cwd=ROOT,
            stdout=log,
            stderr=subprocess.STDOUT,
            check=False,
        )
    actual_bytes = raw_yuv.stat().st_size if raw_yuv.exists() else 0
    ff_text = ffmpeg_log.read_text(errors="ignore")

    if (mask, bias) in EXPECTED_FULL:
        if ff_text.strip():
            raise SystemExit(f"[FAIL] CB_AC_DC_BIAS mask=0x{mask:x} bias={bias:+d} expected clean FFmpeg log, got {ff_text.strip()!r}")
        if actual_bytes != EXPECTED_BYTES:
            raise SystemExit(f"[FAIL] CB_AC_DC_BIAS mask=0x{mask:x} bias={bias:+d} decoded {actual_bytes}/{EXPECTED_BYTES}, expected strict full decode")
        src = input_path.read_bytes()
        dec = raw_yuv.read_bytes()
        u0 = FRAME_SIZE + WIDTH * HEIGHT
        v0 = u0 + WIDTH * HEIGHT // 4
        chroma_size = WIDTH * HEIGHT // 4
        u_sad = sum(abs(dec[u0 + i] - src[u0 + i]) for i in range(chroma_size))
        v_sad = sum(abs(dec[v0 + i] - src[v0 + i]) for i in range(chroma_size))
        if u_sad == 0 or v_sad != 0:
            raise SystemExit(f"[FAIL] CB_AC_DC_BIAS mask=0x{mask:x} bias={bias:+d} expected Cb-only decoded delta, got U_SAD={u_sad} V_SAD={v_sad}")
        print(f"[PASS] CB_AC_DC_BIAS mask=0x{mask:x} bias={bias:+d} strict-decodes {actual_bytes}/{EXPECTED_BYTES} with Cb-only U_SAD={u_sad} V_SAD={v_sad}")
    else:
        expected_signature = EXPECTED_SHORT_SIGNATURES[(mask, bias)]
        if actual_bytes != FRAME_SIZE or expected_signature not in ff_text:
            got_sig = re.search(r"bytestream -\d+", ff_text)
            got = got_sig.group(0) if got_sig else ff_text.strip()
            raise SystemExit(
                f"[FAIL] CB_AC_DC_BIAS mask=0x{mask:x} bias={bias:+d} expected isolated "
                f"{FRAME_SIZE}/{EXPECTED_BYTES} miss with {expected_signature!r}, got {actual_bytes}/{EXPECTED_BYTES}: {got!r}"
            )
        print(f"[PASS] CB_AC_DC_BIAS mask=0x{mask:x} bias={bias:+d} remains isolated {actual_bytes}/{EXPECTED_BYTES} with FFmpeg signature {expected_signature}")

    raw_yuv.unlink(missing_ok=True)


def main() -> int:
    os.environ["PATH"] = "/home/chudpc/.local/verilator-5.020/bin:" + os.environ.get("PATH", "")
    fixtures = {(mask, bias): make_fixture(mask, bias) for mask in MASKS for bias in BIASES}
    sim = Path(
        build_sim(
            stage_workspace("h264_cabac_cb_ac_dc_bias_probe_"),
            BuildConfig(
                width=WIDTH,
                height=HEIGHT,
                bit_depth=8,
                chroma_format_idc=1,
                jobs=int(os.environ.get("BUILD_JOBS", "1")),
                enable_idr_ipcm=1,
                ipcm_sad_threshold=0,
                enable_cabac_p16x16=1,
            ),
        )
    )
    for mask in MASKS:
        for bias in BIASES:
            run_case(sim, mask, bias, fixtures[(mask, bias)])
    print(
        "[PASS] CABAC P16x16 Cb-only chroma AC DC-bias probe locks that adding uniform Cb DC bias "
        "does not promote sparse top/split masks and regresses otherwise-green masks except the zero-bias controls"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
PY
