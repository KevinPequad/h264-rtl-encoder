#!/usr/bin/env python3
"""Convert raw YUV420 file to memory files for Verilator simulation."""

import sys
import os
WIDTH = int(os.getenv('WIDTH', '320'))
HEIGHT = int(os.getenv('HEIGHT', '176'))
FRAME_SIZE = WIDTH * HEIGHT * 3 // 2  # YUV420

def convert_yuv_to_memh(input_path, output_dir, max_frames=None):
    """Convert YUV420 raw file to Verilog $readmemh compatible hex file."""
    file_size = os.path.getsize(input_path)
    total_frames = file_size // FRAME_SIZE

    if max_frames:
        total_frames = min(total_frames, max_frames)

    print(f"Converting {total_frames} frames from {input_path}")
    print(f"Frame size: {WIDTH}x{HEIGHT} YUV420 = {FRAME_SIZE} bytes")

    os.makedirs(output_dir, exist_ok=True)

    with open(input_path, 'rb') as f:
        # Write all frames to a single hex file
        hex_path = os.path.join(output_dir, 'raw_frames.hex')
        with open(hex_path, 'w') as hf:
            for frame_idx in range(total_frames):
                frame_data = f.read(FRAME_SIZE)
                if len(frame_data) < FRAME_SIZE:
                    break
                for byte in frame_data:
                    hf.write(f'{byte:02x}\n')

        print(f"Wrote {hex_path}")

    # Write metadata header for C++
    header_path = os.path.join(output_dir, 'frame_info.h')
    with open(header_path, 'w') as hf:
        hf.write(f'#ifndef FRAME_INFO_H\n')
        hf.write(f'#define FRAME_INFO_H\n')
        hf.write(f'#define FRAME_WIDTH {WIDTH}\n')
        hf.write(f'#define FRAME_HEIGHT {HEIGHT}\n')
        hf.write(f'#define FRAME_SIZE {FRAME_SIZE}\n')
        hf.write(f'#define NUM_FRAMES {total_frames}\n')
        hf.write(f'#define LUMA_SIZE {WIDTH * HEIGHT}\n')
        hf.write(f'#define CHROMA_SIZE {WIDTH * HEIGHT // 4}\n')
        hf.write(f'#endif\n')

    print(f"Wrote {header_path}")
    print(f"Total memory required: {total_frames * FRAME_SIZE} bytes")

if __name__ == '__main__':
    input_path = sys.argv[1] if len(sys.argv) > 1 else '/workspace/data/raw_frames.yuv'
    output_dir = sys.argv[2] if len(sys.argv) > 2 else '/workspace/data'
    max_frames = int(sys.argv[3]) if len(sys.argv) > 3 else None

    if not os.path.isfile(input_path):
        print(f"ERROR: input file not found: {input_path}", file=sys.stderr)
        sys.exit(1)

    if os.path.getsize(input_path) == 0:
        print(f"ERROR: input file is empty: {input_path}", file=sys.stderr)
        sys.exit(1)

    convert_yuv_to_memh(input_path, output_dir, max_frames)
