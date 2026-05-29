# H.264 CABAC P16x16 sparse chroma AC blocker notes (2026-05-28)

Branch: `goal/h264-cabac-chroma-contexts`.

Focused gate: `THREADS=1 BUILD_JOBS=1 scripts/run_cabac_p16x16_chroma_cr_ac_probe.sh`.

Current strict-decode pass set after inferred-final coefficient fix:

- Cb dense checker: full 768/768 raw output, decoded-plane sanity `U_SAD=256 V_SAD=0`.
- Cr sparse right column plus bottom-left: `single_tr`, `single_bl`, and `single_br` full 768/768 raw output, decoded-plane sanity `U_SAD=0 V_SAD=64`.
- Cb sparse mirror bottom-right: `cb_mirror_single_br` full 768/768 raw output, decoded-plane sanity `U_SAD=64 V_SAD=0`.
- Dense both-plane AC checker: full 768/768 raw output, decoded-plane sanity exercises both chroma planes.

Current expected-miss set remains decoder-success with short 384/768 raw output:

- Cr dense checker: `bytestream -21`, short 384/768 raw output.
- Cr sparse top-left: `single_tl` (`bytestream -19`), short 384/768 raw output.
- Cb sparse mirrors except bottom-right: `cb_mirror_single_tl` (`bytestream -13`), `cb_mirror_single_tr` (`bytestream -29`), and `cb_mirror_single_bl` (`bytestream -11`), short 384/768 raw output.

Rejected context experiments:

- Tried changing `cabac_res_chroma_ac_cbf_ctx_sel_for` so unavailable 4:2:0 chroma AC left/top neighbors enter the CBF ctxInc as not-coded (`1'b0`) instead of the current coded default (`1'b1`).
- The all-zero-edge variant (`left_edge=0 top_edge=0`) immediately regressed the existing strict-pass controls to short output, including dense Cb checker and the right-quadrant sparse passes.
- A mixed-edge sweep shows no global unavailable-neighbor default fixes the sparse AC blocker without regressing existing passes. Decoded raw byte counts for two 16x16 yuv420p frames, where `768` is strict full decode and `384` is the current short-output miss:

  | unavailable CBF defaults | cb_checker | Cr checker | Cr TL | Cr TR | Cr BL | Cr BR | both planes | Cb TL | Cb TR | Cb BL | Cb BR |
  | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
  | `left=1 top=1` baseline | 768 | 384 | 384 | 768 | 384 | 768 | 384 | 384 | 384 | 384 | 768 |
  | `left=0 top=0` | 384 | 384 | 384 | 384 | 384 | 384 | 384 | 384 | 384 | 384 | 384 |
  | `left=1 top=0` | 768 | 384 | 384 | 384 | 768 | 384 | 384 | 384 | 384 | 384 | 384 |
  | `left=0 top=1` | 768 | 384 | 384 | 384 | 384 | 384 | 384 | 384 | 384 | 384 | 384 |

- The change was reverted after each probe; the canonical gate then passed again with the existing pass/miss set above.
- The mixed results pointed away from a simple edge-default bug. The inferred-final coefficient fix promoted dense both-plane AC, but sparse top-left Cb/Cr and dense Cr remain short-output blockers, so context-state history from zero chroma-AC coded_block_flag bins remains a useful next probe.

Next useful probe:

- Keep the coded-edge CBF behavior as the baseline for now.
- Enable the plumbed `DEBUG_CABAC_P16X16=1` trace for the first Cr/Cb sparse-left mismatch after the zero-block CBF emissions: compare block0/block1 zero CBF context-state updates plus the following significant/last/level context state progression for failing `single_tl`/`single_bl` versus strict-pass `single_tr`/`single_br`, while preserving the inferred-final coefficient behavior that promoted dense both-plane AC.

## Debug trace checkpoint

- `scripts/run_cabac_p16x16_chroma_ac_debug_compare.sh` now builds with `DEBUG_CABAC_P16X16=1` and locks four diagnostic fixtures:
  - Cr `single_tl`: first coded chroma-AC block `4`, expected short `384/768` decode (`bytestream -19` after split Cb/Cr CBF state).
  - Cr `single_tr`: first coded chroma-AC block `5`, strict `768/768` decode.
  - Cb mirror `single_tl`: first coded chroma-AC block `0`, expected short `384/768` decode.
  - Cb mirror `single_br`: first coded chroma-AC block `3`, strict `768/768` decode.
- `rtl/h264_bitstream.v` now emits `[CABACCTX]` context-state update lines under `DEBUG_CABAC_P16X16`, alongside `[CABACRES]` residual-bin lines. This makes the sparse-left miss vs right-column pass comparison reproducible without VCD dumping.
- Next repair target: use the locked `CABACRES`/`CABACCTX` pairs to test a narrow chroma-AC context-state/ordering fix, then promote the affected expected-miss rows only when FFmpeg emits the full `768/768` raw output.

## 2026-05-28 Cr bottom-left promotion

- Split the reduced chroma-AC CBF context-state storage between Cb and Cr planes while preserving the existing plane-local CBF context selector and coded-edge defaults.
- This promoted Cr `single_bl` from the expected short-output miss set to a strict full `768/768` FFmpeg decode without regressing `single_tr`, `single_br`, dense Cb, dense both-plane, or Cb bottom-right controls.
- Remaining short-output signatures are Cr dense checker/top-left and Cb sparse mirrors except bottom-right; next probe should compare top-left CBF zero-history and significant/last state progression against the newly passing bottom-left and right-column Cr fixtures.
