# ASIC Readiness Plan

This repo's H.264 encoder is being moved toward an ASIC-suitable flow on the main computer (`chudpc-MS-7C56`). Chud PC 2 is intentionally left for the AV1 workstream.

## Goal

Convert the RTL-owned H.264 encoder path into a credible ASIC-ready IP block. The target is not merely "Verilator passes"; the target is a synthesizable, timing-constrainable encoder block with repeatable evidence.

## Ground Rules

- Keep final H.264 syntax owned by RTL.
- Do not let the testbench author, patch, or repair final H.264 bytes.
- Prove small RTL-owned decode-compatible cases before scaling.
- Current lightweight ASIC/frontend work can run on Chud PC 2; memory-heavy full-top synthesis diagnostics should run on the PowerEdge or another large-memory host.
- Treat decoder compatibility, synthesis, and ASIC flow results as separate gates.

## Current Local Main-Computer Baseline

- Repo path: `/home/chudpc/code/h264-rtl-encoder`
- Local branch for ASIC-readiness work: `asic-readiness-main`
- Main-computer host: `chudpc-MS-7C56`
- Local tool setup added:
  - Verilator 5.020 installed at `/home/chudpc/.local/verilator-5.020/bin/verilator`
  - Chud PC 2 currently has Verilator 5.020 available; Yosys may be absent, so `scripts/run_asic_frontend_smoke.sh` runs Verilator lint first and skips Yosys cleanly when unavailable.
  - FFmpeg already available

Baseline RTL-owned smoke verified locally with Verilator 5.020:

```text
python3 scripts/regress_smoke_matrix.py --case smoke_8b_420
[PASS] smoke_8b_420: profile=Constrained Baseline pix_fmt=yuv420p 32x16 ...

python3 scripts/regress_smoke_matrix.py --case smoke_8b_420_cabac_pskip --case smoke_8b_420_cabac_p16x16
[PASS] smoke_8b_420_cabac_pskip: profile=Main pix_fmt=yuv420p 32x16 ...
[PASS] smoke_8b_420_cabac_p16x16: profile=Main pix_fmt=yuv420p 32x16 ...
```

## ASIC Conversion Work Plan

### Gate 1: Main-computer RTL validation

1. Use Verilator 5.020, not Ubuntu's old Verilator 4.038.
2. Run the existing small smoke matrix cases.
3. Run strict FFmpeg decode gates for representative I/P/B/CABAC-subset cases.
4. Record exact commands and artifacts in `output/`.

### Gate 2: Synthesis parsing and elaboration

1. Maintain a deterministic RTL file list for the ASIC/synthesis top.
2. Run Yosys parsing/elaboration:
   - `read_verilog -sv ...`
   - `hierarchy -check -top h264_encoder_top`
   - `proc; opt; stat`
3. Fix simulation-only constructs that block synthesis parsing.
4. Do not change Verilator-visible behavior when removing synthesis blockers.

Current synthesis bring-up status:

- Fixed the first Yosys parser blocker by guarding RTL `$fatal` simulation checks with `ifndef SYNTHESIS`, preserving Verilator failure behavior.
- Fixed CABAC-core synthesis-form blockers by replacing variable-bound loops / `while` with bounded loops and moving unnamed-block local temporaries to module-scope work registers.
- Fixed the CAVLC escape-prefix `while` by converting it to a bounded two-iteration loop.
- Verilator smoke still passes after these synthesis-oriented changes.

Current next synthesis/front-end issue:

```text
Yosys 0.9 now parses h264_bitstream.v, h264_cabac_core.v, h264_cavlc.v,
and h264_chroma_dc.v, then spends >600s in h264_encoder_top.v parsing/elaboration.
```

Next step is to split ASIC bring-up into smaller Yosys gates: parse/lint leaf modules first, then refactor or parameter-reduce `h264_encoder_top.v` before full hierarchy elaboration.

### Gate 3: Synthesizable subset closure

After Yosys elaborates, close the next blockers in order:

1. unsupported simulation-only system tasks
2. unsynthesizable memories or dynamic indexing patterns
3. inferred latch / multiple-driver issues
4. width/select warnings that become synthesis hazards
5. giant parameterized memories that need SRAM macro replacement

### Gate 4: ASIC wrapper and memory plan

Add a clean hardware IP boundary:

- clock/reset
- input pixel stream or DMA-style frame-buffer interface
- output Annex B byte stream interface
- status/error registers
- configuration registers for width/height/profile/subset knobs
- explicit SRAM/memory interfaces for frame buffers and FIFOs

The existing Verilator-oriented top can remain, but ASIC conversion should introduce a wrapper rather than forcing the testbench interface to be the final chip interface.

### Gate 5: Open ASIC flow

Once parsing/elaboration is clean:

1. choose open PDK target, likely Sky130/GF180 for proof-of-flow
2. generate OpenLane/OpenROAD config
3. run synthesis/place/route for a reduced parameter set first
4. report area/timing/utilization/memory blockers
5. only then scale toward larger resolutions or real SRAM macros

## Definition of "ASIC-ready enough" for this phase

This phase is done when:

- Verilator smoke/regression gates pass on the main computer
- Yosys can parse/elaborate the selected ASIC top
- synthesis produces a netlist for a reduced configuration
- all simulation-only constructs are isolated from synthesis
- a documented wrapper/memory/PDK plan exists
- remaining blockers are specific ASIC engineering tasks, not unknown repo state

## Current Chud PC 2 Frontend Smoke

`scripts/run_asic_frontend_smoke.sh` is the current lightweight ASIC-direction
smoke. It runs Verilator lint across the deterministic RTL top and, when Yosys
is installed, runs the Yosys frontend smoke as a second gate. Generated logs go
under `build/asic/`, which remains local/generated artifact space.
