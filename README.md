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
- full directional `Intra_4x4` mode support in RTL
- `Intra_16x16` luma prediction and syntax support in RTL
- current IDR path now routes through RTL `Intra_16x16` macroblock coding
  rather than leaving the feature smoke-only
- limited quarter-pel luma refinement and chroma fractional interpolation on the
  current inter path
- validated multi-frame subset runs plus current-tree `Intra_16x16` decode smoke
- Docker one-frame smoke run

Still missing before full-standard completion, using the current `x264`
software encoder as the implementation baseline:

- CABAC syntax integration into the final RTL bitstream path
- `B-frames`
- weighted bipred and direct-mode handling
- broader standards-complete sub-pel motion handling across richer inter modes
- broader inter partition and transform coverage including `8x8dct`-class tools
- `4:4:4` support
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
- SPS VUI bitstream-restriction signaling in RTL for the current no-reorder,
  four-reference subset
- PPS generation in RTL
- IDR slice header generation in RTL
- non-IDR slice header generation in RTL
- `pic_order_cnt_lsb` signaling in RTL on IDR and non-IDR slice headers
- 8-bit `frame_num` signaling and 9-bit `pic_order_cnt_lsb` signaling on
  IDR and non-IDR slice headers
- macroblock header generation in RTL
- RBSP trailing bits in RTL
- emulation-prevention byte insertion in RTL
- CAVLC entropy coding in RTL
- CAVLC for luma coefficients
- CAVLC for chroma DC coefficients
- CAVLC for chroma AC coefficients
- I-frame support
- P-frame support
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
- quarter-pel luma refinement on the current `16x16` P-macroblock inter path
- luma inter prediction from the previous reconstructed frame
- chroma fractional interpolation on the current inter path
- weighted P prediction for inter luma and chroma on the RTL path
- `pred_weight_table` slice signaling in RTL for weighted P slices
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
- standalone CABAC arithmetic coding core in `rtl/h264_cabac_core.v`
- parameterized resolution
- parameterized bit depth
- parameterized chroma format

Implemented now relative to the chosen `x264` baseline:

- Annex B bitstream ownership in RTL
- parameter-set and slice-header ownership in RTL
- CAVLC-based coefficient coding in RTL
- I and P picture flow
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

## What Is Not Done Yet

Important non-completion gaps:

- `CABAC` arithmetic coding is not yet wired into the final slice syntax path
- `B-frames` are not implemented
- weighted bipred / `B`-picture weighted prediction is not implemented
- direct motion-vector prediction modes are not implemented
- reference-picture management beyond the current four-reference P-slice subset
  is not implemented
- broader full-standard sub-pel motion handling beyond the current `16x16`
  quarter-pel luma path is not implemented
- broader inter partition coverage and `8x8dct`-class transform support are not
  implemented
- broader `4:4:4` chroma-format support beyond the current `I_PCM` path is not
  implemented
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
- reproducible smoke matrix for fast parser/profile sanity on generated tiny inputs
- multi-frame validation at `320x176`
- multi-frame validation at `1280x720`
- PSNR / SSIM comparison scripts
- x264 reference comparison scripts
- side-by-side decoded-vs-source image generation
- staged clean-build log capture for reproducible validation runs
- simulator log and cycle-count capture for regressions
- runtime-configurable `idr_interval` support in the testbench and validation
  scripts
- fast strict-decode-only validation mode in `validate_clip.py` for longer
  regressions that do not need metrics or x264 comparison
- RTL-owned `P_SKIP` skip-run generation validated on the current P-slice path

Measured validation points:

- `docker_320x176_1f`: `816,975` cycles
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
- `320x176_1f_i16idr2`: strict FFmpeg-decodable one-frame IDR
  `Intra_16x16` validation on the current tree, `791,490` cycles, RTL PSNR avg
  `25.806041`, RTL SSIM all `0.333568`
- `320x176_4f_i16idr`: strict FFmpeg-decodable short-GOP validation with an
  IDR `Intra_16x16` first frame on the current tree, `91,031,284` cycles,
  `3,751` bytes, RTL PSNR avg `31.628391`, RTL SSIM all `0.829910`
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
- `320x176_1f_i16x16_fix2`: FFmpeg-decodable current-tree `Intra_16x16` smoke,
  RTL PSNR avg `25.8060`, RTL SSIM all `0.333568`

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
- `scripts/validate_clip.py` and `scripts/rtl_runner.py` now expose
  `ENABLE_IDR_IPCM`, `ENABLE_P_IPCM`, `IPCM_SAD_THRESHOLD`, and
  `INTER_SAD_THRESHOLD` so staged validation can reproduce the `I_PCM` paths
  instead of relying on ad-hoc `make` commands
- the `Intra_16x16` DC inverse path in `h264_luma_dc.v` now preserves the full
  Hadamard dynamic range instead of truncating the top bits before inverse
  scaling
- the current `Intra_16x16` IDR path is decodable on the RTL byte stream, but
  it is still not visually correct enough to count as a finished quality path

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
- `python3 scripts/regress_smoke_matrix.py` runs the current fast parser/profile
  smoke regression matrix on generated tiny inputs and now emits paired
  `.build.log` / `.sim.log` artifacts per case
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
