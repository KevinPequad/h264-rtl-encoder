# Output

This directory is for generated encoder artifacts and validation outputs.

Not committed:
- raw `.h264` bitstreams
- packaged `.mp4` files
- decoded `.yuv` files
- comparison `.png` images
- simulator logs
- regression summaries

Typical generated files include:
- `validation_320x176_24f.*`
- `validation_720p_24f.*`
- `docker_320x176_1f.*`
- `smoke_matrix_summary.json`

Use the validation scripts or Docker smoke flow to regenerate these artifacts
locally.
