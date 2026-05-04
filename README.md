# H.264 RTL Encoder

Synthesizable H.264 / AVC encoder RTL with a Verilator testbench, RTL-owned
Annex B bitstream generation, FFmpeg decode/remux helpers, and reproducible
smoke and validation scripts.

## Status

This repository is working end to end for a constrained subset of H.264. It is
not yet a full-standard H.264 encoder.

Implemented and validated now:

- RTL-owned Annex B byte-stream output
- SPS, PPS, IDR, non-IDR, macroblock headers, CAVLC, RBSP trailing bits, and
  emulation-prevention bytes in RTL
- I-frame and P-frame encode flow
- up to four-reference P-slice support with RTL-owned `ref_idx_l0`
  signaling across the active-reference count
- zero-residual inter-macroblock handling with deferred inter headers
- RTL-owned `P_SKIP` skip-run generation on the current P-slice path
- limited non-reference `B`-slice support on the current intra / `I_PCM` path
- limited inter-coded `B_L0_16x16`, `B_L1_16x16`, and `B_BI_16x16` support on
  the current reordered dual-list `16x16` B path
- limited `B_DIRECT_16x16` support on the current reordered dual-list `16x16`
  B path, with spatial direct derivation, a current limited temporal-direct
  mode, slice-level automatic temporal/spatial selection on reordered `B` and
  reordered-`BREF` slices when the future picture's `List0 ref0` bank maps
  back into the current past-reference set, and force hooks for targeted
  validation
- limited `B_SKIP` support on the current reordered dual-list `16x16`
  `B_DIRECT_16x16` path when the chosen direct macroblock reaches zero
  residual
- limited reference-`B` / `BREF` support on the current reordered dual-list
  `B_L0_16x16` / `B_L1_16x16` / `B_BI_16x16` path
- header/control signaling now uses a stream-level B-slice contract: I/P-only
  8-bit 4:2:0 streams stay Constrained Baseline, while B/BREF/reordered-GOP
  streams advertise Main profile and `max_num_reorder_frames = 1` from the
  first SPS; HRD and `transform_8x8` signaling remain off until those lanes
  exist
- full directional `Intra_4x4` mode support in RTL
- `Intra_16x16` luma prediction and syntax support in RTL
- current IDR path now routes through RTL `Intra_16x16` macroblock coding
  rather than leaving the feature smoke-only
- `Intra_16x16` luma-DC CAVLC now derives `nC` from the normal surrounding
  `4x4` nnz context, which re-closed the tiny non-`I_PCM` high-bit-depth
  decode path
- `Intra_16x16` luma-DC forward quantization and inverse dequantization in
  `rtl/h264_luma_dc.v` now match the current fixed-QP reconstruction path, so
  the current IDR-path `Intra_16x16` validation is no longer only decodable;
  it now reconstructs near-exactly on the validated `320x176` all-IDR run
- current non-`I_PCM` strict-decode validation now reaches `320x176` through
  `10` frames for `10-bit 4:2:0` and `10-bit 4:2:2`, and through `24` frames
  for `8-bit 4:4:4` and `10-bit 4:4:4`
- limited quarter-pel luma refinement and chroma fractional interpolation on the
  current inter path
- validated multi-frame subset runs plus current-tree near-exact
  `Intra_16x16` IDR validation
- Docker one-frame smoke run

Still missing before full-standard completion, using the current `x264`
software encoder as the implementation baseline:

- full CABAC syntax integration beyond the current skip-capable plus explicit
  zero-CBP / single-ref / zero-MVD `P_L0_16x16` P-slice subset
- broader `B` / `BREF` picture support, broader direct-mode handling, and the
  associated reference management
- broader standards-complete sub-pel motion handling across richer inter modes
- broader inter partition and transform coverage including `8x8dct`-class tools
- broader validated `4:4:4` support beyond the current `320x176`
  strict-decode non-`I_PCM` path and spot `I_PCM` coverage
- full in-loop deblocking
- broader profile and tool coverage
- final `1280x720 @ 24 fps`, `10`-second RTL-path completion run

See [STATUS.md](STATUS.md) for the detailed repository inventory, implemented
features, validated runs, and outstanding gaps.

## Project Goal

The target is a full end-to-end H.264 / AVC encoder through the RTL path. The
finished project must:

- generate a decodable Annex B H.264 stream from RTL output bytes
- keep final codec syntax owned by RTL rather than software helpers
- decode successfully in FFmpeg
- package the RTL-generated bitstream into MP4
- produce a visually correct result for the final target clip

Final completion target:

- clip: Big Buck Bunny
- duration: first 10 seconds
- output: `1280x720 @ 24 fps`
- source of truth: RTL-generated H.264 byte stream

Do not consider the encoder complete until the decoded final output is verified
and the remaining gaps against full H.264 standard coverage are closed.

## Continuous Progress Rule

Work in this repository is expected to continue past intermediate milestones.

- Do not stop at a smoke pass, subset pass, decode-only pass, or doc-only pass
- Do not treat a milestone as a stopping point if major H.264 standard gaps are
  still open
- After implementing meaningful feature work or correctness fixes:
  update `README.md` and `STATUS.md` to reflect the current state, push the
  current progress, and continue working
- Only stop when the encoder is actually complete or there is a concrete,
  full blocker that prevents further responsible progress

This repo should be updated as progress is made, not only at the end.

## Repository Layout

| Path | Purpose |
| --- | --- |
| `rtl/` | Encoder RTL modules |
| `tb/` | Verilator testbench and build flow |
| `scripts/` | Input prep, regression, packaging, and validation helpers |
| `docker/` | Docker smoke-run environment |
| `tools/` | Small debug and parsing utilities |
| `data/` | Local-only source media and generated YUV inputs |
| `output/` | Local-only encoded streams, decoded output, and validation artifacts |
| `references/` | Local-only codec specs and software reference documents |
| `STATUS.md` | Detailed implementation and repository inventory |
| `AGENTS.md` | Project rules for autonomous work in this repository |

## Software Reference Baseline

The normative reference for codec behavior remains the H.264 / AVC
specification. For practical implementation coverage and feature-gap tracking,
this repo now uses the official VideoLAN `x264` encoder source as the software
baseline.

Current local baseline:

- local path: `references/software/x264`
- upstream: `https://code.videolan.org/videolan/x264`
- local checkout used for this comparison:
  `0480cb05fa188d37ae87e8f4fd8f1aea3711f7ee` from `2025-08-31`

Why `x264`:

- it is the strongest practical H.264 software encoder baseline in common use
- its current source exposes the exact feature classes this RTL repo still
  needs, including CABAC, `B-frames`, reference-frame management, weighted
  prediction, direct motion-vector modes, sub-pel motion refinement, deblocking,
  profiles / levels, and broader chroma / bit-depth support

Key feature evidence in the local `x264` checkout:

- `x264.c` exposes `--profile`, `--level`, `--bframes`, `--b-pyramid`,
  `--ref`, `--no-deblock`, `--direct`, `--weightp`, `--me`, `--subme`, and
  `--no-cabac`
- `x264.h` exposes `I420`, `I422`, `I444`, high-depth pixel formats, and
  `IDR`, `P`, `BREF`, and `B` picture types

This baseline is used to define what is implemented now and what is still left
to implement. The final claim of completion still requires the RTL path itself
to generate the finished Annex B stream.

## What Is In The Repo Now

Current RTL pipeline:

`fetch -> motion estimation -> prediction -> transform -> quantize -> zigzag -> CAVLC -> inverse quant -> inverse transform -> reconstruct -> bitstream`

Current implemented features:

- end-to-end RTL-owned H.264 Annex B byte-stream generation
- SPS generation in RTL
- SPS `level_idc` selection in RTL from frame macroblock count and target frame
  rate
- SPS `pic_order_cnt_type = 0` signaling in RTL with
  `log2_max_pic_order_cnt_lsb_minus4 = 5`
- SPS `log2_max_frame_num_minus4 = 4` signaling in RTL for an 8-bit
  `frame_num` field
- SPS VUI timing signaling in RTL with `num_units_in_tick`,
  `time_scale`, and `fixed_frame_rate_flag`
- SPS VUI bitstream-restriction signaling in RTL: I/P-only streams advertise
  `max_num_reorder_frames = 0`, and B/BREF/reordered-GOP streams advertise
  `max_num_reorder_frames = 1` while keeping the current four-reference
  buffering subset
- PPS generation in RTL
- IDR slice header generation in RTL
- non-IDR slice header generation in RTL
- `pic_order_cnt_lsb` signaling in RTL on IDR and non-IDR slice headers
- 8-bit `frame_num` signaling and 9-bit `pic_order_cnt_lsb` signaling on
  IDR and non-IDR slice headers
- `pic_order_cnt_lsb` now comes from a dedicated RTL input instead of being
  derived from `frame_num`, so reordered GOPs can keep display order and
  reference numbering separate
- macroblock header generation in RTL
- RBSP trailing bits in RTL
- emulation-prevention byte insertion in RTL
- CAVLC entropy coding in RTL
- CAVLC for luma coefficients
- CAVLC for chroma DC coefficients
- CAVLC for chroma AC coefficients
- I-frame support
- P-frame support
- non-reference `B`-slice support on the current intra / `I_PCM` path
- limited inter-coded non-reference `B_L0_16x16`, `B_L1_16x16`, and
  `B_BI_16x16` support on the current reordered dual-list `16x16` B path
- limited `B_DIRECT_16x16` support on the current reordered dual-list `16x16`
  B path, with spatial direct derivation from neighbor state plus colocated MB
  metadata captured per reference bank
- current limited temporal-direct support on the reordered dual-list `16x16`
  B path when the future reference picture's `List0 ref0` bank maps back to
  the current past reference, including slice-level automatic temporal-direct
  selection on reordered `B` and reordered-`BREF` slices plus
  `direct_spatial_mv_pred_flag = 0` signaling in RTL
- limited reference-`B` / `BREF` support on the current reordered dual-list
  `B_L0_16x16` / `B_L1_16x16` / `B_BI_16x16` path
- reordered `B`-GOP scheduling support in the testbench / validation flow for
  encode orders such as `0,2,1,4,3`, with non-reference `B` pictures reusing
  the same `frame_num` as the surrounding reference pair while carrying their
  own `pic_order_cnt_lsb`
- current reordered B inter selection can choose past `List0`, future `List1`,
  or bidirectional `B_BI_16x16` prediction per macroblock on the current
  limited reordered dual-list `16x16` B path
- the current reordered dual-list `B_BI_16x16` path now seeds its past-side
  search from the best stored past-reference/future-reference pair instead of
  always collapsing to `List0 ref_idx 0`, so reordered validation can exercise
  nonzero `ref_idx_l0` values on the limited B path
- the current limited `B_BI_16x16` path now writes back both motion-vector
  lists into neighbor state and refines each list through the quarter-pel luma
  path before the bidirectional average is formed
- the current limited `B_DIRECT_16x16` path now derives decoder-matching
  spatial direct vectors from neighbor state, applies the colocated zero-MV
  rule from per-bank MB metadata, uses an exact direct interpolation path
  instead of the normal qpel search loop, and can now win automatically
  against the current reordered `B_L0_16x16` / `B_L1_16x16` / `B_BI_16x16`
  candidates instead of only via a force flag
- reference-bank metadata now also retains picture-order and frame-level
  list0-reference-bank state alongside the per-MB colocated metadata, and the
  current limited temporal-direct path now consumes that metadata on reordered
  B and reordered-`BREF` slices
- reference-bank metadata now also retains the additional stored future-picture
  `List0` bank mappings needed for the current limited temporal-direct path, so
  nonzero colocated future `ref_idx_l0` values can map back into the current B
  picture's past-reference set instead of only handling future `ref_idx_l0=0`
- reference-bank metadata now also retains the current limited future-picture
  `List1 ref0` bank mapping for reordered `BREF` pictures, and the temporal-
  direct path can now derive a candidate from colocated `List1` motion when
  that stored future mapping is the usable path back into the current past-
  reference set
- plain `B_L1_16x16` final selection now explicitly stores `List1 ref_idx 0`
  instead of leaking stale `List0` ref-index state into the colocated
  metadata, so reordered-`BREF` reference slots coded as `B_L1_16x16` can
  seed later temporal-direct derivation from colocated `List1`
- the current limited `B_DIRECT_16x16` path can now collapse zero-residual
  macroblocks into RTL-owned B-slice skip-run syntax through the same late
  deferred-header path already used for zero-residual `P_SKIP`
- reordered GOP forcing can now emit reference-slot pictures as `BREF` instead
  of `P`, so encode orders such as `0,2,1,4,3` can be driven as all-BREF
  non-IDR GOPs for validation
- IDR + non-IDR encoded stream output
- `16x16` macroblock raster-order processing
- up to four forward reference pictures for P-slice motion search
- inter/intra macroblock decisioning for P-frames
- slice-level active reference override and per-macroblock `ref_idx_l0` syntax
- standards-correct `TE(v)` coding for `ref_idx_l0` when two P-slice
  references are active, with `UE(v)` fallback when three references are active
- deferred inter-macroblock header emission so zero-residual inter MBs can
  legally choose `cbp=0` or `P_SKIP` before any residual syntax is released
- `mb_skip_run` accumulation and flush in RTL for P-slices
- zero-residual inter MB FIFO discard in RTL when no residual syntax should be
  emitted
- zero-residual `P_SKIP` selection in RTL when the chosen inter MB is
  `ref_idx_l0 = 0` and its motion vector matches the inferred `P_SKIP`
  predictor
- motion-vector-difference syntax for supported P macroblocks
- integer-pel motion estimation
- fixed search range motion estimation
- diamond-style luma motion estimation
- the integer-pel ME core now resets its per-search diamond/refine state on
  every new macroblock search, preventing stale candidate state from leaking
  between macroblocks
- quarter-pel luma refinement on the current `16x16` P-macroblock inter path
- luma inter prediction from the previous reconstructed frame
- chroma fractional interpolation on the current inter path
- weighted P prediction for inter luma and chroma on the RTL path
- `pred_weight_table` slice signaling in RTL for weighted P slices
- explicit weighted B prediction on the current single-list reordered B
  subpaths and limited `B_BI_16x16` path, including B-slice
  `pred_weight_table` signaling for `List0` and `List1`
- single-list weighted `P` / `B` / direct qpel refinement now scores weighted
  luma samples during mode decision instead of scoring the unweighted
  predictor and applying weights only later in reconstruction
- luma intra prediction:
  `Intra_4x4_Vertical`, `Intra_4x4_Horizontal`, `Intra_4x4_DC`,
  `Intra_4x4_Diagonal_Down_Right`, `Intra_4x4_Vertical_Right`,
  `Intra_4x4_Horizontal_Down`, `Intra_4x4_Vertical_Left`, and
  `Intra_4x4_Horizontal_Up`
- luma intra prediction:
  `Intra_16x16_Vertical`, `Intra_16x16_Horizontal`, `Intra_16x16_DC`, and
  `Intra_16x16_Plane`
- chroma intra prediction: DC-style path
- `4x4` H.264 integer transform
- inverse transform path
- quantization path
- inverse quantization path
- zigzag scan path
- reconstruction loop in RTL
- reference-frame writeback for reconstructed luma
- reference-frame writeback for reconstructed chroma
- standalone CABAC arithmetic coding core in `rtl/h264_cabac_core.v`, plus a
  current final-path CABAC subset for skip-capable P slices with dual PPS
  emission, CABAC slice-header fields, CABAC-coded `mb_skip_flag`,
  CABAC-coded `end_of_slice_flag`, and an explicit single-ref / zero-CBP /
  zero-MVD `P_L0_16x16` subset
- parameterized resolution
- parameterized bit depth
- parameterized chroma format

Implemented now relative to the chosen `x264` baseline:

- Annex B bitstream ownership in RTL
- parameter-set and slice-header ownership in RTL
- CAVLC-based coefficient coding in RTL
- current CABAC final-path subset on skip-capable P slices, with CABAC PPS
  selection, CABAC-coded `mb_skip_flag`, CABAC-coded `end_of_slice_flag`, and
  an explicit single-ref / zero-CBP / zero-MVD `P_L0_16x16` subset
- I and P picture flow
- non-reference `B`-picture syntax on the current intra / `I_PCM` path
- limited non-reference `B_L0_16x16`, `B_L1_16x16`, and `B_BI_16x16` inter
  coding on the current reordered dual-list `16x16` B path
- limited `B_DIRECT_16x16` inter coding on the current reordered dual-list
  `16x16` B path, with automatic selection plus a force hook for targeted
  validation
- limited `B_SKIP` ownership on the current reordered dual-list `16x16`
  direct path when a chosen direct macroblock reaches zero residual
- limited reference-`B` / `BREF` picture support on the current reordered
  dual-list `16x16` B path
- explicit weighted prediction on the current single-list reordered B subpaths
- limited spatial direct prediction on the current reordered dual-list
  `16x16` B path, plus a current limited temporal-direct mode for reordered
  B slices whose future reference maps back to the current past reference
- full `Intra_4x4` directional luma mode coverage
- `Intra_16x16` luma prediction and syntax support
- `I_PCM` macroblock coding on the current IDR path and current P-slice intra
  path, with raw-sample byte emission owned by the RTL writer
- exact `I_PCM` validation now also covers `4:4:4` on the current IDR and
  P-slice intra path at `32x16` for both `8-bit` and `10-bit`
- up-to-four-reference P-slice inter flow with integer-pel search and current
  quarter-pel luma refinement
- zero-residual inter-MB handling and `P_SKIP` skip-run ownership on the RTL
  path
- weighted P prediction and `pred_weight_table` ownership on the RTL path
- `8-bit` and `10-bit` operation for `4:2:0` and `4:2:2`

Supported and smoke-verified modes:

- `8-bit 4:2:0`
- `8-bit 4:2:2`
- `10-bit 4:2:0`
- `10-bit 4:2:2`

Current additional validated `I_PCM`-only coverage:

- `8-bit 4:4:4`
- `10-bit 4:4:4`

Current additional validated tiny non-`I_PCM` coverage at `32x16`:

- `10-bit 4:2:0` one-frame and two-frame IDR / P probes
- `10-bit 4:2:2` two-frame IDR / P probes
- `8-bit 4:4:4` two-frame IDR / P probes
- `10-bit 4:4:4` one-frame and two-frame IDR / P probes

Current additional validated non-`I_PCM` coverage at `320x176`:

- `10-bit 4:2:0` ten-frame strict-decode IDR+P run
- `10-bit 4:2:2` ten-frame strict-decode IDR+P run
- `8-bit 4:4:4` twenty-four-frame strict-decode IDR+P run
- `10-bit 4:4:4` twenty-four-frame strict-decode IDR+P run

## What Is Not Done Yet

Important non-completion gaps:

- full `CABAC` syntax/context integration beyond the current skip-capable plus
  explicit zero-CBP / single-ref / zero-MVD `P_L0_16x16` P-slice subset is
  not implemented yet
- broader inter-coded `B` / `BREF` picture handling is not implemented beyond
  the current limited reordered dual-list `B_L0_16x16` / `B_L1_16x16` /
  `B_BI_16x16` `16x16` path
- direct prediction modes are not fully implemented beyond the current limited
  `B_DIRECT_16x16` reordered-`BREF` path
- reference-picture management beyond the current four-reference P-slice subset
  is not implemented
- broader full-standard sub-pel motion handling beyond the current `16x16`
  quarter-pel luma path is not implemented
- broader inter partition coverage and `8x8dct`-class transform support are not
  implemented
- broader `4:4:4` chroma-format support beyond the current `320x176`
  strict-decode non-`I_PCM` path and spot `I_PCM` coverage is not implemented
- full in-loop deblocking is not implemented
- full-standard profile / level / tool coverage is not implemented
- the final `240`-frame `1280x720 @ 24 fps` run is not closed yet

This means the repo is currently a partial H.264 implementation, not a claim
of complete H.264 standard support.

## Validated Progress

Verified validation/features around the current encoder flow:

- FFmpeg-decodable RTL-generated `.h264`
- MP4 remux of the RTL-generated stream
- Docker one-frame smoke run producing RTL-generated `.h264` and `.mp4`
- reproducible smoke matrix for fast strict-decode/profile sanity on generated
  tiny `I_PCM` inputs plus tiny forced spatial-direct, temporal-direct,
  auto temporal-direct reordered-`B` and reordered-`BREF` cases,
  temporal-direct reordered-`BREF` `B_DIRECT_16x16`, mixed reordered-`BREF`
  ref-slot / B-slot temporal-direct cases, explicit reordered-`BREF`
  ref-slot `B_L1_16x16` guards, multi-ref reordered `B_BI_16x16` cases, and
  a generated flat exact-reference CABAC P-skip case plus a generated flat
  exact-reference explicit CABAC `P_L0_16x16` case
- multi-frame validation at `320x176`
- multi-frame validation at `1280x720`
- PSNR / SSIM comparison scripts
- x264 reference comparison scripts
- side-by-side decoded-vs-source image generation
- staged clean-build log capture for reproducible validation runs
- simulator log and cycle-count capture for regressions
- runtime-configurable `idr_interval` support in the testbench and validation
  scripts
- runtime-configurable `force_b_slice` support in the testbench and validation
  scripts for the current non-reference `B`-slice path
- runtime-configurable `force_bref_slice` support in the testbench and
  validation scripts for the current limited reference-`B` path
- runtime-configurable `reorder_b_gop` support in the testbench and validation
  scripts for reordered B-picture encode order
- runtime-configurable `force_b_bi` support in the testbench and validation
  scripts for the current limited `B_BI_16x16` path
- runtime-configurable `force_b_l0` support in the testbench and validation
  scripts for targeted validation of the current limited `B_L0_16x16` path
- runtime-configurable `force_b_l1` support in the testbench and validation
  scripts for targeted validation of the current limited `B_L1_16x16` path
- runtime-configurable `force_b_direct` support in the testbench and
  validation scripts for targeted validation of the current limited
  `B_DIRECT_16x16` path
- runtime-configurable `force_b_direct_temporal` support in the testbench and
  validation scripts so reordered B slices can switch to the current limited
  temporal-direct derivation and emit `direct_spatial_mv_pred_flag = 0`
- runtime-configurable slot-scoped `force_b_bi` / `force_b_l0` /
  `force_b_l1` / `force_b_direct` / `force_b_direct_temporal` support on
  reordered reference slots and reordered B slots, so mixed reordered-`BREF`
  validations can pin the future reference slot to `B_L0_16x16` or
  `B_L1_16x16` while pinning the later B slot to temporal direct in the same
  run
- simulator-side per-frame `b_l1_mbs` logging so reordered B validation can
  prove that the future-reference `List1` path was actually selected
- simulator-side per-frame `b_bi_mbs` logging so reordered B validation can
  prove that the bidirectional `B_BI_16x16` path was actually selected
- simulator-side per-frame `b_direct_mbs` logging so reordered B validation can
  prove that the current limited `B_DIRECT_16x16` path was actually selected,
  whether automatically or via force
- staged validation JSON and smoke summaries now carry parsed
  `skip_mbs` / `b_l1_mbs` / `b_bi_mbs` / `b_direct_mbs` /
  `b_l0_refgt0_mbs` / `b_direct_refgt0_mbs` / `b_direct_l1src_mbs` /
  `cabac_p16x16_mbs` aggregates so B-path behavior can be asserted without
  manual log scraping
- reordered validation can now combine `--reorder-b-gop` and
  `--force-bref-slice` so the reference slots are emitted as `BREF` pictures
- fast strict-decode-only validation mode in `validate_clip.py` for longer
  regressions that do not need metrics or x264 comparison
- RTL-owned `P_SKIP` skip-run generation validated on the current P-slice path

Measured validation points:

- `docker_320x176_1f`: `816,975` cycles
- `32x16_4f_cabac_pskip_ipcmidr`: strict FFmpeg-decodable CABAC skip-only
  P-slice validation on a flat exact-reference clip, `234,131` cycles,
  `473` bytes, `Main` profile, `output/validation_cabac_pskip_ipcmidr_32x16_4f.h264`,
  `output/validation_cabac_pskip_ipcmidr_32x16_4f.mp4`, and
  `b_mode_summary.total_skip = 6`
- `32x16_2f_cabac_p16x16`: strict FFmpeg-decodable explicit CABAC
  `P_L0_16x16` zero-CBP / single-ref / zero-MVD smoke, `47,268` cycles,
  `74` bytes, `Main` profile, `output/smoke_32x16_2f_cabac_p16x16.h264`, and
  `b_mode_summary.total_cabac_p16x16 = 2`
- `32x16_nonipcm_ncfix`: the `Intra_16x16` luma-DC `nC` fix re-opened strict
  decode on tiny non-`I_PCM` high-bit-depth probes, covering `10-bit 4:2:0`,
  `10-bit 4:2:2`, `8-bit 4:4:4`, and `10-bit 4:4:4` through the
  `validation_nonipcm_*_ncfix.json` artifacts
- `320x176_nonipcm_10f`: strict-decode IDR+P validation now also closes at
  `320x176` through `10` frames for `10-bit 4:2:0` and `10-bit 4:2:2`, and
  through `24` frames for `8-bit 4:4:4` and `10-bit 4:4:4`, via the
  `validation_nonipcm_*_320x176_4f_p.json`,
  `validation_nonipcm_*_320x176_10f_p.json`,
  `validation_nonipcm_8b444_320x176_24f_p_fixcbp2.json`, and
  `validation_nonipcm_10b444_320x176_24f_p_fixcbp2.json` artifacts
- `320x176_nonipcm_8b444_inter_cbp_fix`: the `4:4:4` inter
  `coded_block_pattern` path now uses the ChromaArrayType `3` inter table in
  the RTL writer instead of the `4:2:x` inter code, and strict FFmpeg decode
  now re-closes focused extracted clips ending on the old bad picture through
  `validation_nonipcm_8b444_f16f17_2f_fixcbp.json` (`2` frames,
  `14,159,804` cycles, `5,298` bytes) and
  `validation_nonipcm_8b444_f14f17_4f_fixcbp.json` (`4` frames,
  `88,709,796` cycles, `10,442` bytes), plus
  `validation_nonipcm_8b444_f12f17_6f_fixcbp.json` (`6` frames,
  `212,087,014` cycles, `16,327` bytes),
  `validation_nonipcm_8b444_f10f17_8f_fixcbp2.json` (`8` frames,
  `337,204,428` cycles, `21,715` bytes), and the full current-tree
  `validation_nonipcm_8b444_320x176_24f_p_fixcbp2.json` (`24` frames,
  `1,350,672,124` cycles, `58,281` bytes); the matching `10-bit 4:4:4`
  current-tree run now also re-closes through
  `validation_nonipcm_10b444_320x176_24f_p_fixcbp2.json` (`24` frames,
  `1,336,320,075` cycles, `56,308` bytes)
- `320x176_10f_tefix`: strict FFmpeg-decodable multi-frame validation on the
  current tree, `253,064,186` cycles, RTL PSNR avg `45.745576`, RTL SSIM all
  `0.994893`
- `320x176_1f_vui`: strict FFmpeg-decodable one-frame SPS/VUI timing smoke,
  `732,748` cycles, FFmpeg `level=12`, and raw-stream timing metadata behavior
  matching a one-frame `x264` elementary stream at the same settings
- `320x176_1f_vui_restrict`: strict FFmpeg-decodable one-frame SPS/VUI
  restriction smoke, `732,753` cycles, `trace_headers` confirming
  `bitstream_restriction_flag = 1`,
  `motion_vectors_over_pic_boundaries_flag = 1`,
  `max_num_reorder_frames = 0`, and `max_dec_frame_buffering = 4`
- `320x176_1f_frame_num8`: strict FFmpeg-decodable one-frame SPS/frame-number
  smoke, `732,751` cycles, `trace_headers` confirming
  `pic_order_cnt_type = 0`,
  `log2_max_frame_num_minus4 = 4`, and
  `log2_max_pic_order_cnt_lsb_minus4 = 5`
- `320x176_4f_frame_num8`: strict FFmpeg-decodable four-frame SPS/frame-number
  validation, `92,027,135` cycles, `trace_headers` confirming
  8-bit `frame_num` values `0..3` and 9-bit `pic_order_cnt_lsb` values
  `0`, `2`, `4`, and `6`
- `320x176_4f_idr1`: strict FFmpeg-decodable all-IDR validation with
  runtime `idr_interval = 1`, `2,930,968` cycles, `5,652` bytes, and four
  SPS/PPS/IDR groups generated by the RTL path
- `320x176_1f_i16_dcquantfix`: strict FFmpeg-decodable one-frame IDR
  `Intra_16x16` validation on the current tree, `796,556` cycles, `1,147`
  bytes, RTL PSNR avg `69.336543`, RTL SSIM all `0.999940`
- `320x176_4f_i16_dcquantfix_clean`: strict FFmpeg-decodable all-IDR
  `Intra_16x16` validation on the current tree, `3,186,164` cycles, `4,588`
  bytes, RTL PSNR avg `69.336543`, RTL SSIM all `0.999940`
- `ipcm_320x176_1f`: strict FFmpeg-decodable forced-`I_PCM` IDR validation on
  the RTL byte path, `242,396` cycles, `84,963` bytes, and decoded YUV exactly
  matching the `320x176` source frame byte-for-byte
- `ipcm_320x176_4f`: strict FFmpeg-decodable four-frame forced-`I_PCM`
  all-IDR validation on the RTL byte path, `969,524` cycles, `339,852` bytes,
  packaged MP4 output, and decoded YUV exactly matching the first four source
  frames byte-for-byte
- `ipcm_32x16_1f_422`: strict FFmpeg-decodable forced-`I_PCM` IDR validation
  at `32x16`, `8-bit 4:2:2`, `3,651` cycles, `1,071` bytes, High 4:2:2
  profile MP4 output, and decoded YUV exactly matching the source frame
  byte-for-byte
- `ipcm_p_32x16_2f`: strict FFmpeg-decodable two-frame validation with frame
  `0` on the IDR `I_PCM` path and frame `1` on the P-slice `I_PCM` path,
  `59,889` cycles, `1,595` bytes, packaged MP4 output, and decoded YUV exactly
  matching both source frames byte-for-byte
- `ipcm_32x16_1f_10b_latched`: strict FFmpeg-decodable forced-`I_PCM` IDR
  validation at `32x16`, `10-bit 4:2:0`, `5,965` cycles, `1,007` bytes, and
  decoded YUV exactly matching the source frame byte-for-byte
- `ipcm_32x16_1f_10b_422_latched`: strict FFmpeg-decodable forced-`I_PCM` IDR
  validation at `32x16`, `10-bit 4:2:2`, `7,885` cycles, `1,327` bytes, and
  decoded YUV exactly matching the source frame byte-for-byte
- `ipcm_p_32x16_2f_10b_latched`: strict FFmpeg-decodable two-frame validation
  with frame `0` on the IDR `I_PCM` path and frame `1` on the P-slice `I_PCM`
  path at `32x16`, `10-bit 4:2:0`, `59,645` cycles, `1,980` bytes, and decoded
  YUV exactly matching both source frames byte-for-byte
- `ipcm_p_32x16_2f_10b_422_latched`: strict FFmpeg-decodable two-frame
  validation with frame `0` on the IDR `I_PCM` path and frame `1` on the
  P-slice `I_PCM` path at `32x16`, `10-bit 4:2:2`, `62,973` cycles, `2,620`
  bytes, and decoded YUV exactly matching both source frames byte-for-byte
- `ipcm_32x16_1f_444`: strict FFmpeg-decodable forced-`I_PCM` IDR validation at
  `32x16`, `8-bit 4:4:4`, `5,065` cycles, `1,583` bytes, profile
  `High 4:4:4 Predictive`, and decoded YUV exactly matching the source frame
  byte-for-byte
- `ipcm_p_32x16_2f_444`: strict FFmpeg-decodable two-frame validation with
  frame `0` on the IDR `I_PCM` path and frame `1` on the P-slice `I_PCM` path
  at `32x16`, `8-bit 4:4:4`, `64,387` cycles, `3,132` bytes, and decoded YUV
  exactly matching both source frames byte-for-byte
- `ipcm_32x16_1f_10b_444`: strict FFmpeg-decodable forced-`I_PCM` IDR
  validation at `32x16`, `10-bit 4:4:4`, `11,723` cycles, `1,968` bytes,
  profile `High 4:4:4 Predictive`, and decoded YUV exactly matching the source
  frame byte-for-byte
- `ipcm_p_32x16_2f_10b_444`: strict FFmpeg-decodable two-frame validation with
  frame `0` on the IDR `I_PCM` path and frame `1` on the P-slice `I_PCM` path
  at `32x16`, `10-bit 4:4:4`, `69,371` cycles, `3,901` bytes, and decoded YUV
  exactly matching both source frames byte-for-byte
- `bslice_ipcm_320x176_2f`: strict FFmpeg-decodable two-frame validation with
  frame `0` on the IDR `I_PCM` path and frame `1` on the non-reference
  `B`-slice `I_PCM` path at `320x176`, `484,677` cycles, `169,893` bytes,
  packaged MP4 output, exact decoded-YUV match, and `trace_headers`
  confirmation of `nal_ref_idc = 0` and `slice_type = 1` on the second picture
- `bslice_inter_320x176_2f`: strict FFmpeg-decodable two-frame validation with
  frame `0` on the IDR `I_PCM` path and frame `1` on the non-reference
  inter-coded `B_L0_16x16` path at `320x176`, `10,048,976` cycles, `85,388`
  bytes total, exact decoded-YUV match, `trace_headers` confirmation of
  `nal_ref_idc = 0` and `slice_type = 1` on the second picture, and a `425`
  byte second-slice payload with `ENABLE_P_IPCM=0`
- `bref_inter_320x176_3f`: strict FFmpeg-decodable three-frame validation with
  frame `0` on the IDR `I_PCM` path and frames `1` and `2` on the reference-`B`
  / `BREF` inter-coded `B_L0_16x16` path at `320x176`, `19,820,383` cycles,
  `85,799` bytes total, exact decoded-YUV match, and `trace_headers`
  confirmation that both non-IDR B pictures use `nal_ref_idc = 2` with
  `slice_type = 1`
- `reorderbgop_320x176_3f`: strict FFmpeg-decodable reordered B-GOP validation
  at `320x176`, encode order `0,2,1`, `20,392,794` cycles, RTL PSNR avg
  `30.444086`, RTL SSIM all `0.774761`, with the reference P picture carrying
  `frame_num = 1`, `pic_order_cnt_lsb = 4` and the following non-reference B
  picture carrying `frame_num = 1`, `pic_order_cnt_lsb = 2`,
  `output/validation_reorderbgop_320x176_3f.h264`, and
  `output/validation_reorderbgop_320x176_3f.mp4`
- `reorderbgop_320x176_5f`: strict FFmpeg-decodable reordered B-GOP validation
  at `320x176`, encode order `0,2,1,4,3`, `62,543,870` cycles, decode-only
  strict check closed cleanly, `output/validation_reorderbgop_320x176_5f.h264`,
  and `output/validation_reorderbgop_320x176_5f.mp4`
- `bl1_320x176_3f`: strict FFmpeg-decodable reordered B-GOP validation at
  `320x176`, encode order `0,2,1`, `37,760,283` cycles, `3,797` bytes, RTL
  PSNR avg `30.444086`, RTL SSIM all `0.774761`,
  `output/validation_bl1_320x176_3f.h264`, and
  `output/validation_bl1_320x176_3f.mp4`
- `bl1_force_32x16_3f`: strict FFmpeg-decodable forced-`B_L1_16x16`
  reordered-B validation at `32x16`, `3` frames, `129,691` cycles, `98` bytes,
  `output/validation_bl1_force_32x16_3f.h264`, and
  `output/validation_bl1_force_32x16_3f.mp4`, with simulator logging showing
  `b_l1_mbs=2` on the B picture
- `reorderbrefgop2_320x176_5f`: strict FFmpeg-decodable reordered all-`BREF`
  validation at `320x176`, encode order `0,2,1,4,3`, `93,507,221` cycles,
  `4,761` bytes, `output/validation_reorderbrefgop2_320x176_5f.h264`, and
  `output/validation_reorderbrefgop2_320x176_5f.mp4`, with simulator logging
  showing every non-IDR picture emitted as `BREF`
- `weightedb_bl1_32x16_3f`: strict FFmpeg-decodable weighted-B reordered
  validation at `32x16`, `3` frames, `130,005` cycles,
  `output/validation_weightedb_bl1_32x16_3f.h264`, and
  `output/validation_weightedb_bl1_32x16_3f.mp4`, with `trace_headers`
  confirming `weighted_bipred_idc = 1` in PPS and B-slice `pred_weight_table`
  entries for both `List0` and `List1`
- `autobi_qpelprobe_320x176_5f`: strict FFmpeg-decodable current-tree reordered
  all-`BREF` validation at `320x176`, `5` frames, `93,525,885` cycles,
  `4,761` bytes, RTL PSNR avg `32.579259`, RTL SSIM all `0.863570`,
  `output/validation_autobi_qpelprobe_320x176_5f.h264`, and
  `output/validation_autobi_qpelprobe_320x176_5f.json`, with simulator logging
  showing `b_bi_mbs=0` on the three non-IDR pictures
- `forcebbi_qpelprobe_32x16_3f`: strict FFmpeg-decodable current-tree
  forced-`B_BI_16x16` reordered-B validation at `32x16`, `3` frames,
  `130,715` cycles, `150` bytes, RTL PSNR avg `30.120198`, RTL SSIM all
  `0.774794`, `output/validation_forcebbi_qpelprobe_32x16_3f.h264`, and
  `output/validation_forcebbi_qpelprobe_32x16_3f.json`
- `forcebbi_qpelprobe_320x176_5f`: strict FFmpeg-decodable current-tree
  forced-`B_BI_16x16` reordered all-`BREF` validation at `320x176`, `5`
  frames, `91,943,969` cycles, `10,281` bytes, RTL PSNR avg `15.889197`,
  RTL SSIM all `0.837371`,
  `output/validation_forcebbi_qpelprobe_320x176_5f.h264`, and
  `output/validation_forcebbi_qpelprobe_320x176_5f.json`, with simulator
  logging showing `b_bi_mbs=220` on the last two non-IDR pictures
- `forcebbi_qpelcmp_weightedbi5_320x176_5f`: strict FFmpeg-decodable
  current-tree forced-`B_BI_16x16` reordered all-`BREF` validation at
  `320x176`, `5` frames, non-default explicit B weights (`5` with denom `2`),
  `92,405,579` cycles, `19,258` bytes, RTL PSNR avg `32.63735`, RTL SSIM all
  `0.864016`,
  `output/validation_forcebbi_qpelcmp_weightedbi5_320x176_5f.h264`, and
  `output/validation_forcebbi_qpelcmp_weightedbi5_320x176_5f.json`, with
  simulator logging showing `b_bi_mbs=220` on the last two non-IDR pictures
  and `output/validation_forcebbi_qpelcmp_weightedbi5_320x176_5f.trace.txt`
  confirming
  `weighted_bipred_idc = 1`, `luma_log2_weight_denom = 2`,
  `chroma_log2_weight_denom = 2`, and list0/list1 luma/chroma weights of `5`
- `bmultiref_ref1win_32x16_5f_ipcmrefs`: strict FFmpeg-decodable current-tree
  forced-`B_BI_16x16` reordered-B validation at `32x16`, `5` frames, exact
  IDR/P `I_PCM` references, `329,003` cycles, `1,408` bytes,
  `output/validation_bmultiref_ref1win_32x16_5f_ipcmrefs.h264`, and
  `output/validation_bmultiref_ref1win_32x16_5f_ipcmrefs.json`, with
  `b_mode_summary` showing `total_bi = 4` and `total_l0_refgt0 = 2`, proving
  the limited reordered multi-ref `B_BI_16x16` path can now emit nonzero
  `List0 ref_idx` values
- `autobi_qpelcmp_weightedbi5_320x176_5f`: strict FFmpeg-decodable
  current-tree reordered all-`BREF` validation at `320x176`, `5` frames,
  non-default explicit B weights (`5` with denom `2`), `97,793,335` cycles,
  `18,872` bytes, RTL PSNR avg `32.421436`, RTL SSIM all `0.86191`,
  `output/validation_autobi_qpelcmp_weightedbi5_320x176_5f.h264`, and
  `output/validation_autobi_qpelcmp_weightedbi5_320x176_5f.json`, with
  simulator logging still showing `b_l1_mbs=220` on the two middle non-IDR
  pictures and `b_bi_mbs=0` across the run
- `bdirect_force_32x16_3f`: strict FFmpeg-decodable forced-`B_DIRECT_16x16`
  reordered-`BREF` validation at `32x16`, `3` frames, `131,068` cycles,
  `265` bytes, RTL PSNR avg `27.36622`, RTL SSIM all `0.554193`,
  `output/validation_bdirect_force_32x16_3f.h264`,
  `output/validation_bdirect_force_32x16_3f.mp4`, and simulator logging
  showing `b_direct_mbs=2` on the last picture
- `bdirect_force_320x176_5f`: strict FFmpeg-decodable forced-`B_DIRECT_16x16`
  reordered all-`BREF` validation at `320x176`, `5` frames, `97,641,789`
  cycles, `25,505` bytes, RTL PSNR avg `13.670634`, RTL SSIM all `0.668749`,
  `output/validation_bdirect_force_320x176_5f.h264`,
  `output/validation_bdirect_force_320x176_5f.mp4`, and simulator logging
  showing `b_direct_mbs=220` on each non-IDR picture
- `bdirect_auto_probe_32x16_3f`: strict FFmpeg-decodable non-forced auto
  `B_DIRECT_16x16` reordered-B validation at `32x16`, `3` frames, `130,756`
  cycles, `122` bytes, RTL PSNR avg `30.120198`, RTL SSIM all `0.774794`,
  `output/validation_bdirect_auto_probe_32x16_3f.h264`, and simulator logging
  showing `b_direct_mbs=1` on the last picture
- `bdirect_auto_probe_320x176_5f`: strict FFmpeg-decodable non-forced
  decode-only reordered all-`BREF` validation at `320x176`, `5` frames,
  `93,162,228` cycles, `4,666` bytes,
  `output/validation_bdirect_auto_probe_320x176_5f.h264`, and simulator
  logging showing nonzero `b_direct_mbs` across all three non-IDR pictures
  (`219`, `148`, and `31`)
- `bdirect_bskip_auto_320x176_5f_json`: strict FFmpeg-decodable non-forced
  decode-only reordered all-`BREF` validation at `320x176`, `5` frames,
  `93,158,455` cycles, `4,541` bytes,
  `output/validation_bdirect_bskip_auto_320x176_5f_json.h264`, with staged
  JSON `b_mode_summary` reporting `frames_with_skip=3`, `total_skip=393`,
  `max_skip=219`, `frames_with_direct=3`, and simulator skip counts of
  `219`, `148`, and `26` across the three non-IDR pictures
- `temporal_direct_force_32x16_3f`: strict FFmpeg-decodable forced
  temporal-direct reordered-B validation at `32x16`, `3` frames, `131,063`
  cycles, `263` bytes, `output/validation_temporal_direct_32x16_3f.h264`,
  `output/validation_temporal_direct_32x16_3f.json`, and header-trace proof of
  `direct_spatial_mv_pred_flag = 0` with `b_direct_mbs=2`
- `temporal_direct_force_320x176_3f`: strict FFmpeg-decodable decode-only
  forced temporal-direct reordered-B validation at `320x176`, `3` frames,
  `37,905,407` cycles, `21,423` bytes,
  `output/validation_temporal_direct_320x176_3f.h264`,
  `output/validation_temporal_direct_320x176_3f.json`, and header-trace proof
  of `direct_spatial_mv_pred_flag = 0` with `b_direct_mbs=220`
- `temporal_direct_bref_force_32x16_3f`: strict FFmpeg-decodable forced
  temporal-direct reordered-`BREF` validation at `32x16`, `3` frames,
  `131,068` cycles, `265` bytes,
  `output/validation_temporal_direct_bref_fix_32x16_3f.h264`,
  `output/validation_temporal_direct_bref_fix_32x16_3f.json`, and header-trace
  proof that both non-IDR `BREF` slices emit `direct_spatial_mv_pred_flag = 0`
  while the last picture reports `b_direct_mbs=2`
- `temporal_direct_bref_force_320x176_3f`: strict FFmpeg-decodable decode-only
  forced temporal-direct reordered-`BREF` validation at `320x176`, `3`
  frames, `37,905,588` cycles, `21,534` bytes,
  `output/validation_temporal_direct_bref_fix_320x176_3f.h264`,
  `output/validation_temporal_direct_bref_fix_320x176_3f.json`, and
  header-trace proof that both non-IDR `BREF` slices emit
  `direct_spatial_mv_pred_flag = 0` while the last picture reports
  `b_direct_mbs=220`
- `temporal_direct_ref1_32x16_7f`: strict FFmpeg-decodable decode-only forced
  temporal-direct reordered-B validation at `32x16`, `7` frames, `608,780`
  cycles, `525` bytes, `output/validation_temporal_direct_ref1_32x16_7f.h264`,
  `output/validation_temporal_direct_ref1_32x16_7f.json`, and header-trace
  proof that the B slices emit `direct_spatial_mv_pred_flag = 0`, with
  `b_mode_summary` reporting `total_direct=6` and `total_direct_refgt0=4`,
  proving the current limited temporal-direct path can now consume nonzero
  future-picture `List0 ref_idx` mappings
- `temporal_direct_auto_32x16_7f_autoslice`: strict FFmpeg-decodable
  decode-only auto temporal-direct reordered-B validation at `32x16`, `7`
  frames, `608,096` cycles, `274` bytes,
  `output/validation_temporal_direct_b_auto_32x16_7f_autoslice.h264`,
  `output/validation_temporal_direct_b_auto_32x16_7f_autoslice.json`, with
  header-trace proof that the reordered B slices emit
  `direct_spatial_mv_pred_flag = 0`, with the RTL auto-switching the slice to
  temporal direct and `b_mode_summary` reporting `total_direct=4` and
  `total_direct_refgt0=4`
- `temporal_direct_bref_auto_refslotl0_32x16_7f_autoslice`: strict
  FFmpeg-decodable decode-only auto temporal-direct reordered-`BREF`
  validation at `32x16`, `7` frames, `707,309` cycles, `253` bytes,
  `output/validation_temporal_direct_bref_auto_from_refslotl0_32x16_7f_autoslice.h264`,
  `output/validation_temporal_direct_bref_auto_from_refslotl0_32x16_7f_autoslice.json`,
  with header-trace proof that the first reordered `BREF` ref slot stays
  `direct_spatial_mv_pred_flag = 1` while the later reordered `BREF` slices
  auto-switch to `0`, the future reordered `BREF` ref slot pinned to
  `B_L0_16x16`, and the later reordered `BREF` slice auto-switching to
  temporal direct,
  `b_mode_summary` reporting `total_l0_refgt0=6`, `total_direct=2`, and
  `total_direct_refgt0=2`
- `temporal_direct_bref_mixed_refslotl0_32x16_7f`: strict FFmpeg-decodable
  decode-only mixed reordered-`BREF` validation at `32x16`, `7` frames,
  `718,775` cycles, `505` bytes,
  `output/validation_temporal_direct_bref_mixed_refslotl0_32x16_7f.h264`,
  `output/validation_temporal_direct_bref_mixed_refslotl0_32x16_7f.json`,
  and simulator-log proof that reordered reference slots ran with
  `force_l0=1` while reordered B slots ran with
  `force_direct=1 force_direct_temporal=1`, with `b_mode_summary`
  reporting `total_l0_refgt0=6`, `total_direct=4`, and
  `total_direct_refgt0=2`, proving the current limited temporal-direct path
  can now consume nonzero future `List0` mappings coming from reordered
  `BREF` reference slots instead of only future P pictures
- `temporal_direct_bref_mixed_refslotl0_320x176_3f`: strict
  FFmpeg-decodable decode-only mixed reordered-`BREF` validation at
  `320x176`, `3` frames, `37,905,588` cycles, `21,534` bytes,
  `output/validation_temporal_direct_bref_mixed_refslotl0_320x176_3f.h264`,
  `output/validation_temporal_direct_bref_mixed_refslotl0_320x176_3f.json`,
  and simulator-log proof that the same slot-scoped forcing holds on the
  larger real clip, with the middle reordered `BREF` picture pinned to
  `B_L0_16x16` and the final reordered `BREF` picture pinned to temporal
  direct
- `temporal_direct_bref_mixed_refslotbi_32x16_5f`: strict FFmpeg-decodable
  decode-only mixed reordered-`BREF` validation at `32x16`, `5` frames,
  `404,704` cycles, `1,521` bytes,
  `output/validation_temporal_direct_bref_mixed_refslotbi_32x16_5f.h264`,
  `output/validation_temporal_direct_bref_mixed_refslotbi_32x16_5f.json`,
  and simulator-log proof that reordered reference slots ran with
  `force_bi=1` while reordered B slots ran with
  `force_direct=1 force_direct_temporal=1`, with `b_mode_summary`
  reporting `total_bi=6`, `total_l0_refgt0=4`, `total_direct=4`, and
  `total_direct_refgt0=2`, proving the current limited temporal-direct path
  can also consume nonzero future `List0` mappings coming from reordered
  `BREF` reference slots that were themselves coded on the limited
  `B_BI_16x16` path
- `temporal_direct_bref_bi_ref1_l1src_32x16_5f`: strict FFmpeg-decodable
  decode-only mixed reordered-`BREF` validation at `32x16`, `5` frames,
  `404,573` cycles, `1,537` bytes,
  `output/validation_temporal_direct_bref_bi_ref1_l1src_32x16_5f.h264`, and
  `output/validation_temporal_direct_bref_bi_ref1_l1src_32x16_5f.json`, with
  reordered reference slots pinned to `B_BI_16x16` and reordered B slots
  pinned to temporal direct, and `b_mode_summary` reporting `total_direct=4`
  plus `total_direct_l1src=2`, proving the current limited temporal-direct
  path can now derive direct macroblocks from colocated `List1` on future
  reordered-`BREF` BI pictures
- `temporal_direct_bref_bi_ref1_l1src_320x176_5f`: strict FFmpeg-decodable
  decode-only mixed reordered-`BREF` validation at `320x176`, `5` frames,
  `119,819,413` cycles, `152,910` bytes,
  `output/validation_temporal_direct_bref_bi_ref1_l1src_320x176_5f.h264`,
  `output/validation_temporal_direct_bref_bi_ref1_l1src_320x176_5f.json`, and
  header-trace proof that the later reordered `BREF` slices still emit
  `direct_spatial_mv_pred_flag = 0`, with `b_mode_summary` reporting
  `total_direct=607`, `total_direct_refgt0=357`, and `total_direct_l1src=30`
- `temporal_direct_bref_auto_from_refslotbi_32x16_5f_l1src`: strict
  FFmpeg-decodable decode-only mixed reordered-`BREF` auto probe at `32x16`,
  `5` frames, `400,988` cycles, `1,497` bytes,
  `output/validation_temporal_direct_bref_auto_from_refslotbi_32x16_5f_l1src.h264`,
  and `output/validation_temporal_direct_bref_auto_from_refslotbi_32x16_5f_l1src.json`,
  showing that the new colocated-`List1` temporal-direct path is present but
  the non-forced selector on this tiny probe still prefers `B_BI_16x16` /
  `B_L1_16x16`, with `total_direct=0`
- `temporal_direct_bref_auto_from_refslotbi_320x176_5f_l1src`: strict
  FFmpeg-decodable decode-only mixed reordered-`BREF` auto validation at
  `320x176`, `5` frames, `121,592,814` cycles, `150,112` bytes,
  `output/validation_temporal_direct_bref_auto_from_refslotbi_320x176_5f_l1src.h264`,
  `output/validation_temporal_direct_bref_auto_from_refslotbi_320x176_5f_l1src.json`,
  and header-trace proof that the later reordered `BREF` slices still emit
  `direct_spatial_mv_pred_flag = 0`, with `b_mode_summary` reporting
  `total_direct=337`, `total_direct_refgt0=167`, and `total_direct_l1src=170`
- `temporal_direct_bref_mixed_refslotl1_32x16_7f_inter_fix1`: strict
  FFmpeg-decodable decode-only mixed reordered-`BREF` validation at `32x16`,
  `7` frames, `724,380` cycles, `1,821` bytes,
  `output/validation_temporal_direct_bref_mixed_refslotl1_32x16_7f_inter_fix1.h264`,
  `output/validation_temporal_direct_bref_mixed_refslotl1_32x16_7f_inter_fix1.json`,
  and header-trace proof in
  `output/validation_temporal_direct_bref_mixed_refslotl1_32x16_7f_inter_fix1.trace_headers.txt`
  that later reordered `BREF` slices emit `direct_spatial_mv_pred_flag = 0`,
  with reordered reference slots pinned to `B_L1_16x16`, reordered B slots
  pinned to temporal direct, and `b_mode_summary` reporting `total_l1=4`,
  `total_direct=6`, and `total_direct_l1src=4`
- `temporal_direct_bref_auto_from_refslotl1_32x16_7f_inter_fix1`: strict
  FFmpeg-decodable decode-only mixed reordered-`BREF` auto validation at
  `32x16`, `7` frames, `739,640` cycles, `1,587` bytes,
  `output/validation_temporal_direct_bref_auto_from_refslotl1_32x16_7f_inter_fix1.h264`,
  `output/validation_temporal_direct_bref_auto_from_refslotl1_32x16_7f_inter_fix1.json`,
  and header-trace proof in
  `output/validation_temporal_direct_bref_auto_from_refslotl1_32x16_7f_inter_fix1.trace_headers.txt`
  that the first reordered `BREF` slice stays spatial while later ones switch
  to temporal direct, with `b_mode_summary` reporting `total_l1=6`,
  `total_direct=2`, and `total_direct_l1src=2`
- `temporal_direct_bref_mixed_refslotl1_320x176_7f_fix1`: strict
  FFmpeg-decodable decode-only mixed reordered-`BREF` validation at
  `320x176`, `7` frames, `233,261,934` cycles, `129,453` bytes,
  `output/validation_temporal_direct_bref_mixed_refslotl1_320x176_7f_fix1.h264`,
  `output/validation_temporal_direct_bref_mixed_refslotl1_320x176_7f_fix1.json`,
  and simulator-log proof that reordered reference slots pinned to
  `B_L1_16x16` can drive later temporal-direct slices through colocated
  `List1`, with `b_mode_summary` reporting `total_l1=20`, `total_direct=1080`,
  `total_direct_refgt0=640`, and `total_direct_l1src=220`
- `temporal_direct_bref_auto_from_refslotl1_320x176_7f_fix1`: strict
  FFmpeg-decodable decode-only mixed reordered-`BREF` auto validation at
  `320x176`, `7` frames, `233,399,683` cycles, `97,921` bytes,
  `output/validation_temporal_direct_bref_auto_from_refslotl1_320x176_7f_fix1.h264`,
  `output/validation_temporal_direct_bref_auto_from_refslotl1_320x176_7f_fix1.json`,
  and simulator-log proof that the non-forced selector now reaches the same
  colocated-`List1` temporal-direct path on the larger clip, with
  `b_mode_summary` reporting `total_l1=341`, `total_bi=759`,
  `total_direct=727`, `total_direct_refgt0=413`, and `total_direct_l1src=314`
- `bl0_force_ref1_32x16_7f_ipcmrefs`: strict FFmpeg-decodable decode-only
  reordered-B validation at `32x16`, `7` frames, exact IDR/P `I_PCM`
  references, `581,041` cycles, `4,234` bytes,
  `output/validation_bl0_force_ref1_32x16_7f_ipcmrefs.h264`, and
  `output/validation_bl0_force_ref1_32x16_7f_ipcmrefs.json`, with
  `force_b_l0=1` pinning the current limited `B_L0_16x16` path and
  `b_mode_summary` reporting `total_l0_refgt0=2` while `total_bi=0`,
  `total_direct=0`, and `total_direct_refgt0=0`, proving the plain
  `B_L0_16x16` path can emit nonzero past-reference indices without BI/direct
  fallback
- `bdirect_auto_weighted_32x16_3f`: strict FFmpeg-decodable weighted
  non-forced auto `B_DIRECT_16x16` reordered-B validation at `32x16`, `3`
  frames, `131,078` cycles, `180` bytes, RTL PSNR avg `30.158513`, RTL SSIM
  all `0.775715`, `output/validation_bdirect_auto_weighted_32x16_3f.h264`,
  and simulator logging showing `b_direct_mbs=1` on the last picture
- `bdirect_bskip_auto_32x16_3f`: strict FFmpeg-decodable non-forced auto
  reordered-`BREF` validation at `32x16`, `3` frames, `130,749` cycles,
  `122` bytes, RTL PSNR avg `30.120198`, RTL SSIM all `0.774794`,
  `output/validation_bdirect_bskip_auto_32x16_3f.h264`, and simulator
  logging showing `skip_mbs=1`, `b_l1_mbs=2`, and `b_direct_mbs=1` on the
  last picture, proving the current limited `B_DIRECT_16x16` path can collapse
  to B-slice skip syntax on a zero-residual macroblock
- `weightedp_small_32x16_2f`: strict FFmpeg-decodable small weighted-P
  validation at `32x16`, `2` frames, `51,117` cycles, `112` bytes, RTL PSNR
  avg `28.420753`, RTL SSIM all `0.66449`, and
  `output/validation_weightedp_small_32x16_2f.h264`
- `32x16_2f_444_ipcm_scripted`: strict staged validation through
  `scripts/validate_clip.py` with `--enable-idr-ipcm 1 --enable-p-ipcm 1`
  at `32x16`, `8-bit 4:4:4`, packaged MP4 output, and JSON summary in
  `output/validation_32x16_2f_444_ipcm_scripted.json`
- `320x176_4f_decodeonly`: strict FFmpeg-decodable multi-frame decode-only
  validation on the current tree, `92,028,425` cycles, `1,912` bytes, paired
  staged `.build.log` / `.sim.log`, JSON validation-mode recording, and
  packaged MP4 output without PSNR / SSIM, x264, or side-by-side PNG work
- `320x176_24f_tefix`: strict FFmpeg-decodable multi-frame validation on the
  current tree, `640,575,297` cycles, RTL PSNR avg `43.767484`, RTL SSIM all
  `0.989193`
- `320x176_10f_multiref3`: strict FFmpeg-decodable three-reference P-slice
  validation on the current tree, `367,542,946` cycles, `15,781` bytes, SPS
  `max_num_ref_frames = 3`, RTL PSNR avg `45.752063`, RTL SSIM all `0.994913`
- `320x176_24f_multiref3`: strict FFmpeg-decodable three-reference P-slice
  validation on the current tree, `913,475,277` cycles, `51,219` bytes, later
  P-slices with `num_ref_idx_l0_active_minus1 = 2`, RTL PSNR avg `43.7528`,
  RTL SSIM all `0.989176`
- `320x176_4f_multiref4`: strict FFmpeg-decodable four-reference P-slice
  validation on the current tree, `92,027,039` cycles, `5,058` bytes, SPS
  `max_num_ref_frames = 4`, RTL PSNR avg `43.883472`, RTL SSIM all `0.995357`
- `320x176_6f_multiref4`: strict FFmpeg-decodable four-reference P-slice
  validation on the current tree, `217,593,800` cycles, `7,844` bytes, later
  P-slices with `num_ref_idx_l0_active_minus1 = 3`, RTL PSNR avg `45.207556`,
  RTL SSIM all `0.996333`
- `320x176_4f_weightedp`: strict FFmpeg-decodable weighted-P validation on the
  RTL path, Main profile stream, RTL PSNR avg `25.806041`, RTL SSIM all
  `0.333568`
- `320x176_4f_pskip3`: strict FFmpeg-decodable deferred-inter-header /
  zero-residual-`P_SKIP` validation on the RTL path, `92,028,425` cycles,
  `1,912` bytes, RTL PSNR avg `43.883472`, RTL SSIM all `0.995357`, and
  simulator-reported `P_SKIP` counts of `123`, `152`, and `134` across the
  three validated P-frames
- `320x176_4f_multiref`: earlier strict FFmpeg-decodable two-reference
  P-slice validation on the RTL path, `50,611,399` cycles, SPS
  `max_num_ref_frames = 2`, later P-slices with
  `num_ref_idx_active_override_flag = 1`, RTL PSNR avg `25.806041`, RTL SSIM
  all `0.333568`
- `720p_4f_intra_tl_modes`: `522,499,266` cycles, RTL PSNR avg `43.871116`,
  RTL SSIM all `0.995403`
- `320x176_1f_i16x16_fix2`: earlier FFmpeg-decodable `Intra_16x16` smoke
  before the luma-DC quant/dequant fix, RTL PSNR avg `25.8060`, RTL SSIM all
  `0.333568`

Recent correctness fix:

- a `720p` chroma corruption issue was traced to raw input address overflow on
  the Cr fetch path and fixed by widening the raw input address width
- `Intra_4x4` most-probable-mode derivation at picture edges was fixed to
  follow the unavailable-neighbor rule, removing the earlier FFmpeg decode
  errors on the `320x176` multi-frame regression
- two-reference P-slice `ref_idx_l0` signaling was fixed to use standards-
  correct `TE(v)` coding for the two-ref case instead of `UE(v)`, removing the
  later-frame parser corruption on the strict `320x176` multi-frame path
- the current tree now advertises `max_num_ref_frames = 3` and can emit later
  P-slices with `num_ref_idx_l0_active_minus1 = 2`
- the current tree now advertises `max_num_ref_frames = 4` and later P-slices
  can emit `num_ref_idx_l0_active_minus1 = 3`
- the current inter path already performs quarter-pel luma refinement and
  chroma fractional interpolation after the integer-pel motion-estimation pass
- SPS `level_idc` is now selected from frame size and configured frame rate
  instead of the earlier small hardcoded level split
- SPS VUI timing fields are now emitted from RTL for the configured frame rate
- SPS VUI bitstream-restriction fields now describe the current no-reorder,
  four-reference subset
- baseline/main SPS now uses `pic_order_cnt_type = 0`, and the current RTL
  IDR / P slice headers emit `pic_order_cnt_lsb`
- the current RTL path now advertises `log2_max_frame_num_minus4 = 4` and
  emits 8-bit `frame_num` values in slice headers
- the testbench and `validate_clip.py` now accept a runtime `idr_interval`;
  `1` forces every frame to IDR, and `0` means only the first frame is IDR
- deferred inter headers and FIFO discard now prevent illegal zero-residual
  CAVLC payloads from leaking after `cbp=0` or `P_SKIP`, fixing the first
  broken zero-residual inter-header attempt
- the `Intra_16x16` IDR path now emits mb_type values that match the residual
  syntax the RTL actually outputs, removing the earlier first-row FFmpeg decode
  failure at `MB 2 0`
- the current RTL writer now supports `I_PCM` macroblocks on the IDR path,
  byte-aligns with `pcm_alignment_zero_bit`, emits raw luma / Cb / Cr samples
  through the RTL byte path itself, and decodes back to an exact byte-for-byte
  match on the validated `320x176 4:2:0` and `32x16 4:2:2` all-IDR cases
- the `I_PCM` source path is now latched in `rtl/h264_encoder_top.v` before the
  bitstream emit begins, which closes the earlier corruption where the live
  fetch bus could be overwritten by the next macroblock during `10-bit` sample
  emission
- the current tree now supports `I_PCM` on the IDR path and the current
  P-slice intra path for `8-bit` and `10-bit` builds in both `4:2:0` and
  `4:2:2`, and the checked-in `tb/Makefile` exposes `ENABLE_IDR_IPCM`,
  `ENABLE_P_IPCM`, `IPCM_SAD_THRESHOLD`, and `INTER_SAD_THRESHOLD` so the path
  can be reproduced without raw `EXTRA_VERILATOR_ARGS`
- the current tree now also validates exact RTL-owned `4:4:4 I_PCM` output on
  the IDR path and current P-slice intra path at `32x16` for `8-bit` and
  `10-bit`, with SPS/profile signaling decoding as `High 4:4:4 Predictive`
- the `4:4:4` inter path must use the ChromaArrayType `3`
  `coded_block_pattern` table rather than the `4:2:x` inter code; the current
  RTL writer now emits the correct full-residual inter code on that path, and
  focused strict-decode reruns ending on the old bad picture re-close at
  `320x176` for extracted `2`-frame and `4`-frame clips
- the current reordered B path now carries explicit list0/list1 neighbor MV
  state, list-specific MVD syntax, per-list quarter-pel luma refinement,
  qpel-aware final `B_L0` / `B_L1` / `B_BI` luma comparison on the dual-ref B
  path, and explicit weighted bipred combine on the limited `B_BI_16x16`
  path, which re-opened forced strict-decode validation at `32x16` and
  `320x176`; the real `320x176` weighted reordered clip still selects
  `B_L1_16x16` automatically rather than `B_BI_16x16`
- `scripts/validate_clip.py` and `scripts/rtl_runner.py` now expose
  `ENABLE_IDR_IPCM`, `ENABLE_P_IPCM`, `IPCM_SAD_THRESHOLD`, and
  `INTER_SAD_THRESHOLD` so staged validation can reproduce the `I_PCM` paths
  instead of relying on ad-hoc `make` commands
- the `Intra_16x16` luma-DC path in `h264_luma_dc.v` now keeps the forward
  rounded Hadamard output, uses the DC-specific forward quant step, latches
  the input payload for execution, and restores the missing scaling-list
  factor on inverse dequant; that re-closed the current IDR-path
  `Intra_16x16` reconstruction quality on the validated `320x176` all-IDR run

Recent intra prediction expansion:

- completed the full `Intra_4x4` directional mode set
- added `Intra_16x16` luma prediction and luma DC transform / syntax handling
- fixed the top-right neighbor fetch bug in the directional `Intra_4x4` path

Recent entropy coding groundwork:

- added `rtl/h264_cabac_core.v` implementing the standardized CABAC arithmetic
  decision / bypass / terminate core as standalone RTL
- CABAC context selection, syntax binarization, and full bitstream integration
  are still open

Recent multi-reference expansion:

- expanded the banked P-slice reference path from two forward refs to up to
  four forward refs on the current tree
- SPS now advertises `max_num_ref_frames = 4`
- later P-slices now emit `num_ref_idx_active_override_flag = 1` and
  `num_ref_idx_l0_active_minus1 = 3` when the fourth reference is active
- inter macroblock headers now emit RTL-owned `ref_idx_l0` syntax for the
  current four-reference P-slice path

## Requirements

Current development and validation flows assume:

- Linux shell execution, preferably WSL Ubuntu
- Verilator
- FFmpeg / `ffprobe`
- Python 3
- `make`
- `24` build threads by default on this machine

Docker is required only for the containerized smoke path.

## Build And Run

The checked-in shell scripts are Linux-oriented. Use all available host threads
by default for build and simulation-related work unless a debugging task
clearly needs fewer. On this machine, that means `24` threads.

Be wary of simulation times. Start with the smallest valid case that can prove
the issue before scaling up.

### Build

```bash
cd tb
make -j24 WIDTH=320 HEIGHT=176 BIT_DEPTH=8 CHROMA_FORMAT_IDC=1
```

### Run

```bash
./Vh264_encoder_top \
  +frames=24 \
  +idr_interval=12 \
  +timeout=500000000 \
  +input=/path/to/input.yuv \
  +output=/path/to/output.h264
```

Set `+idr_interval=1` to force every frame to IDR, or `+idr_interval=0` to
use only the first frame as IDR and keep later frames as `P`.

### Package To MP4

```bash
python3 scripts/package_mp4.py output.h264 output.mp4 --fps 24 --width 320 --height 176
```

### Helper Scripts

- `./build_run.sh` builds the simulator, runs the RTL encoder on an existing
  YUV input, and optionally packages the result to MP4
- `./run.sh` downloads the sample clip, extracts raw YUV, builds the simulator,
  runs the encoder, and packages MP4 output
- `./docker_run.sh` runs the one-frame Docker smoke path
- `python3 scripts/regress_smoke_matrix.py` runs the current fast
  strict-decode/profile smoke regression matrix on generated tiny `I_PCM`
  inputs and emits paired `.build.log` / `.sim.log` artifacts per case
  - use `--case <name>` to run only specific smoke cases; filtered runs write
    `output/smoke_matrix_summary_filtered.json`
- `python3 scripts/trace_header_matrix.py` regenerates focused smoke rows and
  asserts decoded `trace_headers` fields for profile selection, VUI/HRD,
  CABAC PPS selection, B/reorder signaling, and `transform_8x8` exclusions
  - use `--case <name>` for a focused row; filtered runs write
    `output/header_trace_matrix_summary_filtered.json`
- `python3 scripts/validate_clip.py` runs staged multi-frame validation with
  a clean staged rebuild, strict decode checking, paired `.build.log` /
  `.sim.log` artifacts, MP4 output, and comparison metrics
  - use `--decode-only` to keep longer strict-decode regressions cheap when
    you do not need PSNR / SSIM, x264 reference encode, or side-by-side PNGs
  - use `--skip-metrics`, `--skip-x264`, `--skip-compare`, or `--skip-mp4`
    when you want finer control over which post-sim stages run

### Quick Start

Run a small local case from an existing YUV input:

```bash
WIDTH=320 HEIGHT=176 FRAMES=1 YUV_INPUT=/path/to/input.yuv ./build_run.sh
```

Run the current sample flow:

```bash
./run.sh
```

Run the Docker smoke path:

```bash
./docker_run.sh
```

See [docker/README.md](docker/README.md) for the container behavior and
current limitations.

Run a faster strict-decode-only validation without metrics or x264:

```bash
python3 scripts/validate_clip.py \
  --width 320 \
  --height 176 \
  --frames 24 \
  --label fastdecode_320x176_24f \
  --decode-only
```

## Reference Discipline

- always consult the H.264 / AVC specification and relevant reference material
- expected local spec path: `references/itu/T-REC-H.264-202408-I.pdf`
- expected local software baseline path: `references/software/x264/`
- local reference PDFs are for development use and are not committed by default
- local software reference trees are for development use and are not committed
  by default
- prefer primary references over memory
- do not guess unless there is no practical alternative after checking the
  spec, repository, local `x264` reference tree, and available references

## Local-Only Artifacts

This repo is configured to keep generated and private development assets out of
version control.

Committed:

- RTL, testbench, scripts, Docker files, and documentation
- lightweight README files that describe local-only folders

Ignored by default:

- source media and extracted YUV inputs in `data/`
- generated `.h264`, `.mp4`, decoded `.yuv`, logs, and comparison images in
  `output/`
- local spec PDFs and reference archives in `references/`
- local software encoder source checkouts such as `references/software/x264/`
- build outputs, caches, and common editor junk
