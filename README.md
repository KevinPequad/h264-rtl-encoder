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
- validated `320x176` and `1280x720` multi-frame runs
- Docker one-frame smoke run

Still missing before full-standard completion:

- `CABAC`
- `B-frames`
- multiple reference pictures
- full sub-pel motion handling
- broader intra prediction coverage
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
| `references/` | Local-only codec specs and reference documents |
| `STATUS.md` | Detailed implementation and repository inventory |
| `AGENTS.md` | Project rules for autonomous work in this repository |

## What Is In The Repo Now

Current RTL pipeline:

`fetch -> motion estimation -> prediction -> transform -> quantize -> zigzag -> CAVLC -> inverse quant -> inverse transform -> reconstruct -> bitstream`

Current implemented features:

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
- inter/intra macroblock decisioning for P-frames
- motion-vector-difference syntax for supported P macroblocks
- integer-pel motion estimation
- fixed search range motion estimation
- diamond-style luma motion estimation
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

Supported and smoke-verified modes:

- `8-bit 4:2:0`
- `8-bit 4:2:2`
- `10-bit 4:2:0`
- `10-bit 4:2:2`

## What Is Not Done Yet

Important non-completion gaps:

- `CABAC` is not implemented
- `B-frames` are not implemented
- multiple reference pictures are not implemented
- full sub-pel luma motion compensation is not implemented
- broad intra mode coverage is not implemented
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

Recent correctness fix:

- a `720p` chroma corruption issue was traced to raw input address overflow on
  the Cr fetch path and fixed by widening the raw input address width

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
  +timeout=500000000 \
  +input=/path/to/input.yuv \
  +output=/path/to/output.h264
```

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
- `python3 scripts/regress_smoke_matrix.py` runs the current smoke regression
  matrix
- `python3 scripts/validate_clip.py` runs staged multi-frame validation with
  logs, MP4 output, and comparison metrics

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

## Reference Discipline

- always consult the H.264 / AVC specification and relevant reference material
- expected local spec path: `references/itu/T-REC-H.264-202408-I.pdf`
- local reference PDFs are for development use and are not committed by default
- prefer primary references over memory
- do not guess unless there is no practical alternative after checking the
  spec, repository, and available references

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
- build outputs, caches, and common editor junk
