# Full-Feature H.264 RTL Coverage Implementation Plan

> **For Hermes:** Use subagent-driven-development skill to implement this plan task-by-task. Do not run full long-form RTL simulation until the feature-complete milestone is reached; use focused Verilator tests only as feature gates.

**Goal:** Move `/home/chudpc/code/h264-rtl-encoder` from a validated constrained H.264 subset to full-feature RTL coverage before final full-resolution/long-duration RTL simulation.

**Architecture:** Preserve the RTL-owned byte-stream rule: the Verilator testbench may feed raw frames and validate outputs, but must not repair H.264 syntax. Implement missing standard feature classes in dependency order, with each feature closed by focused RTL simulation plus public FFmpeg/ffprobe decode checks before broad validation.

**Tech Stack:** Verilog RTL, Verilator 5.020, FFmpeg/ffprobe, existing `scripts/validate_clip.py`, existing smoke matrix, x264/spec references for syntax behavior.

---

## Non-Negotiable Ordering

1. **Feature coverage first.** No final 720p/10-second/full RTL proof while major feature gaps remain.
2. **Focused Verilator gates are allowed.** Small tests are required after each feature so we do not stack unverified RTL.
3. **No Yosys/ASIC proof yet.** Synthesis proof happens after codec feature coverage and RTL decode validation are closed.
4. **RTL owns the bitstream.** The testbench cannot patch, rewrite, or paper over syntax.

---

## Current Baseline

Known working subset before this plan:

- flat-memory raw YUV fetch through Verilator testbench
- RTL-owned Annex B H.264 byte stream generation
- CAVLC path for current subset
- IDR/P paths and selected intra/inter modes
- `Intra_4x4` directional luma support
- `Intra_16x16` support including luma AC maxCoeff=15 syntax fix in `rtl/h264_encoder_top.v`
- limited multi-ref P subset
- limited weighted prediction subset
- limited B/BREF/direct `16x16` paths
- selected 4:2:0 and spot 4:4:4/I_PCM validation

Current intentional dirty RTL files to review/fold into feature branch:

- `rtl/h264_encoder_top.v`
- `rtl/h264_cabac_core.v`
- `rtl/h264_intra16_pred.v`
- `rtl/h264_intra_pred.v`

---

## Milestone 0: Freeze and Rebaseline

**Objective:** Establish a clean feature-completion branch and preserve the current subset fix without running long validation.

**Files:**
- Modify/review: current dirty RTL files above
- Create/update: `STATUS.md` after validation checkpoints

**Steps:**
1. Review `git diff` and split changes into logical commits:
   - Intra_16x16 luma AC CAVLC syntax fix
   - intra prediction cleanup/fixes
   - CABAC core bounded-output cleanup
2. Run only fast focused gates:
   ```bash
   cd /home/chudpc/code/h264-rtl-encoder
   export PATH=/home/chudpc/.local/verilator-5.020/bin:$PATH
   python3 scripts/regress_smoke_matrix.py --case smoke_8b_420 --case smoke_8b_420_cabac_pskip --case smoke_8b_420_bdirect
   python3 scripts/validate_clip.py --width 320 --height 176 --frames 1 --input data/flatmem_testsrc_320x176_4f.yuv --label flatmem_i16ac_gate_320x176_1f --decode-only --skip-mp4
   ```
3. Commit the baseline before broad feature work.

**Exit criteria:** Fast smoke and focused Intra_16x16 gate pass; no full long validation required.

---

## Milestone 1: Full CABAC Syntax Integration

**Objective:** Extend CABAC from current partial subset to full practical slice syntax coverage.

**Primary files:**
- `rtl/h264_cabac_core.v`
- `rtl/h264_bitstream.v`
- `rtl/h264_encoder_top.v`
- new helper modules as needed under `rtl/`
- focused tests/scripts under `scripts/` if needed

**Feature scope:**
1. CABAC context state model for macroblock syntax.
2. Binarization and context selection for:
   - `mb_type`
   - `mb_skip_flag`
   - `coded_block_pattern`
   - `ref_idx_l0` / `ref_idx_l1`
   - `mvd_l0` / `mvd_l1`
   - transform coefficient significance, last, levels
   - chroma/luma residual syntax needed by supported profiles
3. CABAC slice initialization and termination for I/P/B slices.
4. CABAC support for intra, P inter, B inter/direct/skip paths implemented by later milestones.

**Focused gates:**
- tiny I-slice CABAC residual case
- tiny P-slice nonzero residual CABAC case
- P-skip CABAC regression
- coefficient-heavy 4x4 residual CABAC regression
- FFmpeg strict decode for every gate

**Exit criteria:** CABAC can be selected for all implemented non-I_PCM I/P syntax in small tests without falling back to CAVLC-only subset limitations.

---

**CABAC checkpoint correction:** current integrated CABAC `P_L0_16x16` is only the
single-ref / zero-CBP / zero-MVD subset. The residual scan-event and bin/context helpers exist
as standalone building blocks, but nonzero luma/chroma CABAC coefficient syntax
still needs a real RED/GREEN integration gate; do not treat the old residual
checkpoint wording as feature completion.
the next CABAC step is general residual-bin coverage from coefficient
positions/levels, then `mb_qp_delta`, chroma, and the remaining I/P/B bins.

## Milestone 2: Broader Inter Partitions

**Objective:** Add standard inter partition coverage beyond mostly `16x16`.

**Primary files:**
- `rtl/h264_me.v`
- `rtl/h264_encoder_top.v`
- transform/quant/recon datapath modules
- bitstream/CABAC/CAVLC syntax modules

**Feature scope:**
- P partitions: `16x16`, `16x8`, `8x16`, `8x8`
- sub-macroblock partitions: `8x4`, `4x8`, `4x4`
- reference index syntax per partition/subpartition
- MVD syntax per partition/subpartition
- reconstruction/reference writeback for all partitions

**Focused gates:**
- force each partition type on a tiny clip
- verify FFmpeg decode
- verify reconstructed reference is consumed by a following P frame

**Exit criteria:** All standard P inter partition shapes have RTL-owned syntax and reconstruction, with focused decode tests.

**Lane closeout:** The P/inter milestone is complete. The implementation chain ran
through `766c2ef` (P16x8/P8x16), `39af946` (nonzero-MVD/ref_idx/weighted-P/
qpel-subpel), `df547f9` (P8x8/subMB), and `f49cdd8` (clean-checkout repair).
Review `t_48fbe723` rejected the `39af946` candidate because the smoke matrix
was not self-contained; `t_dffbac81` approved `f49cdd8`. The canonical merge
state stayed on `asic-readiness-main` @ `8d57dd5` with the validated edits in
the dirty working tree, and post-merge validation `t_f05e396c` passed 17/17
smoke cases under `THREADS=1 BUILD_JOBS=1`. See
`output/h264_p_inter_lane_closeout_t_8258e748.md` for the evidence bundle.

---

## Milestone 3: Full B/BREF and Direct Coverage

**Objective:** Broaden B and BREF support beyond current limited `16x16` direct/list paths.

**Primary files:**
- `rtl/h264_encoder_top.v`
- motion prediction/list-management logic
- CABAC/CAVLC syntax paths
- reference-bank metadata structures

**Feature scope:**
- B partitions matching standard inter partition coverage
- list0/list1/bi prediction per partition
- B skip and direct modes across supported partitions
- spatial and temporal direct edge cases
- BREF/reference-slot behavior
- colocated picture metadata completeness

**Focused gates:**
- forced `B_L0`, `B_L1`, `B_BI`, `B_DIRECT`, `B_SKIP`
- reordered B GOP with BREF ref slots
- temporal direct with nonzero colocated refs
- FFmpeg strict decode for all gates

**Exit criteria:** B/BREF/direct modes work across the implemented partition set, not just selected `16x16` probes.

---

## Milestone 4: Full Reference Picture Management / DPB

**Objective:** Replace the current limited reference-bank assumptions with standard-like DPB/reference behavior.

**Primary files:**
- `rtl/h264_encoder_top.v`
- reference-bank metadata and frame/slice header logic
- SPS/PPS/slice header generation logic

**Feature scope:**
- decoded picture buffer semantics
- reference marking for IDR and non-IDR pictures
- short-term and, if required, long-term references
- reference list construction/reordering
- memory management control operations if targeting full generality
- active reference counts per slice/list

**Focused gates:**
- multi-ref P with changing active ref count
- reordered B using different list construction cases
- reference eviction/marking cases

**Exit criteria:** The RTL no longer depends on narrow handcrafted reference-bank cases for legal H.264 multi-ref/reordered operation.

---

## Milestone 5: In-Loop Deblocking

**Objective:** Implement standard in-loop deblocking so reconstructed references match decoder-side reference behavior.

**Primary files:**
- new `rtl/h264_deblock*.v` modules
- `rtl/h264_encoder_top.v`
- reference writeback pipeline

**Feature scope:**
- boundary strength calculation
- luma/chroma edge filtering
- QP-dependent alpha/beta/tc thresholds
- slice edge behavior
- write deblocked reconstruction into reference banks

**Focused gates:**
- single-frame visual/decode smoke
- two-frame test proving P-frame reference uses deblocked output
- boundary-heavy synthetic patterns

**Exit criteria:** Decoder-compatible streams with deblocking enabled and reference writeback after filtering.

---

## Milestone 6: 8x8 Transform / High-Profile Tools

**Objective:** Add high-profile transform/tool coverage needed to stop calling the RTL a baseline-ish subset.

**Primary files:**
- transform/quant/inverse transform modules
- `rtl/h264_encoder_top.v`
- CAVLC/CABAC coefficient syntax paths
- SPS/PPS profile signalling

**Feature scope:**
- transform-size decision support
- 8x8 forward/inverse transform
- 8x8 quant/dequant
- 8x8 scan and coefficient syntax
- profile/PPS signaling for transform_8x8_mode

**Focused gates:**
- forced 8x8 transform I/P cases
- mixed 4x4/8x8 cases
- CABAC and CAVLC if both are supported for target profile

**Exit criteria:** High-profile 8x8 transform cases decode through FFmpeg from RTL-owned bytes.

---

## Milestone 7: Chroma / Bit Depth / Profile Matrix

**Objective:** Broaden and regularize coverage for 4:2:0, 4:2:2, 4:4:4 and 8/10-bit paths.

**Primary files:**
- chroma prediction/residual modules
- `rtl/h264_encoder_top.v`
- SPS/PPS/profile signalling
- validation scripts

**Feature scope:**
- 4:2:0, 4:2:2, 4:4:4 I/P/B coverage
- 8-bit and 10-bit where target profiles require it
- chroma residual syntax and transforms across entropy modes
- correct profile/level signalling

**Focused gates:**
- matrix of small clips by chroma format and bit depth
- forced intra/inter cases per format
- FFmpeg strict decode and ffprobe profile checks

**Exit criteria:** Format/profile matrix passes focused decode tests without special-case testbench fixes.

---

## Milestone 8: Final Feature-Complete Validation

**Objective:** Only after milestones 1-7 are closed, run broad full RTL simulation.

**Commands:**
Use `scripts/validate_clip.py` staged from small to large:

1. `320x176`, 24 frames, decode-only
2. `1280x720`, 24 frames, decode-only
3. final target: `1280x720 @ 24 fps`, 240 frames / 10 seconds, RTL-owned bytes

**Exit criteria:**
- FFmpeg strict decode passes
- ffprobe reports expected profile/level/pix_fmt
- output came from RTL byte path
- visual/metric check completed
- status docs updated

---

## Immediate Next Task

Start with **Milestone 0**, then **Milestone 1: CABAC**. CABAC is the dependency root for broad Main/High/full-standard feature coverage; building more modes without full entropy support would create more partial subset behavior.
