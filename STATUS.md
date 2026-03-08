# Repository Status

This document inventories what is currently implemented in the repository, what
has been validated, and what is still missing before the project can be called
a full-standard H.264 / AVC encoder.

## Summary

Current state:

- RTL-owned H.264 Annex B bitstream generation works for a constrained subset
- the current flow can produce FFmpeg-decodable `.h264` and packaged `.mp4`
- multi-frame validation has been completed at `320x176` and `1280x720`
- the repository is still not complete as a full H.264 standard encoder

Completion is still blocked by major missing features including `CABAC`,
`B-frames`, multiple references, broader prediction coverage, sub-pel motion
handling, deblocking, and the final long-run target.

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
| `rtl/h264_intra_pred.v` | Current intra prediction logic |
| `rtl/h264_transform.v` | Forward integer transform |
| `rtl/h264_quantize.v` | Quantization |
| `rtl/h264_zigzag.v` | Zigzag coefficient scan |
| `rtl/h264_cavlc.v` | CAVLC syntax generation |
| `rtl/h264_chroma_dc.v` | Chroma DC transform support |
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
| `scripts/validate_clip.py` | Multi-frame validation and comparison flow |
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

## Implemented Features

Current implemented features in the RTL encoder, based on the actual pipeline
in `rtl/h264_encoder_top.v` and bitstream writer in `rtl/h264_bitstream.v`:

- end-to-end RTL-owned H.264 Annex B byte-stream generation
- SPS generation in RTL
- PPS generation in RTL
- IDR slice header generation in RTL
- non-IDR slice header generation in RTL
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
- one forward reference frame
- inter / intra macroblock decisioning for P-frames
- motion-vector-difference syntax for supported P macroblocks
- integer-pel motion estimation
- fixed search range motion estimation
- diamond-style luma ME search
- luma inter prediction from the previous reconstructed frame
- chroma inter prediction in RTL
- luma intra prediction: `4x4` DC mode
- chroma intra prediction: DC-style path
- `4x4` H.264 integer transform
- inverse transform path
- quantization path
- inverse quantization path
- zigzag scan path
- reconstruction loop in RTL
- reference-frame writeback for reconstructed luma
- reference-frame writeback for reconstructed chroma
- parameterized resolution
- parameterized bit depth
- parameterized chroma format

## Supported And Smoke-Verified Modes

- `8-bit 4:2:0`
- `8-bit 4:2:2`
- `10-bit 4:2:0`
- `10-bit 4:2:2`

## Validated Capabilities

Verified validation and tooling coverage around the current encoder flow:

- FFmpeg-decodable RTL-generated `.h264`
- MP4 remux of the RTL-generated stream
- Docker one-frame smoke run producing RTL-generated `.h264` and `.mp4`
- reproducible smoke matrix
- multi-frame validation at `320x176`
- multi-frame validation at `1280x720`
- PSNR / SSIM comparison scripts
- x264 reference comparison scripts
- side-by-side decoded-vs-source image generation
- simulator log and cycle-count capture for regressions

Measured validation points:

- `docker_320x176_1f`: `816,975` cycles
- `320x176_24f`: `249,438,699` cycles, RTL PSNR avg `44.661152`, RTL SSIM all
  `0.992607`
- `720p_24f`: `4,096,671,438` cycles, RTL PSNR avg `41.759917`, RTL SSIM all
  `0.995232`

Current verified milestone outputs:

- `320x176`, `24` frames: packaged MP4 from RTL-generated H.264
- `1280x720`, `24` frames: packaged MP4 from RTL-generated H.264
- Docker one-frame `320x176` smoke run: packaged MP4 from RTL-generated H.264

## Known Correctness Notes

- a `720p` chroma corruption issue was traced to raw input address overflow on
  the Cr plane fetch path and fixed by widening the raw input address width

## Not Done Yet

Important missing features, so this does not get confused with a full-standard
H.264 encoder yet:

- `CABAC`
- `B-frames`
- multiple reference pictures
- full sub-pel luma motion compensation path
- broad intra mode coverage
- full in-loop deblocking engine
- full-standard profile / level / tool coverage

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
- keep the encoder end to end through the RTL bitstream path
- use all `24` threads by default for build and simulation work on this machine
- be wary of simulation times and prove fixes on small cases first
