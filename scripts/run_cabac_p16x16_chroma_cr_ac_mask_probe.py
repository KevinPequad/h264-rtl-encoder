#!/usr/bin/env python3
"""Cr-only CABAC P16x16 chroma-AC mask-lattice probe.

The older chroma-AC probe locked Cr single-block controls and the dense Cr
checker separately.  This diagnostic covers every nonzero Cr-only 2x2 chroma-AC
block mask in one run so multi-block Cr failures cannot hide behind the single
block pass controls.
"""

from __future__ import annotations

import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from scripts.rtl_runner import BuildConfig, build_sim, stage_workspace

WIDTH = HEIGHT = 16
FRAME_SIZE = WIDTH * HEIGHT * 3 // 2
LUMA_SIZE = WIDTH * HEIGHT
CHROMA_SIZE = WIDTH * HEIGHT // 4
EXPECTED_BYTES = FRAME_SIZE * 2

STRICT_MASKS = {
    0x1,
    0x2,
    0x4,
    0x6,
    0x8,
    0x9,
    0xF,
}
MISS_SIGNATURES = {
    0x3: "bytestream -6",
    0x5: "bytestream -16",
    0x7: "bytestream -37",
    0xA: "bytestream -12",
    0xB: "bytestream -17",
    0xC: "bytestream -16",
    0xD: "bytestream -17",
    0xE: "bytestream -7",
}


def checker_chroma(mask: int) -> bytes:
    out: list[int] = []
    for y in range(HEIGHT // 2):
        for x in range(WIDTH // 2):
            block = (1 if x >= 4 else 0) + (2 if y >= 4 else 0)
            out.append(136 if ((mask >> block) & 1 and ((x + y) & 1)) else 128)
    return bytes(out)


def make_fixtures() -> dict[int, Path]:
    data_dir = ROOT / "data"
    data_dir.mkdir(parents=True, exist_ok=True)
    y0 = bytes([64]) * LUMA_SIZE
    y1 = bytes([64]) * LUMA_SIZE
    flat = bytes([128]) * CHROMA_SIZE
    fixtures: dict[int, Path] = {}
    for mask in range(1, 16):
        path = data_dir / f"smoke_16x16_2f_cabac_p16x16_chroma_residual_cr_ac_mask_{mask:x}.yuv"
        path.write_bytes(y0 + flat + flat + y1 + flat + checker_chroma(mask))
        fixtures[mask] = path
        print(f"[INFO] CR_AC_MASK mask=0x{mask:x} fixture {path} size={path.stat().st_size}")
    return fixtures


def build_baseline_sim() -> Path:
    workspace = stage_workspace("h264_cabac_cr_ac_mask_probe_")
    sim = Path(
        build_sim(
            workspace,
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
    print(f"[INFO] CR_AC_MASK workspace={workspace} sim={sim}")
    return sim


def decode_raw(h264: Path, ffmpeg_log: Path) -> bytes:
    with tempfile.NamedTemporaryFile(prefix="h264_cr_ac_mask_", suffix=".yuv", delete=False) as raw_tmp:
        raw_path = Path(raw_tmp.name)
    try:
        with ffmpeg_log.open("w", encoding="utf-8") as log:
            subprocess.run(
                [
                    "ffmpeg",
                    "-y",
                    "-v",
                    "error",
                    "-xerror",
                    "-i",
                    str(h264),
                    "-f",
                    "rawvideo",
                    "-pix_fmt",
                    "yuv420p",
                    str(raw_path),
                ],
                stdout=log,
                stderr=subprocess.STDOUT,
                check=False,
            )
        return raw_path.read_bytes() if raw_path.exists() else b""
    finally:
        raw_path.unlink(missing_ok=True)


def run_mask(sim: Path, mask: int, fixture: Path) -> None:
    out_dir = ROOT / "output" / "cabac_cr_ac_mask_probe"
    out_dir.mkdir(parents=True, exist_ok=True)
    h264 = out_dir / f"mask_{mask:x}.h264"
    sim_log = out_dir / f"mask_{mask:x}.sim.log"
    ffmpeg_log = out_dir / f"mask_{mask:x}.ffmpeg.log"

    with sim_log.open("w", encoding="utf-8") as log:
        subprocess.run(
            [
                str(sim),
                "+frames=2",
                "+timeout=5000000",
                f"+input={fixture}",
                f"+output={h264}",
                "+idr_interval=12",
            ],
            cwd=ROOT,
            stdout=log,
            stderr=subprocess.STDOUT,
            check=True,
        )

    sim_text = sim_log.read_text(encoding="utf-8", errors="replace")
    expected_blocks = mask.bit_count()
    for needle in (
        "cabac_p16x16_mbs=1",
        "cb_ac_mbs=0",
        "cr_ac_mbs=1",
        "cb_ac_blocks=0",
        f"cr_ac_blocks={expected_blocks}",
    ):
        if needle not in sim_text:
            raise SystemExit(f"[FAIL] CR_AC_MASK mask=0x{mask:x} sim log missing {needle}")
    if not re.search(r"cavlc_suppressed_bits=[1-9][0-9]*", sim_text):
        raise SystemExit(f"[FAIL] CR_AC_MASK mask=0x{mask:x} did not suppress the legacy CAVLC payload")

    raw = decode_raw(h264, ffmpeg_log)
    ff_text = ffmpeg_log.read_text(encoding="utf-8", errors="replace")
    src = fixture.read_bytes()

    if mask in STRICT_MASKS:
        if len(raw) != EXPECTED_BYTES:
            raise SystemExit(f"[FAIL] CR_AC_MASK mask=0x{mask:x} decoded {len(raw)}/{EXPECTED_BYTES}, expected strict")
        if ff_text.strip():
            raise SystemExit(f"[FAIL] CR_AC_MASK mask=0x{mask:x} expected clean FFmpeg log, got {ff_text.strip()!r}")
        if raw[:FRAME_SIZE] != src[:FRAME_SIZE]:
            raise SystemExit(f"[FAIL] CR_AC_MASK mask=0x{mask:x} changed IDR reference")
        u0 = FRAME_SIZE + LUMA_SIZE
        v0 = u0 + CHROMA_SIZE
        u_sad = sum(abs(raw[u0 + i] - src[u0 + i]) for i in range(CHROMA_SIZE))
        v_sad = sum(abs(raw[v0 + i] - src[v0 + i]) for i in range(CHROMA_SIZE))
        expected_v = expected_blocks * 64
        if u_sad != 0 or v_sad != expected_v:
            raise SystemExit(
                f"[FAIL] CR_AC_MASK mask=0x{mask:x} decoded-plane sanity U_SAD={u_sad} V_SAD={v_sad}, "
                f"expected U_SAD=0 V_SAD={expected_v}"
            )
        print(
            f"[PASS] CR_AC_MASK mask=0x{mask:x} strict-decodes {len(raw)}/{EXPECTED_BYTES} "
            f"with Cr-only V_SAD={v_sad}"
        )
        return

    signature = MISS_SIGNATURES[mask]
    if len(raw) != FRAME_SIZE:
        raise SystemExit(
            f"[FAIL] CR_AC_MASK mask=0x{mask:x} decoded {len(raw)}/{EXPECTED_BYTES}, "
            f"expected locked one-frame miss"
        )
    if signature not in ff_text:
        got_sig = re.search(r"bytestream -\d+", ff_text)
        raise SystemExit(
            f"[FAIL] CR_AC_MASK mask=0x{mask:x} expected FFmpeg signature {signature!r}, "
            f"got {(got_sig.group(0) if got_sig else ff_text.strip())!r}"
        )
    print(f"[PASS] CR_AC_MASK mask=0x{mask:x} remains one-frame {len(raw)}/{EXPECTED_BYTES} miss with {signature}")


def main() -> int:
    fixtures = make_fixtures()
    sim = build_baseline_sim()
    for mask, fixture in fixtures.items():
        run_mask(sim, mask, fixture)
    print(
        "[PASS] CABAC P16x16 Cr-only chroma-AC mask probe locks the current mask lattice: "
        "single blocks plus masks 0x6/0x9/0xf strict-decode, while adjacent/top+bottom multi-block "
        "masks 0x3/0x5/0x7/0xa/0xb/0xc/0xd/0xe remain exact-signature one-frame misses"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
