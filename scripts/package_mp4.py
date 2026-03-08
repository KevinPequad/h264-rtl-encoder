#!/usr/bin/env python3
"""Package raw H.264 Annex B bitstream into MP4 container.

Takes the output of the Verilator H.264 encoder simulation (raw Annex B byte
stream) and wraps it in a standards-compliant MP4/ISO-BMFF container.

The encoder may produce:
    - SPS/PPS for Constrained Baseline, High 10, or High 4:2:2 profiles
    - IDR (type 5) and non-IDR (type 1) slice NAL units
    - Annex B start codes: 0x00 0x00 0x00 0x01

Usage:
    python3 package_mp4.py [input.h264] [output.mp4] [--fps N] [--width W] [--height H]

If FFmpeg is available it is preferred for remuxing. If not, PyAV is tried,
then a pure-Python manual MP4 box builder is used as a final fallback.
"""

import argparse
import os
import shutil
import struct
import subprocess
import sys

# ---------------------------------------------------------------------------
# Annex B parsing
# ---------------------------------------------------------------------------

def parse_annexb_nals(data):
    """Parse an Annex B byte stream into individual NAL units.

    Only matches 4-byte start codes (0x00 0x00 0x00 0x01) to avoid false
    positives from emulation prevention bytes (0x00 0x00 0x03 0x00 0x01).

    Returns a list of ``bytes`` objects, each containing one NAL unit
    (without the start code prefix).
    """
    nals = []
    length = len(data)

    # Find all 4-byte start code positions.
    sc_positions = []
    i = 0
    while i <= length - 4:
        if data[i:i + 4] == b'\x00\x00\x00\x01':
            sc_positions.append(i)
            i += 4  # Skip past this start code
        else:
            i += 1

    # Extract NAL units between consecutive start codes.
    for idx, sc in enumerate(sc_positions):
        start = sc + 4
        end = sc_positions[idx + 1] if idx + 1 < len(sc_positions) else length

        # Strip trailing zero bytes (padding between NALs).
        nal = data[start:end]
        while nal and nal[-1] == 0:
            nal = nal[:-1]

        if nal:
            nals.append(bytes(nal))

    return nals


def get_nal_type(nal):
    """Return the NAL unit type (5 lower bits of the first byte)."""
    if not nal:
        return -1
    return nal[0] & 0x1F


NAL_TYPE_NAMES = {
    1: 'Non-IDR Slice',
    2: 'Slice Data Partition A',
    3: 'Slice Data Partition B',
    4: 'Slice Data Partition C',
    5: 'IDR Slice',
    6: 'SEI',
    7: 'SPS',
    8: 'PPS',
    9: 'Access Unit Delimiter',
}


def describe_nal(nal):
    """Human-readable one-line description of a NAL unit."""
    nt = get_nal_type(nal)
    name = NAL_TYPE_NAMES.get(nt, f'Type {nt}')
    return f'{name} ({len(nal)} bytes)'


# ---------------------------------------------------------------------------
# avcC (AVCDecoderConfigurationRecord) builder
# ---------------------------------------------------------------------------

def build_avcc(sps, pps):
    """Construct the content of an avcC box from SPS and PPS NAL units.

    The resulting bytes follow ISO/IEC 14496-15 section 5.2.4.1.1.
    """
    if len(sps) < 4:
        raise ValueError('SPS NAL is too short to contain profile/level info')

    buf = bytearray()
    buf.append(1)               # configurationVersion
    buf.append(sps[1])          # AVCProfileIndication
    buf.append(sps[2])          # profile_compatibility
    buf.append(sps[3])          # AVCLevelIndication
    buf.append(0xFF)            # 6 bits reserved (111111) + lengthSizeMinusOne = 3
    buf.append(0xE1)            # 3 bits reserved (111) + numOfSPS = 1
    buf.extend(struct.pack('>H', len(sps)))
    buf.extend(sps)
    buf.append(1)               # numOfPPS
    buf.extend(struct.pack('>H', len(pps)))
    buf.extend(pps)
    return bytes(buf)


# ---------------------------------------------------------------------------
# Classify NAL units into the pieces we need
# ---------------------------------------------------------------------------

def classify_nals(nals):
    """Sort *nals* into SPS, PPS, and frame slices.

    Returns ``(sps, pps, frames)`` where *frames* is a list of
    ``(nal_bytes, is_keyframe)`` tuples.

    Raises ``ValueError`` if SPS or PPS are missing, or no frames found.
    """
    sps = None
    pps = None
    frames = []

    for nal in nals:
        nt = get_nal_type(nal)
        if nt == 7:
            sps = nal
        elif nt == 8:
            pps = nal
        elif nt in (1, 5):
            frames.append((nal, nt == 5))
        # Silently skip SEI, AUD, and other NAL types.

    if sps is None:
        raise ValueError('No SPS NAL unit found in the bitstream')
    if pps is None:
        raise ValueError('No PPS NAL unit found in the bitstream')
    if not frames:
        raise ValueError('No slice NAL units (frames) found in the bitstream')

    return sps, pps, frames


# ===================================================================
# Approach 0 -- FFmpeg remuxing
# ===================================================================

def package_mp4_ffmpeg(input_h264, output_mp4, fps=24):
    """Package Annex B H.264 into MP4 using ffmpeg as an external tool."""
    ffmpeg = shutil.which('ffmpeg')
    if not ffmpeg:
        raise FileNotFoundError('ffmpeg is not installed or not on PATH')

    cmd = [
        ffmpeg,
        '-y',
        '-hide_banner',
        '-loglevel',
        'error',
        '-fflags',
        '+genpts',
        '-f',
        'h264',
        '-r',
        str(fps),
        '-i',
        input_h264,
        '-c:v',
        'copy',
        '-movflags',
        '+faststart',
        output_mp4,
    ]
    proc = subprocess.run(cmd, check=True, capture_output=True, text=True)
    if proc.stderr.strip():
        print('ffmpeg reported H.264 parser warnings/errors:')
        print(proc.stderr.strip())
    return probe_mp4(output_mp4)


def probe_mp4(path):
    """Return a small decode summary using ffprobe when available."""
    ffprobe = shutil.which('ffprobe')
    if not ffprobe:
        return {}

    cmd = [
        ffprobe,
        '-v',
        'error',
        '-select_streams',
        'v:0',
        '-show_entries',
        'stream=codec_name,width,height,avg_frame_rate,nb_frames',
        '-of',
        'default=noprint_wrappers=1',
        path,
    ]
    proc = subprocess.run(cmd, check=True, capture_output=True, text=True)
    info = {}
    for line in proc.stdout.splitlines():
        if '=' in line:
            key, value = line.split('=', 1)
            info[key] = value
    return info


# ===================================================================
# Approach 1 -- PyAV muxing
# ===================================================================

def package_mp4_pyav(h264_data, output_mp4, fps=24, width=320, height=176):
    """Package an Annex B byte stream into MP4 using the PyAV library.

    PyAV wraps FFmpeg's libavformat/libavcodec so the resulting MP4 is as
    compatible as a file produced by ``ffmpeg`` itself.
    """
    import av  # noqa: delay import so manual fallback works without PyAV

    nals = parse_annexb_nals(h264_data)
    sps, pps, frames = classify_nals(nals)
    avcc = build_avcc(sps, pps)

    container = av.open(output_mp4, 'w')
    stream = container.add_stream('h264', rate=fps)
    stream.width = width
    stream.height = height
    stream.pix_fmt = 'yuv420p'
    stream.time_base = av.Fraction(1, fps)

    # Attach SPS/PPS as codec extradata so the muxer writes a proper avcC
    # inside the stsd/avc1 box.
    stream.codec_context.extradata = avcc

    frame_idx = 0
    for nal_data, is_key in frames:
        # Reconstruct an Annex B access unit that FFmpeg's H.264 parser can
        # consume (start-code + NAL).  For IDR frames, also prepend SPS+PPS
        # to help the parser initialise on any random access point.
        au = bytearray()
        if is_key:
            au.extend(b'\x00\x00\x00\x01')
            au.extend(sps)
            au.extend(b'\x00\x00\x00\x01')
            au.extend(pps)
        au.extend(b'\x00\x00\x00\x01')
        au.extend(nal_data)

        pkt = av.Packet(bytes(au))
        pkt.stream = stream
        pkt.pts = frame_idx
        pkt.dts = frame_idx
        pkt.time_base = av.Fraction(1, fps)
        if is_key:
            pkt.is_keyframe = True

        container.mux(pkt)
        frame_idx += 1

    container.close()
    print(f'Muxed {frame_idx} frame(s) via PyAV -> {output_mp4}')
    return frame_idx


# ===================================================================
# Approach 2 -- Manual MP4 box construction (pure Python, no deps)
# ===================================================================

def _box(box_type, payload=b''):
    """Build an ISO-BMFF box (atom).  *box_type* must be 4 bytes."""
    assert len(box_type) == 4
    size = 8 + len(payload)
    return struct.pack('>I', size) + box_type + payload


def _full_box(box_type, version, flags, payload=b''):
    """Build a full-box (box with version + flags header)."""
    vf = struct.pack('>I', (version << 24) | (flags & 0x00FFFFFF))
    return _box(box_type, vf + payload)


def _build_ftyp():
    """ftyp -- file type."""
    major_brand = b'isom'
    minor_version = struct.pack('>I', 0x00000200)
    compatible = b'isomiso2avc1mp41'
    return _box(b'ftyp', major_brand + minor_version + compatible)


def _build_mvhd(timescale, duration):
    """mvhd -- movie header (version 0)."""
    d = bytearray()
    d.extend(struct.pack('>I', 0))              # creation_time
    d.extend(struct.pack('>I', 0))              # modification_time
    d.extend(struct.pack('>I', timescale))       # timescale
    d.extend(struct.pack('>I', duration))        # duration
    d.extend(struct.pack('>I', 0x00010000))      # rate  = 1.0 (fixed 16.16)
    d.extend(struct.pack('>H', 0x0100))          # volume = 1.0 (fixed 8.8)
    d.extend(b'\x00' * 10)                       # reserved
    # Unity matrix (3x3 fixed-point)
    d.extend(struct.pack('>9I',
        0x00010000, 0, 0,
        0, 0x00010000, 0,
        0, 0, 0x40000000))
    d.extend(b'\x00' * 24)                       # pre_defined
    d.extend(struct.pack('>I', 2))               # next_track_ID
    return _full_box(b'mvhd', 0, 0, bytes(d))


def _build_tkhd(track_id, duration, width, height):
    """tkhd -- track header (version 0, flags = enabled|in-movie)."""
    d = bytearray()
    d.extend(struct.pack('>I', 0))              # creation_time
    d.extend(struct.pack('>I', 0))              # modification_time
    d.extend(struct.pack('>I', track_id))       # track_ID
    d.extend(struct.pack('>I', 0))              # reserved
    d.extend(struct.pack('>I', duration))        # duration
    d.extend(b'\x00' * 8)                        # reserved
    d.extend(struct.pack('>h', 0))               # layer
    d.extend(struct.pack('>h', 0))               # alternate_group
    d.extend(struct.pack('>h', 0))               # volume (0 for video)
    d.extend(struct.pack('>H', 0))               # reserved
    # Unity matrix
    d.extend(struct.pack('>9I',
        0x00010000, 0, 0,
        0, 0x00010000, 0,
        0, 0, 0x40000000))
    d.extend(struct.pack('>I', width << 16))     # width  (fixed 16.16)
    d.extend(struct.pack('>I', height << 16))    # height (fixed 16.16)
    return _full_box(b'tkhd', 0, 0x000003, bytes(d))


def _build_mdhd(timescale, duration):
    """mdhd -- media header (version 0)."""
    d = bytearray()
    d.extend(struct.pack('>I', 0))              # creation_time
    d.extend(struct.pack('>I', 0))              # modification_time
    d.extend(struct.pack('>I', timescale))
    d.extend(struct.pack('>I', duration))
    # language: undetermined (0x55C4 encodes 'und')
    d.extend(struct.pack('>H', 0x55C4))
    d.extend(struct.pack('>H', 0))              # pre_defined
    return _full_box(b'mdhd', 0, 0, bytes(d))


def _build_hdlr():
    """hdlr -- handler reference (video)."""
    d = bytearray()
    d.extend(struct.pack('>I', 0))              # pre_defined
    d.extend(b'vide')                            # handler_type
    d.extend(b'\x00' * 12)                       # reserved
    d.extend(b'VideoHandler\x00')                # name (null-terminated)
    return _full_box(b'hdlr', 0, 0, bytes(d))


def _build_vmhd():
    """vmhd -- video media header."""
    return _full_box(b'vmhd', 0, 0x000001,
                     struct.pack('>H', 0) + b'\x00' * 6)


def _build_dinf():
    """dinf/dref -- data information / data reference."""
    url_box = _full_box(b'url ', 0, 0x000001, b'')  # self-contained
    dref = _full_box(b'dref', 0, 0,
                     struct.pack('>I', 1) + url_box)
    return _box(b'dinf', dref)


def _build_stsd(avcc_data, width, height):
    """stsd -- sample descriptions (contains avc1 + avcC)."""
    avcc_box = _box(b'avcC', avcc_data)

    avc1 = bytearray()
    avc1.extend(b'\x00' * 6)                    # reserved
    avc1.extend(struct.pack('>H', 1))            # data_reference_index
    avc1.extend(b'\x00' * 16)                    # pre_defined + reserved
    avc1.extend(struct.pack('>H', width))
    avc1.extend(struct.pack('>H', height))
    avc1.extend(struct.pack('>I', 0x00480000))   # horiz resolution 72 dpi
    avc1.extend(struct.pack('>I', 0x00480000))   # vert  resolution 72 dpi
    avc1.extend(b'\x00' * 4)                     # reserved
    avc1.extend(struct.pack('>H', 1))            # frame_count
    avc1.extend(b'\x00' * 32)                    # compressorname
    avc1.extend(struct.pack('>H', 0x0018))       # depth (24-bit colour)
    avc1.extend(struct.pack('>h', -1))           # pre_defined
    avc1.extend(avcc_box)

    avc1_box = _box(b'avc1', bytes(avc1))
    return _full_box(b'stsd', 0, 0,
                     struct.pack('>I', 1) + avc1_box)


def _build_stts(num_samples, delta=1):
    """stts -- (decoding) time-to-sample.  Constant frame rate."""
    d = struct.pack('>I', 1)                     # entry_count
    d += struct.pack('>II', num_samples, delta)  # sample_count, sample_delta
    return _full_box(b'stts', 0, 0, d)


def _build_stsc(num_samples):
    """stsc -- sample-to-chunk.  All samples in one chunk."""
    d = struct.pack('>I', 1)                     # entry_count
    d += struct.pack('>III', 1, num_samples, 1)  # first_chunk, spc, sdi
    return _full_box(b'stsc', 0, 0, d)


def _build_stsz(sample_sizes):
    """stsz -- sample sizes."""
    d = struct.pack('>II', 0, len(sample_sizes))
    for sz in sample_sizes:
        d += struct.pack('>I', sz)
    return _full_box(b'stsz', 0, 0, d)


def _build_stco_placeholder():
    """stco -- chunk offsets.  Returns (box_bytes, offset_position).

    The single chunk-offset entry is written as zero and must be patched
    later once the final moov size is known.

    *offset_position* is the byte offset **within the returned box bytes**
    where the 4-byte chunk offset lives.
    """
    d = struct.pack('>I', 1)                     # entry_count
    d += struct.pack('>I', 0)                    # placeholder
    box = _full_box(b'stco', 0, 0, d)
    # The chunk-offset value sits at: 8 (box hdr) + 4 (version/flags)
    #   + 4 (entry_count) = 16 bytes from the start of the box.
    return box, 16


def _build_stss(sync_samples):
    """stss -- sync (key-frame) sample table.  1-indexed."""
    d = struct.pack('>I', len(sync_samples))
    for s in sync_samples:
        d += struct.pack('>I', s)
    return _full_box(b'stss', 0, 0, d)


def package_mp4_manual(h264_data, output_mp4, fps=24, width=320, height=176):
    """Package an Annex B byte stream into MP4 by manually building every box.

    This implementation has zero external dependencies (only ``struct`` from
    the standard library).
    """
    nals = parse_annexb_nals(h264_data)
    sps, pps, frames = classify_nals(nals)
    avcc = build_avcc(sps, pps)

    # Build mdat payload -- each sample is a 4-byte-length-prefixed NAL.
    mdat_payload = bytearray()
    sample_sizes = []
    sync_samples = []

    for i, (nal_data, is_key) in enumerate(frames):
        sample = struct.pack('>I', len(nal_data)) + nal_data
        sample_sizes.append(len(sample))
        mdat_payload.extend(sample)
        if is_key:
            sync_samples.append(i + 1)           # stss is 1-indexed

    num_samples = len(frames)
    timescale = fps
    duration = num_samples                        # one tick per frame

    # If every frame is a sync sample we can still write stss, but some
    # players are happier without it when it is trivial.  We keep it for
    # correctness.

    # --- Sample table (stbl) ---
    stsd = _build_stsd(avcc, width, height)
    stts = _build_stts(num_samples)
    stsc = _build_stsc(num_samples)
    stsz = _build_stsz(sample_sizes)
    stco, stco_patch_offset = _build_stco_placeholder()
    stss = _build_stss(sync_samples)
    stbl = _box(b'stbl', stsd + stts + stsc + stsz + stco + stss)

    # --- Media information (minf) ---
    vmhd = _build_vmhd()
    dinf = _build_dinf()
    minf = _box(b'minf', vmhd + dinf + stbl)

    # --- Media (mdia) ---
    mdhd = _build_mdhd(timescale, duration)
    hdlr = _build_hdlr()
    mdia = _box(b'mdia', mdhd + hdlr + minf)

    # --- Track (trak) ---
    tkhd = _build_tkhd(1, duration, width, height)
    trak = _box(b'trak', tkhd + mdia)

    # --- Movie (moov) ---
    mvhd = _build_mvhd(timescale, duration)
    moov = _box(b'moov', mvhd + trak)

    # --- ftyp and mdat ---
    ftyp = _build_ftyp()
    mdat = _box(b'mdat', bytes(mdat_payload))

    # Patch stco: the chunk data starts right after the mdat 8-byte header.
    mdat_data_offset = len(ftyp) + len(moov) + 8   # +8 = mdat box header
    moov_buf = bytearray(moov)

    # Find our stco box inside moov and patch the offset field.
    # We search for the stco fourcc to be resilient to layout changes.
    stco_tag_pos = moov_buf.find(b'stco')
    if stco_tag_pos < 0:
        raise RuntimeError('BUG: could not locate stco box inside moov')
    # stco_tag_pos points at the 's' of 'stco' which is byte 4 of the box.
    # offset field = tag_pos + 4 (rest of box type) + 4 (ver/flags) + 4 (entry_count)
    patch_pos = stco_tag_pos + 4 + 4 + 4
    struct.pack_into('>I', moov_buf, patch_pos, mdat_data_offset)
    moov = bytes(moov_buf)

    # Write the file.
    with open(output_mp4, 'wb') as f:
        f.write(ftyp)
        f.write(moov)
        f.write(mdat)

    total_bytes = len(ftyp) + len(moov) + len(mdat)
    print(f'Wrote {output_mp4} ({total_bytes} bytes, {num_samples} frame(s))')
    return num_samples


# ===================================================================
# Entry point
# ===================================================================

def main():
    parser = argparse.ArgumentParser(
        description='Package a raw H.264 Annex B bitstream into an MP4 container.')
    parser.add_argument('input', nargs='?',
                        default='/workspace/output/encoded.h264',
                        help='Path to the raw H.264 Annex B file '
                             '(default: /workspace/output/encoded.h264)')
    parser.add_argument('output', nargs='?',
                        default='/workspace/output/output.mp4',
                        help='Path for the output MP4 file '
                             '(default: /workspace/output/output.mp4)')
    parser.add_argument('--fps', type=int, default=24,
                        help='Frame rate (default: 24)')
    parser.add_argument('--width', type=int, default=320,
                        help='Video width in pixels (default: 320)')
    parser.add_argument('--height', type=int, default=176,
                        help='Video height in pixels (default: 176)')
    parser.add_argument('--method', choices=['ffmpeg', 'pyav', 'manual', 'auto'],
                        default='auto',
                        help='Muxing method (default: auto -- try ffmpeg, then PyAV, then manual)')
    args = parser.parse_args()

    print('H.264 to MP4 Packager')
    print(f'  Input:  {args.input}')
    print(f'  Output: {args.output}')
    print(f'  Resolution: {args.width}x{args.height} @ {args.fps} fps')
    print()

    if not os.path.isfile(args.input):
        print(f'ERROR: input file not found: {args.input}', file=sys.stderr)
        sys.exit(1)

    file_size = os.path.getsize(args.input)
    if file_size == 0:
        print('ERROR: input file is empty', file=sys.stderr)
        sys.exit(1)

    print(f'Reading H.264 bitstream ({file_size} bytes) ...')
    with open(args.input, 'rb') as f:
        h264_data = f.read()

    os.makedirs(os.path.dirname(os.path.abspath(args.output)), exist_ok=True)

    nals = parse_annexb_nals(h264_data)
    print(f'Found {len(nals)} NAL units')
    for idx, nal in enumerate(nals[:12]):
        print(f'  NAL {idx}: {describe_nal(nal)}')
    if len(nals) > 12:
        print(f'  ... {len(nals) - 12} more NAL units')

    try:
        _, _, frames = classify_nals(nals)
        print(f'Frame-like slice count: {len(frames)}')
    except ValueError as exc:
        print(f'ERROR: invalid H.264 input: {exc}', file=sys.stderr)
        sys.exit(1)

    method = args.method
    success = False
    n = 0

    # --- Try ffmpeg -------------------------------------------------------
    if method in ('ffmpeg', 'auto'):
        try:
            print('Using ffmpeg for MP4 remuxing ...')
            ffprobe_info = package_mp4_ffmpeg(args.input, args.output, fps=args.fps)
            n = len(frames)
            success = True
            if ffprobe_info:
                print('ffprobe summary:')
                for key in ('codec_name', 'width', 'height', 'avg_frame_rate', 'nb_frames'):
                    if key in ffprobe_info:
                        print(f'  {key}: {ffprobe_info[key]}')
        except FileNotFoundError:
            if method == 'ffmpeg':
                print('ERROR: ffmpeg is not installed.', file=sys.stderr)
                sys.exit(1)
            print('ffmpeg not available, falling back to PyAV/manual muxing ...')
        except subprocess.CalledProcessError as exc:
            if method == 'ffmpeg':
                print(f'ERROR: ffmpeg remux failed: {exc}', file=sys.stderr)
                sys.exit(1)
            print(f'ffmpeg remux failed ({exc}), falling back to PyAV/manual muxing ...')

    # --- Try PyAV ---------------------------------------------------------
    if not success and method in ('pyav', 'auto'):
        try:
            import av  # noqa
            print('Using PyAV (FFmpeg) for MP4 muxing ...')
            n = package_mp4_pyav(h264_data, args.output,
                                 fps=args.fps, width=args.width,
                                 height=args.height)
            success = True
        except ImportError:
            if method == 'pyav':
                print('ERROR: PyAV is not installed.', file=sys.stderr)
                sys.exit(1)
            print('PyAV not available, falling back to manual boxing ...')
        except Exception as exc:
            if method == 'pyav':
                print(f'ERROR: PyAV muxing failed: {exc}', file=sys.stderr)
                sys.exit(1)
            print(f'PyAV muxing failed ({exc}), falling back to manual boxing ...')

    # --- Manual fallback --------------------------------------------------
    if not success and method in ('manual', 'auto'):
        print('Using manual MP4 box builder (pure Python) ...')
        n = package_mp4_manual(h264_data, args.output,
                               fps=args.fps, width=args.width,
                               height=args.height)
        success = True

    if not success:
        print('ERROR: no muxing method succeeded.', file=sys.stderr)
        sys.exit(1)

    out_size = os.path.getsize(args.output)
    print()
    print(f'Done.  {args.output}  ({out_size} bytes, {n} frame(s))')


if __name__ == '__main__':
    main()
