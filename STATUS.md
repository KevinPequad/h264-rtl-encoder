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
- the current tree now also supports a limited non-reference `B`-slice path on
  intra / `I_PCM` macroblocks
- the current tree now also supports limited non-reference inter-coded
  `B_L0_16x16`, `B_L1_16x16`, and `B_BI_16x16` macroblocks on a reordered
  dual-list `16x16` B path
- the current tree now also supports limited reference-`B` / `BREF`
  `B_L0_16x16`, `B_L1_16x16`, and `B_BI_16x16` pictures on that reordered
  dual-list `16x16` B path
- the repository is still not complete as a full H.264 standard encoder

Completion is still blocked by major missing features including CABAC syntax
integration, broader `B` / `BREF` support, direct-mode support, broader
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
- limited non-reference inter-coded `B_L0_16x16`, `B_L1_16x16`, and
  `B_BI_16x16` support on the current reordered dual-list `16x16` B path
- limited reference-`B` / `BREF` support on the current reordered dual-list
  `B_L0_16x16` / `B_L1_16x16` / `B_BI_16x16` path
- reordered `B`-GOP scheduling support in the testbench / validation flow for
  encode orders such as `0,2,1,4,3`, with non-reference `B` pictures reusing
  the same `frame_num` as the surrounding reference pair while carrying their
  own `pic_order_cnt_lsb`
- current reordered B inter selection can choose past `List0`, future `List1`,
  or bidirectional `B_BI_16x16` prediction per macroblock on the current
  limited reordered dual-list `16x16` B path
- the current limited `B_BI_16x16` path now writes back both motion-vector
  lists into neighbor state and refines each list through the quarter-pel luma
  path before the bidirectional average is formed
- reordered GOP forcing can now emit reference-slot pictures as `BREF` instead
  of `P`, so encode orders such as `0,2,1,4,3` can be driven as all-BREF
  non-IDR GOPs for validation
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
- explicit weighted B prediction on the current single-list reordered B
  subpaths and limited `B_BI_16x16` path, including B-slice
  `pred_weight_table` signaling for `List0` and `List1`
- full directional `Intra_4x4` mode support
- `Intra_16x16` luma prediction with `Vertical`, `Horizontal`, `DC`, and
  `Plane` mode search
- `Intra_16x16` luma-DC CAVLC now derives `nC` from the normal surrounding
  `4x4` nnz context instead of a special neighbor luma-DC count path
- current IDR-path and P-slice intra-path `I_PCM` macroblock coding with raw
  luma / Cb / Cr sample emission owned by the RTL writer
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
- non-reference `B`-picture syntax on the current intra / `I_PCM` path
- limited non-reference `B_L0_16x16`, `B_L1_16x16`, and `B_BI_16x16` inter
  coding on the current reordered dual-list `16x16` B path
- limited reference-`B` / `BREF` picture support on the current reordered
  dual-list `16x16` B path
- explicit weighted prediction on the current single-list reordered B subpaths
- full `Intra_4x4` directional luma mode coverage
- `Intra_16x16` luma prediction and syntax support
- current IDR-path `Intra_16x16` macroblock coding through the RTL byte stream
- current IDR-path and P-slice intra-path `I_PCM` macroblock coding through
  the RTL byte stream
- exact `I_PCM` validation now also covers `4:4:4` on the current IDR and
  P-slice intra path at `32x16` for both `8-bit` and `10-bit`
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

## Validated Capabilities

Verified validation and tooling coverage around the encoder flow:

- FFmpeg-decodable RTL-generated `.h264`
- MP4 remux of the RTL-generated stream
- Docker one-frame smoke run producing RTL-generated `.h264` and `.mp4`
- reproducible smoke matrix for fast strict-decode/profile sanity on generated
  tiny `I_PCM` inputs
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
- simulator-side per-frame `b_l1_mbs` logging so reordered B validation can
  prove that the future-reference `List1` path was actually selected
- simulator-side per-frame `b_bi_mbs` logging so reordered B validation can
  prove that the bidirectional `B_BI_16x16` path was actually selected
- reordered validation can now combine `--reorder-b-gop` and
  `--force-bref-slice` so the reference slots are emitted as `BREF` pictures
- fast strict-decode-only validation mode in `validate_clip.py` for longer
  regression runs that do not need metrics or x264 comparison
- RTL-owned `P_SKIP` skip-run generation validated on the current P-slice path

Measured validation points:

- `docker_320x176_1f`: `816,975` cycles
- `32x16_1f_nonipcm_10b420_main_ncfix`: strict FFmpeg-decodable one-frame
  non-`I_PCM` `10-bit 4:2:0` probe, RTL PSNR avg `7.9009`, RTL SSIM
  `0.345989`
- `32x16_2f_nonipcm_10b420_idr1_ncfix`: strict FFmpeg-decodable two-frame
  all-IDR non-`I_PCM` `10-bit 4:2:0` probe, RTL PSNR avg `9.8896`, RTL SSIM
  `0.469719`
- `32x16_2f_nonipcm_10b420_p_ncfix`: strict FFmpeg-decodable two-frame IDR+P
  non-`I_PCM` `10-bit 4:2:0` probe, RTL PSNR avg `10.9076`, RTL SSIM
  `0.643681`
- `32x16_2f_nonipcm_10b422_idr1_ncfix`: strict FFmpeg-decodable two-frame
  all-IDR non-`I_PCM` `10-bit 4:2:2` probe, RTL PSNR avg `11.1312`, RTL SSIM
  `0.544361`
- `32x16_2f_nonipcm_10b422_p_ncfix`: strict FFmpeg-decodable two-frame IDR+P
  non-`I_PCM` `10-bit 4:2:2` probe, RTL PSNR avg `12.1470`, RTL SSIM
  `0.674832`
- `32x16_2f_nonipcm_8b444_idr1_ncfix`: strict FFmpeg-decodable two-frame
  all-IDR non-`I_PCM` `8-bit 4:4:4` probe, RTL PSNR avg `35.8758`, RTL SSIM
  `0.968007`
- `32x16_2f_nonipcm_8b444_p_ncfix`: strict FFmpeg-decodable two-frame IDR+P
  non-`I_PCM` `8-bit 4:4:4` probe, RTL PSNR avg `24.2915`, RTL SSIM
  `0.827152`
- `32x16_1f_nonipcm_10b444_probe_ncfix`: strict FFmpeg-decodable one-frame
  non-`I_PCM` `10-bit 4:4:4` probe, RTL PSNR avg `38.5022`, RTL SSIM
  `0.897306`
- `32x16_2f_nonipcm_10b444_idr1_ncfix`: strict FFmpeg-decodable two-frame
  all-IDR non-`I_PCM` `10-bit 4:4:4` probe, RTL PSNR avg `38.5059`, RTL SSIM
  `0.899397`
- `32x16_2f_nonipcm_10b444_p_ncfix`: strict FFmpeg-decodable two-frame IDR+P
  non-`I_PCM` `10-bit 4:4:4` probe, RTL PSNR avg `28.3215`, RTL SSIM
  `0.886921`
- `320x176_10f_nonipcm_10b420_p`: strict FFmpeg-decodable ten-frame IDR+P
  non-`I_PCM` `10-bit 4:2:0` validation, `420,156,980` cycles, `11,433`
  bytes
- `320x176_10f_nonipcm_10b422_p`: strict FFmpeg-decodable ten-frame IDR+P
  non-`I_PCM` `10-bit 4:2:2` validation, `422,555,097` cycles, `12,108`
  bytes
- `320x176_10f_nonipcm_8b444_p`: strict FFmpeg-decodable ten-frame IDR+P
  non-`I_PCM` `8-bit 4:4:4` validation, `472,182,097` cycles, `11,736`
  bytes
- `320x176_10f_nonipcm_10b444_p`: strict FFmpeg-decodable ten-frame IDR+P
  non-`I_PCM` `10-bit 4:4:4` validation, `461,752,849` cycles, `11,019`
  bytes
- `320x176_2f_nonipcm_8b444_f16f17_fixcbp`: strict FFmpeg-decodable extracted
  `8-bit 4:4:4` IDR+P validation over source frames `16..17`, `14,159,804`
  cycles, `5,298` bytes
- `320x176_4f_nonipcm_8b444_f14f17_fixcbp`: strict FFmpeg-decodable extracted
  `8-bit 4:4:4` IDR+P validation over source frames `14..17`, `88,709,796`
  cycles, `10,442` bytes
- `320x176_6f_nonipcm_8b444_f12f17_fixcbp`: strict FFmpeg-decodable extracted
  `8-bit 4:4:4` IDR+P validation over source frames `12..17`, `212,087,014`
  cycles, `16,327` bytes
- `320x176_8f_nonipcm_8b444_f10f17_fixcbp`: strict FFmpeg-decodable extracted
  `8-bit 4:4:4` IDR+P validation over source frames `10..17`, `337,204,428`
  cycles, `21,715` bytes
- `320x176_24f_nonipcm_8b444_fixcbp`: strict FFmpeg-decodable full current-tree
  `8-bit 4:4:4` IDR+P validation, `1,350,672,124` cycles, `58,281` bytes
- `320x176_24f_nonipcm_10b444_fixcbp`: strict FFmpeg-decodable full current-tree
  `10-bit 4:4:4` IDR+P validation, `1,336,320,075` cycles, `56,308` bytes
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
  matching the source frame byte-for-byte
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
- `forcebbi_weightedbi5_320x176_5f`: strict FFmpeg-decodable current-tree
  forced-`B_BI_16x16` reordered all-`BREF` validation at `320x176`, `5`
  frames, non-default explicit B weights (`5` with denom `2`), `92,405,579`
  cycles, `19,258` bytes, RTL PSNR avg `32.63735`, RTL SSIM all `0.864016`,
  `output/validation_forcebbi_weightedbi5_320x176_5f.h264`, and
  `output/validation_forcebbi_weightedbi5_320x176_5f.json`, with simulator
  logging showing `b_bi_mbs=220` on the last two non-IDR pictures and
  `output/validation_forcebbi_weightedbi5_320x176_5f.trace.txt` confirming
  `weighted_bipred_idc = 1`, `luma_log2_weight_denom = 2`,
  `chroma_log2_weight_denom = 2`, and list0/list1 luma/chroma weights of `5`
- `32x16_2f_444_ipcm_scripted`: strict staged validation through
  `scripts/validate_clip.py` with `--enable-idr-ipcm 1 --enable-p-ipcm 1`
  at `32x16`, `8-bit 4:4:4`, packaged MP4 output, and JSON summary in
  `output/validation_32x16_2f_444_ipcm_scripted.json`
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
  `4:2:2`, and `tb/Makefile` exposes `ENABLE_IDR_IPCM`, `ENABLE_P_IPCM`,
  `IPCM_SAD_THRESHOLD`, and `INTER_SAD_THRESHOLD` so the path can be
  reproduced without raw `EXTRA_VERILATOR_ARGS`
- the current tree now also validates exact RTL-owned `4:4:4 I_PCM` output on
  the IDR path and current P-slice intra path at `32x16` for `8-bit` and
  `10-bit`, with SPS/profile signaling decoding as `High 4:4:4 Predictive`
- the `4:4:4` inter path must use the ChromaArrayType `3`
  `coded_block_pattern` table rather than the `4:2:x` inter code; the current
  RTL writer now emits the correct full-residual inter code on that path, and
  focused strict-decode reruns ending on the old bad picture re-close at
  `320x176` for extracted `2`-frame and `4`-frame clips
- the current reordered B path now carries explicit list0/list1 neighbor MV
  state, list-specific MVD syntax, per-list quarter-pel luma refinement, and
  explicit weighted bipred combine on the limited `B_BI_16x16` path, which
  re-opened forced strict-decode validation at `32x16` and `320x176`;
  automatic BI mode selection is still not closed on the real `320x176`
  reordered clip
- `scripts/validate_clip.py` and `scripts/rtl_runner.py` now expose
  `ENABLE_IDR_IPCM`, `ENABLE_P_IPCM`, `IPCM_SAD_THRESHOLD`, and
  `INTER_SAD_THRESHOLD` so staged validation can reproduce the `I_PCM` paths
  instead of relying on ad-hoc `make` commands
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
- no broader `B` / `BREF` picture support beyond the current limited
  reordered dual-list `B_L0_16x16` / `B_L1_16x16` / `B_BI_16x16` `16x16` path
- direct motion-vector prediction modes
- reference-picture management beyond the current four-reference P-slice subset
- broader full-standard sub-pel motion handling beyond the current `16x16`
  quarter-pel luma path
- broader inter partition coverage and `8x8dct`-class transform support
- broader `4:4:4` chroma support beyond the current `320x176` strict-decode
  non-`I_PCM` path through `24` frames for `8-bit` and `10-bit`, plus spot
  `I_PCM` coverage
- full in-loop deblocking engine
- full-standard profile / level / tool coverage

Still missing relative to the chosen `x264` software baseline:

- final CABAC slice integration instead of the current standalone arithmetic
  core only
- broader inter-coded `B` / `BREF` picture handling and the associated
  reference management
- reference-picture management beyond the current four-reference P-slice subset
- weighted bipred support beyond the current limited `B_BI_16x16` path
- direct prediction modes
- broader sub-pel motion estimation / compensation and richer mode decision
- broader partition / transform coverage including `8x8dct`-class tools
- broader `I444` / `4:4:4` format coverage beyond the current `320x176`
  strict-decode non-`I_PCM` path through `24` frames for `8-bit` and
  `10-bit`, plus spot `I_PCM` coverage
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
