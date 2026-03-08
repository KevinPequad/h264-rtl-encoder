# Docker

This directory contains the containerized smoke-run path for the H.264 RTL
encoder.

Included files:

- `Dockerfile` installs the minimum toolchain needed for the current smoke run
- `run_one_frame.sh` downloads Big Buck Bunny if needed, extracts a small raw
  YUV clip, builds the Verilator testbench, runs the RTL byte-stream path, and
  remuxes the result to MP4

Current intent:

- provide a reproducible one-frame sanity check
- confirm the RTL-generated `.h264` stream can be produced and packaged in a
  clean environment

Current limitation:

- this is a smoke path, not yet the primary flow for larger multi-frame or
  long-duration validation runs

From the repo root:

```bash
./docker_run.sh
```

Environment variables such as `WIDTH`, `HEIGHT`, `FRAMES`, `FPS`, and
`TIMEOUT` can be passed through when needed.
