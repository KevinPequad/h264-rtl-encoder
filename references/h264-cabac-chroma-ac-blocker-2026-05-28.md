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

## 2026-05-29 sparse-Cb top-row CBF selector sweep

- Rejected a narrow Cb-only top-row selector sweep while preserving the landed bottom-row sparse-Cb mapping as the baseline (`plane_block` selectors `[1,1,3,0]` for Cb blocks 0..3).
- `THREADS=1 BUILD_JOBS=1 scripts/run_cabac_p16x16_chroma_ac_debug_compare.sh` showed these temporary mappings do not promote the remaining Cb top-row misses:
  - `[3,3,3,0]`: Cb TL/TR/BL/BR all short-decode `384/768`, regressing the bottom-row controls.
  - `[1,2,3,0]`: Cb TL/TR/BL short-decode `384/768`; only Cb BR stays strict.
  - `[2,1,3,0]`: Cb TL/TR/BL/BR all short-decode `384/768`, regressing the bottom-row controls.
- `THREADS=1 BUILD_JOBS=1 scripts/run_cabac_p16x16_chroma_cr_ac_probe.sh` also rejected `[0,0,3,0]` and `[2,2,3,0]`: both kept the top-row Cb mirrors short and only changed locked FFmpeg bytestream signatures (`TL -9` for `[0,0,3,0]`; `TR -23` for `[2,2,3,0]`).
- The source was restored after each probe. This narrows the next repair away from a static per-block Cb CBF selector remap; the next useful target is the ordering/state interaction when a sparse Cb top-row coded block is emitted before the later Cb/Cr zero-CBF walk.

## 2026-05-29 Cb-only Cr-zero shared-state probe

- Re-ran the focused debug compare on current `goal/h264-cabac-chroma-contexts`: Cr sparse `single_tl`/`single_tr`/`single_bl` and Cb sparse bottom-row mirrors now strict-decode `768/768`; the remaining sparse-Cb misses are top-row only (`cb_mirror_single_tl` and `cb_mirror_single_tr`, both `384/768`).
- Rejected a narrow experiment that made the Cr-plane zero-CBF walk reuse the Cb CHRAC_CBF context-state bank when the fixture was Cb-only AC (`cb_any && !cr_any`). It did not promote Cb TL/TR and regressed the already-green Cb bottom-left mirror to short `384/768` output.
- The rejected trail changed the post-Cb Cr-zero selectors from split-plane `sel=7/6/5/4` to shared-bank `sel=3/2/1/0`, confirming the remaining top-row Cb blocker is not fixed by simply sharing Cb CBF state into the all-zero Cr plane.
- Next useful repair target: preserve the current split Cb/Cr state banks and probe the Cb top-row coded-block ordering/context transition before the later same-plane zero CBF(s), especially the repeated `sel=1` update for `cb_mirror_single_tl`/`cb_mirror_single_tr` versus the passing bottom-row `sel=3`/`sel=0` coded updates.

## 2026-05-29 sparse-Cb top-row adjacent-selector probes

- Rejected two additional Cb-only top-row CBF selector experiments while preserving the current split Cb/Cr state banks and the landed bottom-row baseline (`[1,1,3,0]` for Cb blocks 0..3).
- Temporary `[1,3,3,0]` kept Cb TL short at the locked `bytestream -19` one-frame output and changed Cb TR only to a different short-output signature (`bytestream -25` instead of the locked `-21`); no strict full `768/768` top-row decode.
- Temporary `[3,1,3,0]` immediately changed Cb TL away from the locked short signature without producing a full two-frame decode, so it is also not a repair.
- The source was restored after each probe. This further narrows the blocker away from a simple adjacent top-row CBF selector swap; next useful probe is the actual same-plane top-row coded-before-zero ordering/state interaction, or an independent decoder-side trace of the CABAC CBF decisions for `cb_mirror_single_tl`/`cb_mirror_single_tr`.


## 2026-05-29 exhaustive sparse-Cb top-row selector sweep

- Completed the remaining Cb-only top-row static CBF selector sweep for sparse Cb AC, keeping bottom-row selectors at the current green baseline (`[*,*,3,0]` for Cb blocks 0..3) and restoring source after each probe.
- Newly rejected top-row pairs `[0,1]`, `[1,0]`, `[0,3]`, `[3,0]`, `[2,3]`, `[3,2]`, `[0,2]`, and `[2,0]`: none promoted `cb_mirror_single_tl` or `cb_mirror_single_tr` to strict `768/768`; most also regressed one or both bottom-row sparse-Cb controls.
- Together with the earlier rejected `[0,0]`, `[1,2]`, `[2,1]`, `[2,2]`, `[1,3]`, `[3,1]`, and `[3,3]` probes plus the baseline `[1,1]`, this exhausts the 4x4 static selector space for Cb blocks 0/1 under the current `[block2=3, block3=0]` bottom-row mapping.
- Next useful target is no longer another static Cb top-row selector remap; probe the residual scheduler/CABAC state ordering around Cb top-row coded AC before later same-plane zero CBFs, or capture an independent decoder-side CABAC CBF decision trace of the expected Cb TL/TR coded_block_flag decisions.

## 2026-05-29 sparse-Cb CBF/payload ordering lock

- Extended `scripts/run_cabac_p16x16_chroma_ac_debug_compare.sh` to lock the ordered sequence of chroma-AC CBF bins and the first coded payload context update for each sparse Cb/Cr fixture.
- The remaining sparse Cb top-row misses now explicitly capture the coded-before-zero shape: `cb_mirror_single_tl` emits `CBF0=1`, then the block-0 payload, then zero CBFs for blocks 1..7; `cb_mirror_single_tr` emits `CBF0=0`, `CBF1=1`, then the block-1 payload before later zero CBFs. The bottom-row sparse-Cb strict-pass controls remain locked as zero CBFs before the block-2/block-3 payload.
- `THREADS=1 BUILD_JOBS=1 scripts/run_cabac_p16x16_chroma_ac_debug_compare.sh` passed with this additional ordering check. No new strict-decode promotion was made; the immediate repair target remains the top-row Cb coded-before-later-zero CBF ordering/context-state interaction or an independent decoder-side CABAC CBF decision trace.

## 2026-05-29 sparse-Cb FFmpeg signature lock and Cr-bank probe

- Extended `scripts/run_cabac_p16x16_chroma_ac_debug_compare.sh` to lock the FFmpeg stderr signatures alongside decoded-byte counts: the remaining Cb top-left/top-right misses are now tied to `bytestream -19` and `bytestream -21`, while the Cr sparse controls and Cb bottom-row controls must keep clean strict-pass logs.
- Rejected a temporary source probe that routed sparse Cb top-row CHRAC_CBF state through the Cr CBF bank. It preserved Cr sparse strict passes but kept Cb TL/TR at `384/768` and regressed the already-green Cb bottom-left mirror to short output, so the blocker is not just the Cb-vs-Cr CBF state bank choice.
- Next useful repair target remains the same-plane sparse-Cb top-row coded-before-zero ordering/context transition, now with the decoder error signatures locked by the diagnostic gate.

## 2026-05-29 sparse-Cb dynamic coded-selector probe

- Rejected a dynamic variant of the sparse Cb-only CBF selector that changed the selector only for the actually coded top-row Cb block while leaving zero-CBF top-row blocks at the current baseline and preserving bottom-row selectors `[3,0]`.
- Swept coded selector pairs `[0,0]`, `[2,2]`, `[3,3]`, `[0,2]`, `[2,0]`, `[3,0]`, `[0,3]`, `[3,2]`, and `[2,3]` for Cb blocks 0/1 with `THREADS=1 BUILD_JOBS=1` using a temporary `/tmp/h264_dynamic_probe.py` source rewrite that restored `rtl/h264_bitstream.v` afterward.
- None promoted `cb_mirror_single_tl` or `cb_mirror_single_tr` to full `768/768` strict FFmpeg output; both remained short `384/768` with only bytestream-signature changes (`TL` in `-9/-13/-19`, `TR` in `-5/-9/-25`). Bottom-row sparse-Cb mirrors stayed strict `768/768` in all swept dynamic-coded variants.
- This rules out the remaining simple dynamic-coded top-row CBF selector split. The next useful target is lower than static/dynamic CBF selector choice: trace arithmetic-state/renormalization around the first Cb top-row AC payload immediately following chroma DC, or compare the produced CABAC bit decisions against an independent decoder/instrumented-reference trace.

## 2026-05-29 Cb-only AC mask-lattice probe

- Added `scripts/run_cabac_p16x16_chroma_cb_ac_mask_probe.sh` to generate and lock all 15 nonzero Cb-only chroma-AC block masks for the 16x16 two-frame CABAC P16x16 fixture. The probe validates integrated CABAC P16x16 counters, Cb-only block counts, decoded-byte length, and Cb-only decoded-plane SAD for strict-pass masks.
- Current strict-pass masks are `0x3`, `0x4`, `0x7`, `0x8`, `0xb`, `0xd`, `0xe`, and `0xf`; these all decode full `768/768` raw bytes with `cr_ac_blocks=0` and nonzero U-only SAD.
- Current isolated one-frame misses are `0x1`, `0x2`, `0x5`, `0x6`, `0x9`, `0xa`, and `0xc`; these emit the expected Cb AC block counters but stop at `384/768` raw bytes with FFmpeg error signatures. This expands the blocker from only single top-row Cb mirrors to a Cb mask-lattice pattern: top-pair/dense/full-ish masks pass, but single-top, split top+bottom, and bottom-pair sparse masks still fail.
- A temporary plusarg-based exhaustive sweep of the 4^4 static CBF selector sequence for the failing masks found no selector tuple that promoted any of the failing masks to full `768/768`, then restored `rtl/h264_bitstream.v`. The next repair target should therefore compare CABAC arithmetic-state/renormalization or decoder-side CBF/payload decisions across passing masks `0x3/0x4/0x8` and failing masks `0x1/0x2/0xc`, not repeat static CBF selector sweeps.


## 2026-05-29 Cb-only AC mask signature lock

- Tightened `scripts/run_cabac_p16x16_chroma_cb_ac_mask_probe.sh` so each currently failing Cb-only sparse AC mask now has an exact FFmpeg bytestream signature, not just a generic short-decode check.
- Locked signatures: `0x1 -> bytestream -19`, `0x2 -> bytestream -21`, `0x5 -> bytestream -22`, `0x6 -> bytestream -18`, `0x9 -> bytestream -14`, `0xa -> bytestream -20`, and `0xc -> bytestream -18`; all still emit exactly one decoded 16x16 yuv420p frame (`384/768`) while the known passing masks remain full `768/768`.
- This keeps the gate from papering over the blocker: any future repair must promote a mask to the strict-pass partition and update the expectation, while signature drift in the remaining misses now fails fast.


## 2026-05-29 CABAC arithmetic trace tap

- Added explicit debug-state outputs from `rtl/h264_cabac_core.v` and plumbed them into the `DEBUG_CABAC_P16X16` `[CABACCTX]` trace as `ari_low`, `ari_range`, `ari_queue`, `ari_outstanding`, `ari_pending`, and `ari_pbyte`.
- Tightened `scripts/run_cabac_p16x16_chroma_ac_debug_compare.sh` so the sparse chroma-AC diagnostic gate now fails if those arithmetic-state taps disappear; the existing CBF selector/state, coded-payload, ordering, decoded-byte, and FFmpeg-signature locks are unchanged.
- This does not promote any Cb mask to strict decode yet. It gives the next repair probe a stable RTL-side arithmetic/renormalization signature for comparing failing Cb top-row / split masks against passing Cb bottom singles and top-pair masks without simulator hierarchy hacks.

## 2026-05-30 Cb-only arithmetic trace probe

- Added `scripts/run_cabac_p16x16_chroma_cb_ac_arith_trace_probe.sh` to build the CABAC P16x16 path with `DEBUG_CABAC_P16X16=1` and lock representative Cb-only chroma-AC mask arithmetic traces.
- The probe compares failing masks `0x1`, `0x2`, and `0xc` against strict-pass controls `0x3`, `0x4`, and `0x8`, checking decoded byte counts, FFmpeg signatures, CHRAC_CBF selector/state transitions, CABAC arithmetic state taps, CBF/payload order, and first-payload state.
- Current result remains diagnostic rather than a promotion: `0x1`, `0x2`, and `0xc` still emit one-frame `384/768` output, while `0x3`, `0x4`, and `0x8` strict-decode full `768/768`. Next repair should use this narrower arithmetic trail to compare the failing same-plane zero-CBF transitions against the passing top-pair/bottom-single masks.

## 2026-05-30 CABAC residual byte-chunk trace lock

- Added a `DEBUG_CABAC_P16X16` `[CABACBITS]` tap in `rtl/h264_bitstream.v` for non-luma residual CABAC byte chunks as they are handed from `h264_cabac_core` into the bitstream writer.
- Tightened `scripts/run_cabac_p16x16_chroma_cb_ac_arith_trace_probe.sh` to lock the emitted byte chunks for failing Cb-only masks `0x1`, `0x2`, and `0xc` against strict-pass controls `0x3`, `0x4`, and `0x8`, alongside the existing CBF arithmetic/context/order checks.
- The failing masks still stop at one decoded frame (`384/768`) and the strict-pass controls remain full (`768/768`); the new byte tap narrows the next repair below selector/context choice to CABAC output-byte/carry/termination behavior around the sparse-Cb top-row and split-mask residual tail.

## 2026-05-30 zero-DC Cb AC mask-lattice expansion

- Expanded `scripts/run_cabac_p16x16_chroma_cb_ac_zerodc_probe.sh` from the four singleton masks to all 15 nonzero Cb-only chroma-AC masks using a balanced pattern with zero chroma-DC contribution.
- Result: without chroma DC, only bottom-row masks `0x4`, `0x8`, and `0xc` strict-decode. Top-row, mixed, and full masks remain isolated one-frame misses with exact FFmpeg signatures (`0x1:-20`, `0x2:-18`, `0x3:-24`, `0x5:-22`, `0x6:-26`, `0x7:-19`, `0x9:-20`, `0xa:-30`, `0xb:-17`, `0xd:-15`, `0xe:-15`, `0xf:-9`).
- Compared with the normal Cb-AC mask lattice, removing chroma DC regresses top-pair/dense/full-ish masks that otherwise strict-decode. This points the next repair below static CBF selectors and toward the interaction between chroma-DC context/history, Cb AC CBF ordering, and CABAC arithmetic output around the Cb residual tail.

## 2026-05-30 CABAC terminate-wait probe

- Added `scripts/run_cabac_p16x16_chroma_cb_ac_terminate_wait_probe.py`, which patches only a staged RTL workspace to make the CABAC terminate(1) trailer state wait for `cabac_bits_valid` or `cabac_done` before advancing.
- The staged wait does not promote the remaining sparse Cb AC masks: representative failing masks `0x1`, `0x2`, and `0xc` still emit one decoded frame (`384/768`), while strict-pass controls `0x3` and `0x4` remain full `768/768`.
- The wait changes the failing FFmpeg bytestream signatures (`0x1:-24`, `0x2:-22`, `0xc:-15`) without producing a strict decode, so the next repair should stay below simple terminate-tail waiting and compare residual CABAC arithmetic/output state around the Cb AC coded/zero block transitions.

## 2026-05-30 Cb-only AC phase/polarity probe

- Added `scripts/run_cabac_p16x16_chroma_cb_ac_phase_probe.sh` to lock a small parity/sign lattice at the first nonzero sparse Cb AC residual step (`±5`) without changing RTL.
- Top-row Cb singleton blocks remain isolated one-frame misses for both checker parities and both signs: block0 keeps `bytestream -19`, block1 keeps `bytestream -21`.
- Bottom-left is now known to be phase/sign sensitive at the same residual magnitude: `+5/even` and `-5/odd` short-decode with `bytestream -5`, while `+5/odd` and `-5/even` strict-decode full `768/768` with Cb-only decoded-plane SAD.
- Bottom-right remains a green control for all four `±5` parity/sign cases. This broadens the immediate repair target from top-row position alone to residual payload/arithmetic-state interaction with coefficient sign/phase, still below static CBF selector choice.

## 2026-05-30 Cb AC level-suffix probe

- Added `scripts/run_cabac_p16x16_chroma_cb_ac_level_suffix_probe.py`, which patches only a staged RTL workspace to replace the current fixed-binary residual level suffix scaffold with a small unary stop-bit form for `coeff_abs_level_remaining`.
- The staged suffix change does not promote representative sparse Cb AC masks: `0x1`, `0x2`, and `0xc` still stop at one decoded frame (`384/768`) with the locked FFmpeg signatures (`-19`, `-21`, and `-18`), while strict controls `0x3` and `0x4` remain full `768/768`.
- This rules out the simple residual-level suffix-form hypothesis for the current sparse Cb blocker. The next repair should compare the CABAC arithmetic/decoder decisions around the same-plane Cb AC coded/zero block transitions rather than repeating fixed-vs-unary suffix experiments.

## 2026-05-30 CABAC terminate pre-state trace lock

- Added a `DEBUG_CABAC_P16X16` `[CABACTERM]` tap in `rtl/h264_bitstream.v` at the slice-terminate handoff so the diagnostic Cb AC arithmetic probe now locks the CABAC core pre-flush state for failing masks `0x1`, `0x2`, and `0xc` against strict controls `0x3`, `0x4`, and `0x8`.
- `scripts/run_cabac_p16x16_chroma_cb_ac_arith_trace_probe.sh` now checks the terminate pre-state in addition to decoded bytes, FFmpeg signatures, CBF arithmetic trails, residual output byte chunks, CBF/payload order, and first-payload state.
- This still does not promote a sparse Cb top/split mask to full `768/768`; it narrows the next repair below CBF selector/static ordering to the CABAC arithmetic residual tail versus final terminate handoff, with a stable pre-flush state row available for each representative failing/passing mask.

## 2026-05-30 residual level node-context probe

- Rejected a staged RTL experiment that replaced the residual4x4 helper's two-context level scaffold with the x264/spec-style `coeff_abs_level_minus1` node-context walk (`level1` contexts base+1/+2/+3/+4/+0, `levelgt1` contexts base+5..+9, unary stop bins, and per-block node reset) plus full luma/chroma-DC/chroma-AC level context-state arrays.
- Standalone syntax compiled, but the focused integrated gate regressed an already-green control: `THREADS=1 BUILD_JOBS=1 scripts/run_cabac_p16x16_chroma_cr_ac_probe.sh` failed at `CR_AC checker strict-pass control decoded 384 bytes, expected 768 bytes`, while the dense Cb control still strict-decoded.
- The source was restored after the probe. This rules out landing the level node-context walk by itself as the sparse-Cb repair; the next fix should combine any level-binarization cleanup with a decoder/reference CABAC decision trace so Cr dense and Cb dense controls stay green while top/split sparse Cb masks are promoted.

## 2026-05-30 Cb AC stream-tail lock

- Tightened `scripts/run_cabac_p16x16_chroma_cb_ac_arith_trace_probe.sh` so the representative Cb-only chroma-AC arithmetic trace now locks the generated H.264 stream size and final 32-byte tail for failing masks `0x1`, `0x2`, `0xc` and strict-pass controls `0x3`, `0x4`, `0x8`.
- Current tails confirm the short-output masks are not just missing a whole trailing NAL: all six streams keep the same SPS/PPS/AUD/IDR layout and second-slice start, while the payload tail differs per Cb AC mask.
- This still does not promote any sparse Cb mask to `768/768`; it makes future CABAC arithmetic/bitstream-tail repairs fail fast if they silently drift the already-characterized failing/pass control streams.

## 2026-05-30 Cb AC DC-bias probe

- Added `scripts/run_cabac_p16x16_chroma_cb_ac_dc_bias_probe.sh` to vary a uniform Cb-plane DC bias (`-16/-8/0/+8/+16`) around representative Cb-only chroma-AC masks (`0x1`, `0x2`, `0x3`, `0x4`, `0x8`, `0xc`).
- Result: DC bias does not promote the remaining sparse top/split Cb AC masks; `0x1`, `0x2`, and `0xc` remain isolated one-frame `384/768` misses across all tested biases with locked FFmpeg bytestream signatures.
- The same bias sweep regresses otherwise-green masks `0x3`, `0x4`, and `0x8` whenever the uniform DC bias is nonzero; only their zero-bias controls strict-decode full `768/768`. This narrows the repair away from adding/manipulating Cb DC history and toward matching the CABAC arithmetic/output transition for the zero-bias sparse-Cb residual tail.

## 2026-05-30 CABAC residual context-latency probe

- Added `scripts/run_cabac_p16x16_chroma_cb_ac_ctx_latency_probe.py`, which patches only a staged RTL workspace to make the residual bin source wait for the CABAC core context writeback before accepting the next residual bin.
- The staged handoff bubble does not promote the remaining sparse Cb AC masks: `0x1` and `0x2` still stop at one decoded frame (`384/768`) with their locked signatures, and representative split mask `0xc` remains a short decode.
- The same staged bubble regresses the otherwise-green top-pair control `0x3` to a short decode while bottom-single controls `0x4` and `0x8` stay strict-decodable. This rejects the simple context-writeback-latency hypothesis as a repair and keeps the next target on syntax/arithmetic-state decisions around top-row and split Cb residual tails.

## 2026-05-30 Cb AC arithmetic trace parser hardening

- Re-ran `THREADS=1 BUILD_JOBS=1 scripts/run_cabac_p16x16_chroma_cb_ac_arith_trace_probe.sh` and found the diagnostic gate could fail on mask `0xc` when the C++ testbench frame-complete line split the Verilog `[CABACBITS]` stdout row for the `3a` byte.
- Hardened the probe to keep the full `0xc` byte-chunk expectation plus the stream-size/tail lock, while tolerating the known non-atomic log-line split as an alternate parsed byte-chunk list. This fixes a local execution blocker without relaxing the actual H.264 stream-tail check (`...beb3189943a6990`).
- The repaired probe now passes again with masks `0x1`, `0x2`, and `0xc` still short at `384/768`, and masks `0x3`, `0x4`, and `0x8` strict-decodable at `768/768`. No sparse-Cb promotion was claimed.

## 2026-05-30 Cb AC arithmetic decoded-plane sanity hardening

- Tightened `scripts/run_cabac_p16x16_chroma_cb_ac_arith_trace_probe.sh` so the representative arithmetic trace gate now decodes the generated streams into raw yuv420p bytes instead of checking only the byte count.
- The gate now verifies every emitted first frame remains byte-identical to the IDR source frame, and every full two-frame strict-pass control (`0x3`, `0x4`, `0x8`) has a Cb-only decoded-plane delta (`U_SAD != 0`, `V_SAD == 0`). This prevents a future CABAC arithmetic/tail change from being misclassified as green merely because FFmpeg emitted `768/768` bytes.
- Verification: `THREADS=1 BUILD_JOBS=1 scripts/run_cabac_p16x16_chroma_cb_ac_arith_trace_probe.sh` passes with the existing fail/pass partition unchanged (`0x1`, `0x2`, `0xc` short at `384/768`; `0x3`, `0x4`, `0x8` full at `768/768`).

## 2026-05-30 sparse-Cb residual-tail bitflip probe

- Added `scripts/run_cabac_p16x16_chroma_cb_ac_tail_bitflip_probe.sh` to generate representative failing Cb-only AC masks (`0x1`, `0x2`, `0xc`) and exhaustively flip single bits in the post-slice-header residual tail bytes.
- The baseline streams remain the locked short one-frame misses (`0x1:-19`, `0x2:-21`, `0xc:-18` at `384/768`), but the probe now locks exact one-bit payload mutations that make FFmpeg emit two full frames with byte-identical IDR and Cb-only decoded deltas: 5 mutations for `0x1`, 6 for `0x2`, and 3 for `0xc`.
- This narrows the next repair below CBF selector/context choice and below whole-stream framing: the current encoded streams are close enough that individual residual-tail payload bits can produce a strict-decodable Cb-only result, so the next useful target is matching the CABAC arithmetic/output byte decisions around those tail bytes against the decoder/reference trace.
- Verification: `THREADS=1 BUILD_JOBS=1 scripts/run_cabac_p16x16_chroma_cb_ac_tail_bitflip_probe.sh` passes and preserves the existing failing baseline while locking the strict-decodable one-bit mutation set.

## 2026-05-30 CABAC prefix vs residual-byte bitflip split

- Tightened `scripts/run_cabac_p16x16_chroma_cb_ac_tail_bitflip_probe.sh` to classify the strict-decodable one-bit payload mutations into the common pre-residual CABAC prefix byte (`0x6b`, offset 0 after the fixed P-slice header) versus the residual byte chunks that the DEBUG_CABAC_P16X16 arithmetic trace observes from offset 1 onward.
- All representative short masks (`0x1`, `0x2`, `0xc`) share the same two prefix-byte strict-decode mutations: `0x6b -> 0x4b` (bit 5) and `0x6b -> 0xeb` (bit 7). The remaining strict-decode mutations are residual-byte specific.
- This corrects the next-target framing: do not assume every useful mutation is in residual coefficient bytes. The most common promotion point is the early CABAC prefix before the traced residual chunks, so the next repair should compare early CABAC syntax/arithmetic state through skip/mb-type/MVD/CBP/QP-delta handoff against the decoder/reference trace before changing residual coefficient emission.
- Verification: `THREADS=1 BUILD_JOBS=1 scripts/run_cabac_p16x16_chroma_cb_ac_tail_bitflip_probe.sh` passes with the same baseline short masks while explicitly reporting 2 prefix and 3/4/1 residual-byte promotion mutations for masks `0x1`/`0x2`/`0xc` respectively.

## 2026-05-30 P-slice prefix emission trace lock

- Added `DEBUG_CABAC_P16X16` byte-emission tracing in `rtl/h264_bitstream.v` so the generated byte stream can be tied back to the bitstream writer state, not just the CABAC residual helper's byte chunks.
- Tightened `scripts/run_cabac_p16x16_chroma_cb_ac_arith_trace_probe.sh` to lock the common P-slice prefix emission tail (`d0 08 08 6b`) separately from the residual emitted byte tail for representative Cb-only AC masks `0x1`, `0x2`, `0x3`, `0x4`, `0x8`, and `0xc`.
- Result: no promotion yet. Sparse masks `0x1`, `0x2`, and `0xc` remain short `384/768` one-frame outputs, while controls `0x3`, `0x4`, and `0x8` remain strict `768/768` decodes. The useful next repair target is now explicitly the arithmetic/byte decision that produces the shared `0x6b` prefix byte or the immediately following residual tail, with both emission points locked by the diagnostic gate.
- Verification: `THREADS=1 BUILD_JOBS=1 scripts/run_cabac_p16x16_chroma_cb_ac_arith_trace_probe.sh` passes with P-slice prefix emission, residual output/emit chunks, stream tails, terminate pre-state, FFmpeg signatures, and decoded-plane sanity locked.

## 2026-05-30 early-header debug-state lock

- Tightened `scripts/run_cabac_p16x16_chroma_cb_ac_arith_trace_probe.sh` again so the representative sparse-Cb arithmetic gate now locks the early CABAC header debug trail before residual emission: skip, mb-type, MVD, luma CBP, chroma CBP, and the chroma-AC CBP handoff states.
- The locked trail is identical for failing sparse masks `0x1`, `0x2`, and `0xc` and strict-pass controls `0x3`, `0x4`, and `0x8`, so the remaining decode split is still below these header context states and at/after the shared P-slice prefix byte plus residual tail.
- Verification: `THREADS=1 BUILD_JOBS=1 scripts/run_cabac_p16x16_chroma_cb_ac_arith_trace_probe.sh` passes with early header debug state, P-slice prefix emission, residual output/emit chunks, stream tails, terminate pre-state, FFmpeg signatures, and decoded-plane sanity locked.

## 2026-05-30 P-slice prefix emit-row lock

- Tightened `scripts/run_cabac_p16x16_chroma_cb_ac_arith_trace_probe.sh` so the common P-slice prefix is locked as full `[CABACEMIT]` rows, not only emitted byte values: `(mb=0, return_state=S_SLICE, return_sub=7, byte=d0/08/08/6b, bit_cnt=32/24/16/8, pending_kind=0, pending_sel=0)`.
- This keeps future prefix-byte experiments honest about where the shared `0x6b` byte is produced and whether any pending residual context state leaks into the pre-residual emission point.
- Verification: `THREADS=1 BUILD_JOBS=1 scripts/run_cabac_p16x16_chroma_cb_ac_arith_trace_probe.sh` passes with the stricter P-slice emit-row lock; sparse masks `0x1`, `0x2`, and `0xc` remain short at `384/768`, while controls `0x3`, `0x4`, and `0x8` remain strict `768/768`.

## 2026-05-30 P-slice prefix bit-buffer row lock

- Tightened the same arithmetic trace probe to include the full `bit_buf` contents for the common P-slice `[CABACEMIT]` tail rows, locking the exact `d008086b`, `08086b`, `086b`, and `6b` progression that produces the shared pre-residual prefix byte.
- This keeps the prefix-byte repair target below whole-stream framing and prevents a future experiment from preserving the emitted byte sequence while silently moving the bit-buffer alignment that feeds the failing sparse-Cb masks.
- Verification: `THREADS=1 BUILD_JOBS=1 scripts/run_cabac_p16x16_chroma_cb_ac_arith_trace_probe.sh` passes with the stricter P-slice emit-tail/bit-buffer rows; sparse masks `0x1`, `0x2`, and `0xc` remain short at `384/768`, while controls `0x3`, `0x4`, and `0x8` remain strict `768/768`.

## 2026-05-30 full plane-local sparse-Cb CBF trial

- Rejected a local source trial that replaced the sparse Cb-only special CBF selector table with the direct plane-local neighbor derivation for all four Cb AC blocks (`block0=0`, `block1=left`, `block2=top`, `block3=left+top`) while leaving dense/Cr paths unchanged.
- The trial did not promote the remaining top-row Cb mirrors and regressed both bottom-row sparse-Cb controls: `cb_mirror_single_tl`, `cb_mirror_single_tr`, `cb_mirror_single_bl`, and `cb_mirror_single_br` all emitted only `384/768` decoded bytes; dense `cb_checker` stayed strict at `768/768`.
- The source was restored and the canonical chroma-residual gates passed afterward. This keeps the next repair below another sparse-Cb selector remap and on the prefix/residual-tail arithmetic decisions locked by the recent `[CABACEMIT]`, `[CABACBITS]`, and bitflip probes.
