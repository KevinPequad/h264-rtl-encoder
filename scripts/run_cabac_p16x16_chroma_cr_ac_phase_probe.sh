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
import tempfile

sim = sys.argv[1]
root = Path.cwd()
width = height = 16
frame_size = width * height * 3 // 2
expected_bytes = frame_size * 2
flat_chroma = bytes([128]) * ((width // 2) * (height // 2))
y0 = bytes([64]) * (width * height)
y1 = bytes([64]) * (width * height)
FIRST_CABAC_PAYLOAD = 0xEB
PROMOTED_PAYLOADS = (("queue_m8_payload_0x75", 0x75), ("bit7_payload_0x6b", 0x6B))

# Cr-only single-block AC does not reproduce the sparse top-row Cb-only
# short-decode blocker.  Lock the matching first-nonzero residual phase/sign
# lattice as strict controls so the Cb repair can stay plane/order scoped rather
# than chasing a generic chroma-AC threshold or singleton issue.  The exact
# final P-slice tails are also locked here: if a later Cb repair perturbs the
# Cr-only arithmetic/residual payload order while preserving strict decode, this
# probe should fail at the bytestream boundary instead of only at the decoded
# plane sanity layer.
CASES = [
    # name, block, delta, checker_parity, expect_ac, expected V-plane SAD,
    # exact current final P-slice hex
    ("top_left_quantized_even", 0, 4, 0, False, 32, "0000000141d008086b"),
    ("top_right_quantized_even", 1, 4, 0, False, 32, "0000000141d008086b"),
    ("bottom_left_quantized_even", 2, 4, 0, False, 32, "0000000141d008086b"),
    ("bottom_right_quantized_even", 3, 4, 0, False, 32, "0000000141d008086b"),
    ("top_left_pos_even", 0, 5, 0, True, 40, "0000000141d008086beb2f99af"),
    ("top_left_pos_odd", 0, 5, 1, True, 40, "0000000141d008086beb2f99af"),
    ("top_left_neg_even", 0, -5, 0, True, 40, "0000000141d008086beb2f99af"),
    ("top_left_neg_odd", 0, -5, 1, True, 40, "0000000141d008086beb2f99af"),
    ("top_right_pos_even", 1, 5, 0, True, 40, "0000000141d008086beb2f9a24"),
    ("top_right_pos_odd", 1, 5, 1, True, 40, "0000000141d008086beb2f9a24"),
    ("top_right_neg_even", 1, -5, 0, True, 40, "0000000141d008086beb2f9a24"),
    ("top_right_neg_odd", 1, -5, 1, True, 40, "0000000141d008086beb2f9a24"),
    ("bottom_left_pos_even", 2, 5, 0, True, 40, "0000000141d008086beb2f9860"),
    ("bottom_left_pos_odd", 2, 5, 1, True, 40, "0000000141d008086beb2f9860"),
    ("bottom_left_neg_even", 2, -5, 0, True, 40, "0000000141d008086beb2f9860"),
    ("bottom_left_neg_odd", 2, -5, 1, True, 40, "0000000141d008086beb2f9860"),
    ("bottom_right_pos_even", 3, 5, 0, True, 40, "0000000141d008086beb2f9986"),
    ("bottom_right_pos_odd", 3, 5, 1, True, 40, "0000000141d008086beb2f9986"),
    ("bottom_right_neg_even", 3, -5, 0, True, 40, "0000000141d008086beb2f9986"),
    ("bottom_right_neg_odd", 3, -5, 1, True, 40, "0000000141d008086beb2f9986"),
    ("top_left_pos8_odd", 0, 8, 1, True, 64, "0000000141d008086beb2f99af"),
    ("top_right_pos8_odd", 1, 8, 1, True, 64, "0000000141d008086beb2f9a24"),
    ("bottom_left_pos8_odd", 2, 8, 1, True, 64, "0000000141d008086beb2f9860"),
    ("bottom_right_pos8_odd", 3, 8, 1, True, 64, "0000000141d008086beb2f9986"),
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
        raise SystemExit(f"[FAIL] CR_AC_PHASE {path} has no Annex-B start code")
    return data[starts[-1]:].hex()


def first_payload_index(data: bytes, label: str) -> int:
    last_start = data.rfind(b"\x00\x00\x00\x01")
    if last_start < 0:
        raise SystemExit(f"[FAIL] CR_AC_PHASE {label} has no final Annex-B start code")
    header_tail_idx = last_start + 8
    first_idx = last_start + 9
    if first_idx >= len(data):
        raise SystemExit(f"[FAIL] CR_AC_PHASE {label} has no first CABAC payload byte")
    if data[header_tail_idx] != 0x6B:
        raise SystemExit(
            f"[FAIL] CR_AC_PHASE {label} header-tail byte 0x{data[header_tail_idx]:02x}, expected 0x6b"
        )
    if data[first_idx] != FIRST_CABAC_PAYLOAD:
        raise SystemExit(
            f"[FAIL] CR_AC_PHASE {label} first CABAC payload 0x{data[first_idx]:02x}, expected 0xeb"
        )
    return first_idx


def decode_h264_bytes(data: bytes) -> tuple[bytes, str]:
    with tempfile.NamedTemporaryFile(prefix="h264_cabac_cr_ac_phase_sub_", suffix=".h264", delete=False) as h264_tmp:
        h264_tmp.write(data)
        h264_path = Path(h264_tmp.name)
    with tempfile.NamedTemporaryFile(prefix="h264_cabac_cr_ac_phase_sub_", suffix=".yuv", delete=False) as raw_tmp:
        raw_path = Path(raw_tmp.name)
    try:
        proc = subprocess.run(
            ["ffmpeg", "-y", "-v", "error", "-xerror", "-i", str(h264_path), "-f", "rawvideo", "-pix_fmt", "yuv420p", str(raw_path)],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            check=False,
        )
        raw = raw_path.read_bytes() if raw_path.exists() else b""
        return raw, proc.stderr.decode("utf-8", "replace")
    finally:
        h264_path.unlink(missing_ok=True)
        raw_path.unlink(missing_ok=True)


def mutate_first_payload(data: bytes, first_idx: int, value: int) -> bytes:
    mutated = bytearray(data)
    mutated[first_idx] = value
    return bytes(mutated)


def assert_first_payload_substitutions(h264: Path, input_path: Path, name: str, delta: int) -> None:
    stream = h264.read_bytes()
    first_idx = first_payload_index(stream, name)
    expected_v_sad = 8 * abs(delta)
    src = input_path.read_bytes()
    u0 = frame_size + width * height
    v0 = u0 + width * height // 4
    chroma_size = width * height // 4
    for label, value in PROMOTED_PAYLOADS:
        raw, err = decode_h264_bytes(mutate_first_payload(stream, first_idx, value))
        if err.strip():
            raise SystemExit(f"[FAIL] CR_AC_PHASE {label} {name} FFmpeg log {err.strip()!r}")
        if len(raw) != expected_bytes:
            raise SystemExit(f"[FAIL] CR_AC_PHASE {label} {name} decoded {len(raw)}/{expected_bytes}")
        if raw[:frame_size] != src[:frame_size]:
            raise SystemExit(f"[FAIL] CR_AC_PHASE {label} {name} changed IDR reference")
        u_sad = sum(abs(raw[u0 + i] - src[u0 + i]) for i in range(chroma_size))
        v_sad = sum(abs(raw[v0 + i] - src[v0 + i]) for i in range(chroma_size))
        if u_sad != 0 or v_sad != expected_v_sad:
            raise SystemExit(
                f"[FAIL] CR_AC_PHASE {label} {name} SAD U={u_sad} V={v_sad}, "
                f"expected U=0 V={expected_v_sad}"
            )
        print(
            f"[PASS] CR_AC_PHASE {label} {name} promotes/stays strict at "
            f"{len(raw)}/{expected_bytes} with exact Cr-only V_SAD={v_sad}"
        )


for name, block, delta, parity, expect_ac, expected_v_sad, expected_final_slice in CASES:
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
    final_slice = final_nal_hex(h264)
    if final_slice != expected_final_slice:
        raise SystemExit(
            f"[FAIL] CR_AC_PHASE {name} final slice changed: "
            f"got {final_slice}, expected {expected_final_slice}"
        )
    if not final_slice.startswith("0000000141d008086b"):
        raise SystemExit(f"[FAIL] CR_AC_PHASE {name} lost locked P-slice header/payload prefix in {final_slice}")
    if expect_ac:
        if not final_slice.startswith("0000000141d008086beb"):
            raise SystemExit(f"[FAIL] CR_AC_PHASE {name} lost locked first CABAC payload byte in {final_slice}")
        assert_first_payload_substitutions(h264, input_path, name, delta)
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
        print(f"[PASS] CR_AC_PHASE {name} quantizes below Cr AC threshold and strict-decodes {actual_bytes}/{expected_bytes} final_slice={final_slice} with U_SAD={u_sad} V_SAD={v_sad}")
    else:
        print(f"[PASS] CR_AC_PHASE {name} strict-decodes {actual_bytes}/{expected_bytes} final_slice={final_slice} with Cr AC U_SAD={u_sad} V_SAD={v_sad}")

    raw_yuv.unlink(missing_ok=True)

print("[PASS] CABAC P16x16 Cr-only chroma AC phase/polarity probe locks +4 no-AC controls plus +5/+8 singleton strict decodes across all quadrants, exact final P-slice tails, and first-payload substitutions that preserve the full phase lattice; sparse top-row short-decode behavior remains Cb/mixed-plane scoped")
PY
