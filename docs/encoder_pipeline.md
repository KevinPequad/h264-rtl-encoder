# H.264 Encoder Pipeline

This project is building a Verilator-driven H.264 encoder around a memory-backed
RTL pipeline. The current target clip is the first 20 seconds of Big Buck Bunny
at `320x176`, `24 fps`, `yuv420p`.

## Stage Plan

1. Source ingest
   Download `BigBuckBunny.mp4`, trim to 20 seconds, force `24 fps`, and decode
   to planar `YUV420`.

2. Raw frame memory
   Load the decoded YUV bytes into a simple byte-vector memory in the Verilator
   harness. The encoder reads from this memory through `raw_mem_addr/raw_mem_data`.

3. Macroblock fetch
   Read one `16x16` luma macroblock plus `8x8` `Cb` and `Cr` blocks from frame
   memory.

4. Intra prediction
   Build spatial predictors from top/left neighbors.

5. Transform and quantization
   Run the integer transform, quantizer, and zig-zag scan on each residual
   block.

6. Entropy coding
   Feed quantized coefficients into the CAVLC encoder and assemble an Annex B
   H.264 bitstream in output memory.

7. Reconstruction
   Inverse-quantize, inverse-transform, and reconstruct samples so future
   macroblocks can use the correct neighbors.

8. Output memory
   Store encoded bytes in a bitstream memory vector and flush them to
   `encoded.h264` after simulation.

9. MP4 packaging
   Read the encoded memory dump from Python and remux it into MP4, preferring
   `ffmpeg` on Ubuntu and falling back to PyAV or a manual MP4 writer.

## Current Implementation Status

- Implemented
  - Memory-backed Verilator harness for raw input and encoded output.
  - Luma fetch, intra prediction, transform, quantization, zig-zag, CAVLC,
    inverse path, and neighbor reconstruction.
  - Multi-frame simulation loop and Python-based MP4 packaging.

- Current simplifications
  - Fixed `320x176` geometry and fixed `QP=26`.
  - Intra-only, all-IDR stream.
  - Hard-coded SPS/PPS/slice-header generation.
  - Chroma fetch exists, but chroma coding is not implemented in the active RTL.

- Current architectural gap
  - The predictor and emitted syntax are not fully aligned yet. The active RTL
    computes a macroblock-wide DC predictor, while the bitstream path emits
    `I_4x4`-style macroblock syntax. Closing that gap is the main blocker to a
    standards-clean H.264 elementary stream.

## Build Order From Here

1. Keep the current memory-backed simulation flow stable for the full 480-frame
   clip.
2. Align prediction mode and emitted syntax:
   either implement true sequential `Intra_4x4` prediction, or move the syntax
   and residual coding path to a coherent `Intra_16x16` design.
3. Add chroma prediction, transform, and entropy coding.
4. Replace hard-coded headers with parameterized SPS/PPS and validated slice
   syntax.
5. Add decoder-side validation on Ubuntu with `ffprobe`/`ffmpeg`.
