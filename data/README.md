# Data

This directory is for local input assets used during simulation and validation.

Not committed:
- source videos such as Big Buck Bunny
- extracted `.yuv` test clips
- generated `.hex` memory images
- generated `frame_info.h`

Typical local files produced here:
- `bigbuckbunny.mp4`
- `raw_frames.yuv`
- `raw_frames_720p_1s.yuv`
- `raw_frames_720p_10s.yuv`

Use `scripts/download_and_decode.sh` or local FFmpeg commands to populate this
directory when needed.
