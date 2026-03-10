# Repository Status

This document inventories what is currently implemented in the repository, what
has been validated, and what is still missing before the project can be called
a full-standard H.264 / AVC encoder.

## Summary

Current state:

- RTL-owned H.264 Annex B bitstream generation works for a constrained subset
- the current flow can produce FFmpeg-decodable `.h264` and packaged `.mp4`
- multi-frame validation has been completed at `320x176` and `1280x720`
- the strict current-tree `320x176` validation path now passes after extending
  the P-slice path to four forward refs and re-closing decode on that banked
  path
- the current P-slice path now supports zero-residual inter-MB header deferral
  and RTL-owned `P_SKIP` skip-run generation
- the repository is still not complete as a full H.264 standard encoder

Completion is still blocked by major missing features including CABAC syntax
integration, `B-frames`, weighted bipred / direct-mode support, broader
partition/tool coverage, deblocking, and the final long-run target.

## Source Inventory

### Top-Level Files

| Path | Purpose |
| --- | --- |
| `README.md` | Public project overview, run instructions, and high-level status |
| `STATUS.md` | Detailed implementation and gap inventory |
| `AGENTS.md` | Working rules for autonomous development in this repo |
| `build_run.sh` | Build simulator, run encoder, optionally package MP4 |
| `run.sh` | Download sample media, prep YUV, build, run, and package |
| `docker_run.sh` | Linux Docker smoke-run entrypoint |
| `docker_run.bat` | Windows helper for the Docker smoke path |
| `.gitignore` | Ignore local artifacts and generated junk |
| `.gitattributes` | Line-ending and binary handling rules |
| `.editorconfig` | Editor defaults for consistent formatting |

### RTL Modules

| Path | Purpose |
| --- | --- |
| `rtl/h264_encoder_top.v` | Top-level pipeline and frame / macroblock orchestration |
| `rtl/h264_fetch.v` | Input frame fetch and plane address handling |
| `rtl/h264_me.v` | Motion estimation for the current inter path |
| `rtl/h264_intra_pred.v` | Full `Intra_4x4` directional prediction logic |
| `rtl/h264_intra16_pred.v` | `Intra_16x16` luma prediction mode search |
| `rtl/h264_transform.v` | Forward integer transform |
| `rtl/h264_quantize.v` | Quantization |
| `rtl/h264_zigzag.v` | Zigzag coefficient scan |
| `rtl/h264_cabac_core.v` | Standalone CABAC arithmetic coding core |
| `rtl/h264_cavlc.v` | CAVLC syntax generation |
| `rtl/h264_chroma_dc.v` | Chroma DC transform support |
| `rtl/h264_luma_dc.v` | `Intra_16x16` luma DC transform support |
| `rtl/h264_inverse_quant.v` | Inverse quantization |
| `rtl/h264_inverse_transform.v` | Inverse transform |
| `rtl/h264_reconstruct.v` | Reconstruction and reference update path |
| `rtl/h264_bitstream.v` | Annex B writer, parameter sets, slice syntax, output bytes |

### Testbench And Utilities

| Path | Purpose |
| --- | --- |
| `tb/Makefile` | Verilator build and run flow |
| `tb/tb_h264_encoder.cpp` | Main testbench harness |
| `scripts/download_and_decode.sh` | Sample media fetch and YUV extraction |
| `scripts/yuv_to_mem.py` | YUV-to-memory conversion helper |
| `scripts/package_mp4.py` | Remux raw H.264 into MP4 |
| `scripts/calc_psnr.py` | Metric helper |
| `scripts/rtl_runner.py` | Staged runner for clean simulator execution |
| `scripts/regress_smoke_matrix.py` | Reproducible smoke regression matrix |
| `scripts/validate_clip.py` | Multi-frame validation, strict decode gating, optional decode-only fast path, and comparison flow |
| `docker/Dockerfile` | Containerized smoke-run environment |
| `docker/run_one_frame.sh` | One-frame Docker smoke flow |
| `tools/parse_422.c` | Small debug/parser utility |

### Local-Only Directories

| Path | Contents |
| --- | --- |
| `data/` | Source media, extracted YUV inputs, generated hex data |
| `output/` | Generated streams, MP4s, logs, JSON summaries, decoded output, comparisons |
| `references/` | Spec PDFs and local development references |

These directories are intentionally treated as local-only working areas and are
ignored by default except for their small README files.

## Software Baseline

The normative reference remains the H.264 / AVC specification at
`references/itu/T-REC-H.264-202408-I.pdf`.

For practical implementation comparison, the current software baseline for this
repo is the official VideoLAN `x264` encoder source tree at:

- `references/software/x264`

Local checkout used for the current docs update:

- commit: `0480cb05fa188d37ae87e8f4fd8f1aea3711f7ee`
- date: `2025-08-31`

Why this baseline was chosen:

- it is a current and widely used H.264 encoder implementation
- its public source clearly exposes the standard feature classes this repo still
  needs to close
- it is a better practical implementation target than treating the spec PDF
  alone as the gap checklist

Feature evidence in the local `x264` source:

- `x264.c` exposes `--profile`, `--level`, `--bframes`, `--b-pyramid`, `--ref`,
  `--no-deblock`, `--direct`, `--weightp`, `--me`, `--subme`, and
  `--no-cabac`
- `x264.h` exposes `I420`, `I422`, `I444`, high-depth pixel formats, and
  `IDR`, `P`, `BREF`, and `B` picture types

## Implemented Features

Current implemented features in the RTL encoder, based on the actual pipeline
in `rtl/h264_encoder_top.v` and bitstream writer in `rtl/h264_bitstream.v`:

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
- inter / intra macroblock decisioning for P-frames
- slice-level active reference override and per-macroblock `ref_idx_l0` syntax
- standards-correct `TE(v)` coding for `ref_idx_l0` in the two-reference
  P-slice case, with `UE(v)` fallback when three references are active
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
- diamond-style luma ME search
- quarter-pel luma refinement on the current `16x16` P-macroblock inter path
- luma inter prediction from the previous reconstructed frame
- chroma fractional interpolation on the current inter path
- weighted P prediction for inter luma and chroma on the RTL path
- `pred_weight_table` slice signaling in RTL for weighted P slices
- full directional `Intra_4x4` mode support
- `Intra_16x16` luma prediction with `Vertical`, `Horizontal`, `DC`, and
  `Plane` mode search
- chroma intra prediction: DC-style path
- `4x4` H.264 integer transform
- inverse transform path
- quantization path
- inverse quantization path
- zigzag scan path
- reconstruction loop in RTL
- reference-frame writeback for reconstructed luma
- reference-frame writeback for reconstructed chroma
- standalone CABAC arithmetic coder core RTL
- parameterized resolution
- parameterized bit depth
- parameterized chroma format

Implemented now relative to the chosen `x264` baseline:

- Annex B bitstream generation owned by RTL
- SPS / PPS / slice-header / macroblock-header ownership in RTL
- CAVLC entropy path owned by RTL
- I-picture and P-picture coding
- full `Intra_4x4` directional luma mode coverage
- `Intra_16x16` luma prediction and syntax support
- current IDR-path `Intra_16x16` macroblock coding through the RTL byte stream
- up-to-four-reference P-slice inter coding with integer-pel search and
  current quarter-pel luma refinement
- zero-residual inter-MB handling and `P_SKIP` skip-run ownership on the RTL
  path
- weighted P prediction and `pred_weight_table` signaling on the RTL path
- `8-bit` and `10-bit` support for `4:2:0` and `4:2:2`

## Supported And Smoke-Verified Modes

- `8-bit 4:2:0`
- `8-bit 4:2:2`
- `10-bit 4:2:0`
- `10-bit 4:2:2`

## Validated Capabilities

Verified validation and tooling coverage around the encoder flow:

- FFmpeg-decodable RTL-generated `.h264`
- MP4 remux of the RTL-generated stream
- Docker one-frame smoke run producing RTL-generated `.h264` and `.mp4`
- reproducible smoke matrix for fast parser/profile sanity on generated tiny
  inputs
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
  regression runs that do not need metrics or x264 comparison
- RTL-owned `P_SKIP` skip-run generation validated on the current P-slice path

Measured validation points:

- `docker_320x176_1f`: `816,975` cycles
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
- `320x176_4f_decodeonly`: strict FFmpeg-decodable multi-frame decode-only
  validation on the current tree, `92,028,425` cycles, `1,912` bytes, paired
  staged `.build.log` / `.sim.log`, JSON validation-mode recording, and
  packaged MP4 output without PSNR / SSIM, x264, or side-by-side PNG work
- `320x176_10f_tefix`: strict FFmpeg-decodable current-tree validation,
  `253,064,186` cycles, RTL PSNR avg `45.745576`, RTL SSIM all `0.994893`
- `320x176_24f_tefix`: strict FFmpeg-decodable current-tree validation,
  `640,575,297` cycles, RTL PSNR avg `43.767484`, RTL SSIM all `0.989193`
- `320x176_10f_multiref3`: strict FFmpeg-decodable three-reference P-slice
  validation, `367,542,946` cycles, `15,781` bytes, SPS
  `max_num_ref_frames = 3`, RTL PSNR avg `45.752063`, RTL SSIM all `0.994913`
- `320x176_24f_multiref3`: strict FFmpeg-decodable three-reference P-slice
  validation, `913,475,277` cycles, `51,219` bytes, later P-slices with
  `num_ref_idx_l0_active_minus1 = 2`, RTL PSNR avg `43.7528`, RTL SSIM all
  `0.989176`
- `320x176_4f_multiref4`: strict FFmpeg-decodable four-reference P-slice
  validation, `92,027,039` cycles, `5,058` bytes, SPS
  `max_num_ref_frames = 4`, RTL PSNR avg `43.883472`, RTL SSIM all `0.995357`
- `320x176_6f_multiref4`: strict FFmpeg-decodable four-reference P-slice
  validation, `217,593,800` cycles, `7,844` bytes, later P-slices with
  `num_ref_idx_l0_active_minus1 = 3`, RTL PSNR avg `45.207556`, RTL SSIM all
  `0.996333`
- `320x176_4f_weightedp`: strict FFmpeg-decodable weighted-P validation on the
  RTL path, Main profile stream, RTL PSNR avg `25.806041`, RTL SSIM all
  `0.333568`
- `320x176_4f_pskip3`: strict FFmpeg-decodable deferred-inter-header /
  zero-residual-`P_SKIP` validation on the RTL path, `92,028,425` cycles,
  `1,912` bytes, RTL PSNR avg `43.883472`, RTL SSIM all `0.995357`, and
  simulator-reported `P_SKIP` counts of `123`, `152`, and `134` across the
  three validated P-frames
- `320x176_4f_multiref`: earlier strict FFmpeg-decodable two-reference P-slice
  validation on the RTL path, `50,611,399` cycles, SPS
  `max_num_ref_frames = 2`, later P-slices with
  `num_ref_idx_active_override_flag = 1`, RTL PSNR avg `25.806041`, RTL SSIM
  all `0.333568`
- `720p_24f`: `4,096,671,438` cycles, RTL PSNR avg `41.759917`, RTL SSIM all
  `0.995232`
- `320x176_1f_i16x16_fix2`: current-tree FFmpeg-decodable `Intra_16x16`
  smoke, RTL PSNR avg `25.8060`, RTL SSIM all `0.333568`

Current verified milestone outputs:

- `320x176`, `24` frames: packaged MP4 from RTL-generated H.264
- `1280x720`, `24` frames: packaged MP4 from RTL-generated H.264
- Docker one-frame `320x176` smoke run: packaged MP4 from RTL-generated H.264

## Known Correctness Notes

- a `720p` chroma corruption issue was traced to raw input address overflow on
  the Cr plane fetch path and fixed by widening the raw input address width
- a directional `Intra_4x4` top-right reference fetch bug was fixed in
  `rtl/h264_encoder_top.v`
- the multi-reference P-slice path was fixed to encode `ref_idx_l0` with
  standards-correct `TE(v)` coding when two refs are active, removing the
  later-frame parser corruption seen in strict `320x176` multi-frame decode
- the current tree now advertises `max_num_ref_frames = 3` and later P-slices
  can emit `num_ref_idx_l0_active_minus1 = 2`
- the current tree now advertises `max_num_ref_frames = 4` and later P-slices
  can emit `num_ref_idx_l0_active_minus1 = 3`
- the current inter path already performs quarter-pel luma refinement and
  chroma fractional interpolation after the integer-pel ME pass
- SPS `level_idc` is now selected from frame size and configured frame rate
  instead of the earlier hardcoded split
- SPS VUI timing fields are now emitted from RTL for the configured frame rate
- SPS VUI bitstream-restriction fields now describe the current no-reorder,
  four-reference subset
- baseline/main SPS now uses `pic_order_cnt_type = 0`, and the current RTL
  IDR / P slice headers emit `pic_order_cnt_lsb`
- the current RTL path now advertises `log2_max_frame_num_minus4 = 4` and
  emits 8-bit `frame_num` values in slice headers
- the testbench and `validate_clip.py` now accept a runtime `idr_interval`;
  `1` forces every frame to IDR, and `0` means only the first frame is IDR
- `validate_clip.py` now supports `--decode-only` plus granular skip flags for
  metrics, x264 reference encode, side-by-side PNG generation, and MP4
  packaging so longer strict-decode regressions can stay cheaper
- the `Intra_16x16` IDR path now emits mb_type values that match the residual
  syntax the RTL actually outputs, removing the earlier first-row FFmpeg decode
  failure at `MB 2 0`
- the `Intra_16x16` DC inverse path in `rtl/h264_luma_dc.v` now preserves the
  full Hadamard dynamic range instead of truncating the top bits before
  inverse scaling
- the current `Intra_16x16` IDR path is now decodable on the RTL byte stream,
  but it is still not visually correct enough to count as a finished quality
  path
- deferred inter headers and FIFO discard now prevent illegal zero-residual
  CAVLC payloads from leaking after `cbp=0` or `P_SKIP`, which is what made
  the earlier zero-residual inter-header attempt invalid

## Not Done Yet

Important missing features, so this does not get confused with a full-standard
H.264 encoder yet:

- CABAC context modelling, syntax binarization, and final bitstream-path
  integration
- `B-frames`
- weighted bipred / `B`-picture weighted prediction
- direct motion-vector prediction modes
- reference-picture management beyond the current four-reference P-slice subset
- broader full-standard sub-pel motion handling beyond the current `16x16`
  quarter-pel luma path
- broader inter partition coverage and `8x8dct`-class transform support
- `4:4:4` chroma support
- full in-loop deblocking engine
- full-standard profile / level / tool coverage

Still missing relative to the chosen `x264` software baseline:

- final CABAC slice integration instead of the current standalone arithmetic
  core only
- `B` / `BREF` picture handling and the associated reference management
- reference-picture management beyond the current four-reference P-slice subset
- weighted bipred support beyond the current weighted P path
- direct prediction modes
- broader sub-pel motion estimation / compensation and richer mode decision
- broader partition / transform coverage including `8x8dct`-class tools
- `I444` / `4:4:4` format coverage
- in-loop deblocking
- enough profile / level / tool coverage to stop calling the repo a subset

Additional project-level open work:

- the Docker flow is still a smoke path rather than the primary long-run path
- the repo still has Verilator width and lint warnings outside the validated
  bitstream path
- the final `240`-frame `1280x720 @ 24 fps` run is not closed yet
- full-standard completion still requires closing the broader H.264 feature
  gaps rather than freezing the current subset

## Completion Criteria

The encoder should only be marked complete once:

- the final decoded `1280x720 @ 24 fps` Big Buck Bunny output is produced
- the stream came from the RTL byte path itself
- the remaining gaps against full H.264 standard support are closed
- the final result is visually verified and decodable in FFmpeg

## Development Rules That Matter

- use the H.264 spec and primary references before making codec decisions
- use the local `x264` source tree as the default software encoder comparison
  baseline after consulting the spec
- keep the encoder end to end through the RTL bitstream path
- use all `24` threads by default for build and simulation work on this machine
- be wary of simulation times and prove fixes on small cases first
