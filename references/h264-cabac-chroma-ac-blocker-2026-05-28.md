# H.264 CABAC P16x16 sparse chroma AC blocker notes (2026-05-28)

Branch: `goal/h264-cabac-chroma-contexts`.

Focused gate: `THREADS=1 BUILD_JOBS=1 scripts/run_cabac_p16x16_chroma_cr_ac_probe.sh`.

Current strict-decode pass set after `8552342`:

- Cb dense checker: full 768/768 raw output, decoded-plane sanity `U_SAD=256 V_SAD=0`.
- Cr sparse right column: `single_tr` and `single_br` full 768/768 raw output, decoded-plane sanity `U_SAD=0 V_SAD=64`.
- Cb sparse mirror bottom-right: `cb_mirror_single_br` full 768/768 raw output, decoded-plane sanity `U_SAD=64 V_SAD=0`.

Current expected-miss set remains decoder-success with short 384/768 raw output:

- Cr dense checker.
- Cr sparse left column: `single_tl`, `single_bl`.
- Both-plane dense checker.
- Cb sparse mirrors except bottom-right: `cb_mirror_single_tl`, `cb_mirror_single_tr`, `cb_mirror_single_bl`.

Rejected context experiment in this run:

- Tried changing `cabac_res_chroma_ac_cbf_ctx_sel_for` so unavailable 4:2:0 chroma AC left/top neighbors enter the CBF ctxInc as not-coded (`1'b0`) instead of the current coded default (`1'b1`).
- That immediately regressed the existing Cb dense strict-pass control: `CR_AC cb_checker strict-pass control decoded 384 bytes, expected 768 bytes`.
- The change was reverted; the canonical gate then passed again with the existing pass/miss set above.

Next useful probe:

- Keep the coded-edge CBF behavior as the baseline for now.
- Instrument or isolate the first Cr/Cb sparse-left mismatch after CBF emission: compare per-block chroma AC significant/last/level context state progression for `single_tl` vs strict-pass `single_tr`/`single_br`, rather than flipping unavailable-edge CBF defaults globally.
