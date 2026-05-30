#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
export PATH=/home/chudpc/.local/verilator-5.020/bin:$PATH

python3 - <<'PY'
from pathlib import Path
import itertools
import subprocess

from scripts.rtl_runner import BuildConfig, build_sim, stage_workspace

ROOT = Path.cwd()
W = H = 16
FRAME_BYTES = W * H * 3 // 2
FULL_BYTES = FRAME_BYTES * 2
SINGLE_MASKS = (0x1, 0x2, 0x4, 0x8)


def bit(mask: int, block: int) -> int:
    return (mask // (2 ** block)) % 2


def cb_for_mask(mask: int) -> bytes:
    out = []
    for y in range(H // 2):
        for x in range(W // 2):
            block = (1 if x >= 4 else 0) + (2 if y >= 4 else 0)
            out.append(136 if bit(mask, block) and ((x + y) % 2) else 128)
    return bytes(out)


def patch_workspace_bitstream(workspace: Path) -> None:
    p = workspace / "rtl" / "h264_bitstream.v"
    s = p.read_text()
    anchor = "    reg [6:0]  cabac_res_chroma_ac_last_ctx_state [0:14];\n"
    insert = """    reg [6:0]  cabac_res_chroma_ac_last_ctx_state [0:14];
`ifndef SYNTHESIS
    reg [1:0]  cabac_debug_sparse_cb_ctx_sel [0:3];
    integer cabac_debug_sparse_cb_ctx_tmp;
    initial begin
        cabac_debug_sparse_cb_ctx_sel[0] = 2'd1;
        cabac_debug_sparse_cb_ctx_sel[1] = 2'd1;
        cabac_debug_sparse_cb_ctx_sel[2] = 2'd3;
        cabac_debug_sparse_cb_ctx_sel[3] = 2'd0;
        if ($value$plusargs(\"cabac_sparse_cb_ctx0=%d\", cabac_debug_sparse_cb_ctx_tmp)) cabac_debug_sparse_cb_ctx_sel[0] = cabac_debug_sparse_cb_ctx_tmp[1:0];
        if ($value$plusargs(\"cabac_sparse_cb_ctx1=%d\", cabac_debug_sparse_cb_ctx_tmp)) cabac_debug_sparse_cb_ctx_sel[1] = cabac_debug_sparse_cb_ctx_tmp[1:0];
        if ($value$plusargs(\"cabac_sparse_cb_ctx2=%d\", cabac_debug_sparse_cb_ctx_tmp)) cabac_debug_sparse_cb_ctx_sel[2] = cabac_debug_sparse_cb_ctx_tmp[1:0];
        if ($value$plusargs(\"cabac_sparse_cb_ctx3=%d\", cabac_debug_sparse_cb_ctx_tmp)) cabac_debug_sparse_cb_ctx_sel[3] = cabac_debug_sparse_cb_ctx_tmp[1:0];
    end
`endif
"""
    case_old = """                case (plane_block_i)
                    3'd0: begin left_coded_i = 1'b1; top_coded_i = 1'b0; end
                    3'd1: begin left_coded_i = 1'b1; top_coded_i = 1'b0; end
                    3'd2: begin left_coded_i = 1'b1; top_coded_i = 1'b1; end
                    default: begin left_coded_i = 1'b0; top_coded_i = 1'b0; end
                endcase
"""
    case_new = """`ifndef SYNTHESIS
                case (cabac_debug_sparse_cb_ctx_sel[plane_block_i])
                    2'd0: begin left_coded_i = 1'b0; top_coded_i = 1'b0; end
                    2'd1: begin left_coded_i = 1'b1; top_coded_i = 1'b0; end
                    2'd2: begin left_coded_i = 1'b0; top_coded_i = 1'b1; end
                    default: begin left_coded_i = 1'b1; top_coded_i = 1'b1; end
                endcase
`else
                case (plane_block_i)
                    3'd0: begin left_coded_i = 1'b1; top_coded_i = 1'b0; end
                    3'd1: begin left_coded_i = 1'b1; top_coded_i = 1'b0; end
                    3'd2: begin left_coded_i = 1'b1; top_coded_i = 1'b1; end
                    default: begin left_coded_i = 1'b0; top_coded_i = 1'b0; end
                endcase
`endif
"""
    if anchor not in s:
        raise SystemExit("[FAIL] sparse-Cb selector sweep could not find debug-reg anchor")
    if case_old not in s:
        raise SystemExit("[FAIL] sparse-Cb selector sweep could not find selector case")
    s = s.replace(anchor, insert, 1).replace(case_old, case_new, 1)
    p.write_text(s)


def run_decode_bytes(sim: Path, table: tuple[int, int, int, int], mask: int) -> int:
    tag = "".join(str(v) for v in table)
    input_path = ROOT / "data" / f"smoke_16x16_2f_cabac_p16x16_chroma_residual_cb_ac_mask_{mask:x}.yuv"
    h264_path = Path(f"/tmp/h264_sparse_cb_ctx_{tag}_{mask:x}.h264")
    raw_path = Path(f"/tmp/h264_sparse_cb_ctx_{tag}_{mask:x}.yuv")
    log_path = Path(f"/tmp/h264_sparse_cb_ctx_{tag}_{mask:x}.sim.log")
    args = [
        str(sim),
        "+frames=2",
        "+timeout=5000000",
        f"+input={input_path}",
        f"+output={h264_path}",
        "+idr_interval=12",
    ]
    args.extend(f"+cabac_sparse_cb_ctx{i}={v}" for i, v in enumerate(table))
    with log_path.open("w") as log:
        proc = subprocess.run(args, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT)
    if proc.returncode != 0:
        return -1
    subprocess.run(
        ["ffmpeg", "-y", "-v", "error", "-xerror", "-i", str(h264_path), "-f", "rawvideo", "-pix_fmt", "yuv420p", str(raw_path)],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    decoded_bytes = raw_path.stat().st_size if raw_path.exists() else 0
    h264_path.unlink(missing_ok=True)
    raw_path.unlink(missing_ok=True)
    return decoded_bytes


data_dir = ROOT / "data"
data_dir.mkdir(parents=True, exist_ok=True)
y0 = bytes([64]) * (W * H)
y1 = y0
flat = bytes([128]) * ((W // 2) * (H // 2))
for mask in range(1, 16):
    (data_dir / f"smoke_16x16_2f_cabac_p16x16_chroma_residual_cb_ac_mask_{mask:x}.yuv").write_bytes(
        y0 + flat + flat + y1 + cb_for_mask(mask) + flat
    )

workspace = stage_workspace("h264_sparse_cb_ctx_sweep_")
patch_workspace_bitstream(workspace)
sim = build_sim(
    workspace,
    BuildConfig(
        width=16,
        height=16,
        bit_depth=8,
        chroma_format_idc=1,
        enable_idr_ipcm=1,
        ipcm_sad_threshold=0,
        enable_cabac_p16x16=1,
    ),
)

qualified: list[tuple[tuple[int, int, int, int], dict[int, int]]] = []
near: list[tuple[tuple[int, int, int, int], dict[int, int]]] = []
for table in itertools.product(range(4), repeat=4):
    result = {mask: run_decode_bytes(sim, table, mask) for mask in SINGLE_MASKS}
    full_count = sum(decoded == FULL_BYTES for decoded in result.values())
    if full_count >= 2:
        near.append((table, result))
    if full_count >= 3:
        qualified.append((table, result))

expected_near = {
    (1, 1, 3, 0): {0x1: 384, 0x2: 384, 0x4: 768, 0x8: 768},
    (0, 2, 0, 3): {0x1: 384, 0x2: 384, 0x4: 768, 0x8: 768},
}
near_map = {table: result for table, result in near}
if qualified:
    raise SystemExit(f"[FAIL] sparse Cb CBF context selector sweep found a selector table that promotes at least three singleton masks: {qualified[:4]}")
if near_map != expected_near:
    raise SystemExit(f"[FAIL] sparse Cb CBF context selector sweep changed near-pass set: {near_map}")

print("[PASS] CABAC P16x16 sparse Cb AC singleton blocker is not solved by the 4-entry CBF context selector table alone")
print("[PASS] only selector tables (1,1,3,0) and (0,2,0,3) preserve the two bottom singleton strict-decodes, and neither promotes top singleton masks 0x1/0x2")
PY
