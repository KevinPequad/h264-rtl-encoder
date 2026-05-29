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

## 2026-05-28 coded-Cb top-left CBF context probe

- Tested generalizing the special coded top-left chroma-AC CBF path from Cr-only to both planes, i.e. making a coded plane-local top-left block use `ctxInc=0` (`left_coded=0`, `top_coded=0`) while preserving the edge-coded fallback for uncoded top-left blocks.
- Result: rejected. The focused gate still strict-decoded the existing Cr single-block and dense controls, but Cb `cb_mirror_single_tl` did not promote to full `768/768`; it changed the locked short-output FFmpeg signature from `bytestream -13` to `bytestream -9` and remained invalid.
- The source/audit experiment was reverted. This narrows the remaining Cb sparse-left blocker away from simply mirroring the coded Cr top-left CBF ctxInc special case; next useful probe is per-plane significant/last/level context history around the first Cb coded block versus the passing Cb bottom-right control.

## 2026-05-28 coeff_abs_level_gt2 emission probe

- Tested a local source experiment in `rtl/h264_cabac_residual4x4_bins.v` that suppressed the `coeff_abs_level_greater2_flag` bin when `absLevel == 1`, with the standalone residual-bin expectation updated accordingly.
- Standalone gate result for the experiment: `THREADS=1 BUILD_JOBS=1 scripts/run_cabac_residual4x4_bins_check.sh` passed after removing the second-level bin from the absLevel-1 luma/chroma-AC expectations.
- Integrated result: rejected for now. `THREADS=1 BUILD_JOBS=1 scripts/run_cabac_p16x16_chroma_cr_ac_probe.sh` changed dense Cr checker from the locked `bytestream -25` short-output signature to `bytestream -20` and did not strict-decode it. `THREADS=1 BUILD_JOBS=1 scripts/run_cabac_p16x16_chroma_ac_debug_compare.sh` then regressed Cr `single_bl` from strict `768/768` output to short `384/768` output.
- The source/test experiment was reverted. Keep the current emission behavior until the remaining chroma-AC ordering/context issue is isolated; this probe suggests the absLevel-1 bin cleanup is entangled with later CBF/significant/last context progression and cannot be landed as a standalone blocker fix.

## 2026-05-29 sparse-Cb CBF trail lock

- Extended `scripts/run_cabac_p16x16_chroma_ac_debug_compare.sh` to lock the CHRAC_CBF selector/state-update trail for each sparse Cb/Cr fixture, not just first coded block and decoded byte count.
- The remaining failing Cb top/left mirrors are now distinguished from the passing Cb bottom-right control by exact CBF state history:
  - Cb TL short-decodes after `[(0,3,105,103),(2,3,103,109),(3,3,109,113),...]`.
  - Cb TR short-decodes after `[(1,3,105,109),(1,2,124,126),(3,1,119,123),...]`.
  - Cb BL short-decodes after `[(1,3,105,109),(2,2,124,122),(2,1,119,117),...]`.
  - Cb BR strict-decodes with `[(1,3,105,109),(2,2,124,122),(3,1,119,123),(3,0,92,100),...]`.
- This narrows the next repair to the Cb-plane sparse-left CBF context-state/ordering transition after the first coded block; do not promote any Cb TL/TR/BL row until FFmpeg emits the full `768/768` raw output.

## 2026-05-29 true pending-block CBF trace labels

- Fixed the `DEBUG_CABAC_P16X16` `[CABACCTX]` trace to print the residual block/category captured when the bin was issued, instead of the live `cabac_res_block_idx` after the residual scheduler had already advanced.
- Updated `scripts/run_cabac_p16x16_chroma_ac_debug_compare.sh` to lock the corrected CHRAC_CBF trails. The remaining sparse Cb misses are now labeled against the actual Cb AC blocks:
  - Cb TL short-decodes with `[(0,3,105,103),(1,3,103,109),(2,3,109,113),(3,0,92,90),...]`.
  - Cb TR short-decodes with `[(0,3,105,109),(1,2,124,126),(2,1,119,123),(3,2,126,124),...]`.
  - Cb BL short-decodes with `[(0,3,105,109),(1,2,124,122),(2,1,119,117),(3,1,117,119),...]`.
  - Cb BR still strict-decodes with `[(0,3,105,109),(1,2,124,122),(2,1,119,123),(3,0,92,100),...]`.
- This does not promote a new sparse-Cb strict-decode row yet; it removes a misleading debug label that made post-coded-block CBF transitions look shifted by one or two blocks. Next repair probe should target those actual Cb block 0/1/2 transition differences, not the old live-index labels.


## 2026-05-29 sparse-Cb coded-payload context lock

- Extended `scripts/run_cabac_p16x16_chroma_ac_debug_compare.sh` to lock the first coded chroma-AC block's significant-map and level context update trail for each sparse Cb/Cr fixture.
- The coded payload context trail is identical for Cb TL/TR/BL short-output misses, the Cb BR strict-pass control, and the promoted Cr sparse controls; no CHRAC_LAST update is emitted for these inferred-final reduced blocks.
- This keeps the immediate repair target on CHRAC_CBF selector/state history for the first four Cb AC blocks rather than significant/last/level payload emission.
