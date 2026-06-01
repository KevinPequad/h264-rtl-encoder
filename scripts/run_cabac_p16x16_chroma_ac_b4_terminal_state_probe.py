#!/usr/bin/env python3
"""DEBUG_CABAC terminal-state probe for high-amplitude Cb0xb/Cr0x4.

The first/second/third payload sweeps and the payload-boundary probe keep the
remaining B4 miss scoped to the first generated residual payload byte.  This
probe runs the unchanged RTL with DEBUG_CABAC_P16X16 enabled and locks the
arithmetic state at terminate/flush for the four +/-32 endpoints.  It is a
non-repair diagnostic: the streams must still short-decode, the residual payload
bytes must remain the checked-in three-byte tails, no scoped split bank may be
selected for this reciprocal mask, and the terminating arithmetic low/range must
match the currently observed Cr-sign partition.
"""

from __future__ import annotations

import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from scripts.rtl_runner import BuildConfig, build_sim, stage_workspace  # noqa: E402
from scripts.run_cabac_p16x16_chroma_ac_b4_first_payload_substitution_probe import (  # noqa: E402
    BASELINE_CASES,
    CB_MASK,
    CR_MASK,
    assert_baseline_idr_only,
    decode_raw_bytes,
    first_payload_index,
)
from scripts.run_cabac_p16x16_chroma_ac_b4_second_payload_value_sweep import (  # noqa: E402
    BASELINE_SECOND_PAYLOADS,
)
from scripts.run_cabac_p16x16_chroma_ac_b4_third_payload_value_sweep import (  # noqa: E402
    BASELINE_THIRD_PAYLOADS,
)
from scripts.run_cabac_p16x16_chroma_ac_cross_plane_first_payload_probe import (  # noqa: E402
    final_slice_hex,
    make_fixture,
)

OUT_DIR = ROOT / "output" / "cabac_b4_terminal_state_probe"
EXPECTED_TERMINAL = {
    # cb_value, cr_value: ari_low.  The checked-in state currently partitions by
    # the Cr sign while keeping the same terminal range for all four endpoints.
    (160, 160): "19a",
    (160, 96): "17e",
    (96, 160): "19a",
    (96, 96): "17e",
}
EXPECTED_TERMINAL_RANGE = "270"


def build_debug_sim() -> Path:
    workspace = Path(stage_workspace("h264_b4_terminal_state_"))
    config = BuildConfig(
        width=16,
        height=16,
        bit_depth=8,
        chroma_format_idc=1,
        jobs=int(os.environ.get("BUILD_JOBS", "1")),
        enable_idr_ipcm=1,
        ipcm_sad_threshold=0,
        enable_cabac_p16x16=1,
        debug_cabac_p16x16=1,
    )
    sim = Path(build_sim(workspace, config))
    print(f"[INFO] B4_TERM workspace={workspace} sim={sim}")
    return sim


def run_debug_case(sim: Path, cb_value: int, cr_value: int) -> tuple[Path, bytes, str]:
    fixture = make_fixture(CB_MASK, CR_MASK, cb_value, cr_value)
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    h264 = OUT_DIR / f"cbb_cr4_cbv{cb_value}_crv{cr_value}.h264"
    sim_log = OUT_DIR / f"cbb_cr4_cbv{cb_value}_crv{cr_value}.sim.log"
    with sim_log.open("w", encoding="utf-8") as log:
        subprocess.run(
            [str(sim), "+frames=2", "+timeout=5000000", f"+input={fixture}", f"+output={h264}", "+idr_interval=12"],
            stdout=log,
            stderr=subprocess.STDOUT,
            check=True,
        )
    return fixture, h264.read_bytes(), sim_log.read_text(encoding="utf-8", errors="replace")


def final_flush_bytes(text: str) -> list[int]:
    out: list[int] = []
    for line in text.splitlines():
        if "[CABACEMIT]" not in line or "return_state=0" not in line or "return_sub=46" not in line:
            continue
        m = re.search(r"byte=([0-9a-f]{2})", line)
        if m:
            out.append(int(m.group(1), 16))
    return out


def payload_ctx_selects(text: str) -> list[int]:
    selects: list[int] = []
    for line in text.splitlines():
        if "[CABACCTX]" not in line or "cat=2" not in line:
            continue
        m = re.search(r"kind=(22|23|24) sel=(\d+)", line)
        if m:
            selects.append(int(m.group(2)))
    return selects


def terminal_state(text: str, label: str) -> tuple[str, str]:
    term_lines = [line for line in text.splitlines() if "[CABACTERM]" in line]
    if not term_lines:
        raise SystemExit(f"[FAIL] B4_TERM {label} missing CABACTERM line")
    m = re.search(r"ari_low=([0-9a-f]+) ari_range=([0-9a-f]+)", term_lines[-1])
    if not m:
        raise SystemExit(f"[FAIL] B4_TERM {label} malformed CABACTERM line: {term_lines[-1]}")
    return m.group(1), m.group(2)


def check_case(sim: Path, cb_value: int, cr_value: int) -> None:
    expected_first, expected_tail, expected_signature = BASELINE_CASES[(cb_value, cr_value)]
    expected_second = BASELINE_SECOND_PAYLOADS[(cb_value, cr_value)]
    expected_third = BASELINE_THIRD_PAYLOADS[(cb_value, cr_value)]
    expected_payload = [expected_first, expected_second, expected_third]
    label = f"cb=0x{CB_MASK:x} cr=0x{CR_MASK:x} cb_value={cb_value} cr_value={cr_value}"

    fixture, stream, text = run_debug_case(sim, cb_value, cr_value)
    tail = final_slice_hex(stream, label)
    if tail != expected_tail:
        raise SystemExit(f"[FAIL] B4_TERM {label} tail {tail}, expected {expected_tail}")
    first_payload_index(stream, label, expected_first)

    baseline_raw, baseline_err = decode_raw_bytes(stream)
    assert_baseline_idr_only(baseline_raw, baseline_err, fixture, label, expected_signature)

    emitted = final_flush_bytes(text)
    if emitted != expected_payload:
        pretty = ",".join(f"0x{x:02x}" for x in emitted)
        want = ",".join(f"0x{x:02x}" for x in expected_payload)
        raise SystemExit(f"[FAIL] B4_TERM {label} final flush bytes [{pretty}], expected [{want}]")

    selects = payload_ctx_selects(text)
    if any(sel >= 16 for sel in selects):
        raise SystemExit(f"[FAIL] B4_TERM {label} unexpectedly selected split payload bank: {selects}")

    ari_low, ari_range = terminal_state(text, label)
    if ari_low != EXPECTED_TERMINAL[(cb_value, cr_value)] or ari_range != EXPECTED_TERMINAL_RANGE:
        raise SystemExit(
            f"[FAIL] B4_TERM {label} terminal ari_low={ari_low} ari_range={ari_range}, "
            f"expected ari_low={EXPECTED_TERMINAL[(cb_value, cr_value)]} ari_range={EXPECTED_TERMINAL_RANGE}"
        )

    print(
        f"[PASS] B4_TERM {label}: baseline short/{expected_signature}, "
        f"payload={[f'0x{x:02x}' for x in emitted]}, shared_ctx_selects={selects[-12:]}, "
        f"terminal_ari_low=0x{ari_low} terminal_ari_range=0x{ari_range}"
    )


def main() -> int:
    sim = build_debug_sim()
    for cb_value, cr_value in BASELINE_CASES:
        check_case(sim, cb_value, cr_value)
    print(
        "[PASS] CABAC P16x16 high-amplitude Cb0xb/Cr0x4 terminal-state probe: "
        "all four checked-in endpoint streams still short-decode with the exact "
        "three-byte payload tails, stay on the shared payload context bank, and "
        "lock the terminating arithmetic low/range partition for the next source repair."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
