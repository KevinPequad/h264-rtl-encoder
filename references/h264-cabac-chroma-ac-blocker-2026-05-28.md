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

## 2026-05-30 sparse-Cb neighbor-CBF restoration rejection

- Added `scripts/run_cabac_p16x16_chroma_cb_ac_neighbor_cbf_probe.py`, which patches only a staged RTL workspace to replace the current sparse-Cb-only synthetic CBF walk with direct plane-local-neighbor CBF derivation.
- The staged neighbor walk does not promote the remaining sparse Cb AC masks and also regresses former strict controls: representative masks `0x1`, `0x2`, `0x3`, `0x4`, `0x8`, and `0xc` all stop at one decoded frame (`384/768`) with locked FFmpeg signatures (`-9`, `-15`, `-6`, `-15`, `-23`, `-22`).
- This rules out simply restoring neighbor-derived Cb AC CBF selectors as the repair. The next repair should keep the current control-pass constraints visible while comparing CABAC arithmetic/output decisions around the early prefix/residual-tail bits.

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

## 2026-05-30 decoded-plane SAD lock for Cb AC controls

- Tightened `scripts/run_cabac_p16x16_chroma_cb_ac_arith_trace_probe.sh` so the full-decode Cb-only chroma-AC controls no longer pass on any nonzero Cb-plane mismatch. The gate now locks the exact current second-frame decoded-plane SADs against the source fixture: mask `0x3` has `U_SAD=128`, masks `0x4` and `0x8` have `U_SAD=64`, and all keep `V_SAD=0`.
- This makes the distinction explicit: those masks are strict FFmpeg-decodable controls, not reconstruction-parity closures. Future CABAC arithmetic/tail work must either preserve these exact diagnostic signatures or intentionally promote them to a documented lower-SAD/exact-parity expectation.
- Verification: `THREADS=1 BUILD_JOBS=1 scripts/run_cabac_p16x16_chroma_cb_ac_arith_trace_probe.sh` passes with sparse masks `0x1`, `0x2`, and `0xc` still short at `384/768` and controls `0x3`, `0x4`, and `0x8` still full at `768/768` with exact decoded-plane SAD locked.

## 2026-05-30 full plane-local sparse-Cb CBF trial

- Rejected a local source trial that replaced the sparse Cb-only special CBF selector table with the direct plane-local neighbor derivation for all four Cb AC blocks (`block0=0`, `block1=left`, `block2=top`, `block3=left+top`) while leaving dense/Cr paths unchanged.
- The trial did not promote the remaining top-row Cb mirrors and regressed both bottom-row sparse-Cb controls: `cb_mirror_single_tl`, `cb_mirror_single_tr`, `cb_mirror_single_bl`, and `cb_mirror_single_br` all emitted only `384/768` decoded bytes; dense `cb_checker` stayed strict at `768/768`.
- The source was restored and the canonical chroma-residual gates passed afterward. This keeps the next repair below another sparse-Cb selector remap and on the prefix/residual-tail arithmetic decisions locked by the recent `[CABACEMIT]`, `[CABACBITS]`, and bitflip probes.

## 2026-05-30 all-mask P-slice prefix bitflip sweep

- Added `scripts/run_cabac_p16x16_chroma_cb_ac_prefix_bitflip_sweep.sh` to extend the earlier representative tail-bitflip result across all 15 nonzero Cb-only chroma-AC masks.
- The probe preserves the current baseline partition (`0x1/0x2/0x5/0x6/0x9/0xa/0xc` short at one frame with locked FFmpeg signatures, all other masks strict-decodable) and then flips only the common first post-slice-header CABAC prefix byte.
- Both common mutations, `0x6b -> 0x4b` (bit 5) and `0x6b -> 0xeb` (bit 7), strict-decode every mask while preserving the expected Cb-only decoded-plane SAD (`64 * popcount(mask)`, `V_SAD=0`), including masks that already strict-decode at baseline.
- This moves the next repair target away from per-mask CBF selectors and toward the shared arithmetic decision that produces the `0x6b` prefix byte before residual chunks begin; future source fixes should make that byte/renormalization state match the reference rather than patching individual sparse masks.

## 2026-05-30 split-mask arithmetic trace extension

- Extended `scripts/run_cabac_p16x16_chroma_cb_ac_arith_trace_probe.sh` so the DEBUG_CABAC_P16X16 arithmetic trace now includes split top+bottom failing masks `0x5` and `0x6`, not only singleton-top `0x1`/`0x2`, bottom-pair `0xc`, and strict controls `0x3`/`0x4`/`0x8`.
- The new locks preserve their one-frame failures and exact signatures (`0x5 -> bytestream -22`, `0x6 -> bytestream -18`) while recording CBF arithmetic trails, residual byte chunks, stream tails, terminate pre-state, first-payload state, and the common P-slice prefix emit rows.
- Verification: `THREADS=1 BUILD_JOBS=1 scripts/run_cabac_p16x16_chroma_cb_ac_arith_trace_probe.sh` passes with masks `0x1`, `0x2`, `0x5`, `0x6`, and `0xc` short at `384/768`, and controls `0x3`, `0x4`, and `0x8` full at `768/768` with exact Cb-only decoded-plane SAD.

## 2026-05-30 staged sparse-Cb CBF selector-table sweep

- Added `scripts/run_cabac_p16x16_chroma_cb_ac_cbf_selector_sweep.py`, a reusable staged diagnostic that patches only a temporary workspace's sparse-Cb CBF selector table and builds each variant with the same 16x16 two-frame CABAC P16x16 Cb-only AC fixture family.
- The sweep locks the current mapping `[1,1,3,0]` plus simple unavailable-edge, actual-ish, and all-same selector remaps. None promote the remaining top-row sparse Cb masks `0x1` or `0x2` from the one-frame `384/768` miss state to full `768/768` output.
- Several variants also regress current strict controls (`0x3`, `0x4`, and/or `0x8`), matching the earlier ad-hoc/static selector probes and turning the no-more-static-selector-remaps conclusion into a checked gate.
- Verification: `THREADS=1 BUILD_JOBS=1 scripts/run_cabac_p16x16_chroma_cb_ac_cbf_selector_sweep.py` passes; next repair work should stay focused on the shared CABAC prefix/residual-tail arithmetic decisions rather than another CBF selector table tweak.

## 2026-05-30 first CABAC payload-byte bitflip sweep

- Added `scripts/run_cabac_p16x16_chroma_cb_ac_first_cabac_bitflip_sweep.sh` to sweep single-bit mutations of the first CABAC payload byte after the locked `d0 08 08 6b` P-slice header for all 15 nonzero Cb-only chroma-AC masks.
- The baseline partition remains unchanged (`0x1/0x2/0x5/0x6/0x9/0xa/0xc` one-frame misses; all other masks strict-decode). The generated first CABAC payload byte is locked as `0xeb` for every mask.
- Flipping bit7 (`0xeb -> 0x6b`) strict-decodes every mask with byte-identical IDR and expected Cb-only second-frame SAD. Flipping bit0 (`0xeb -> 0xea`) only promotes high-density masks `0x7/0x9/0xb/0xd/0xe/0xf`, and flipping bit2 (`0xeb -> 0xef`) only additionally promotes mask `0x2`; all other first-byte bit flips remain isolated one-frame bytestream misses.
- Verification: `THREADS=1 BUILD_JOBS=1 scripts/run_cabac_p16x16_chroma_cb_ac_first_cabac_bitflip_sweep.sh` passes; this moves the next repair target onto the first CABAC payload arithmetic/output decision, below the already-classified header-tail parser-realignment flips and away from more CBF selector remaps.

## 2026-05-30 staged CABAC core queue-alignment probe

- Added `scripts/run_cabac_p16x16_chroma_cb_ac_queue_align_probe.py`, which keeps the canonical source untouched, builds a baseline staged workspace, then builds a second staged workspace that changes only the two `h264_cabac_core` initial `cod_i_queue` assignments from `-8'sd9` to `-8'sd8`.
- The baseline half preserves the current Cb-only AC mask lattice (`0x1/0x2/0x5/0x6/0x9/0xa/0xc` short at one decoded frame with locked FFmpeg bytestream signatures, all other nonzero masks strict-decode).
- The `queue_m8` staged variant promotes all 15 nonzero Cb-only chroma-AC masks to clean two-frame FFmpeg decode (`768/768`) with a byte-identical IDR frame, first CABAC payload byte `0x75`, and exact Cb-only decoded-plane SAD (`64 * popcount(mask)`, `V_SAD=0`).
- This is the first single-source-line class candidate that promotes the full Cb-only AC mask lattice without changing CBF selectors or residual binarization. Next repair should land the queue alignment in `rtl/h264_cabac_core.v`, then refresh the stale expected-miss diagnostics and run the broader CABAC P16x16/luma/chroma gates before claiming the sparse-Cb blocker closed.
- Verification: `THREADS=1 BUILD_JOBS=1 scripts/run_cabac_p16x16_chroma_cb_ac_queue_align_probe.py` passes.

## 2026-05-30 queue-shift guard and first-payload substitution split

- Tightened `scripts/run_cabac_p16x16_chroma_cb_ac_queue_align_probe.py` with a dense Cb+Cr AC guard. The staged global `cod_i_queue -9 -> -8` change still promotes every Cb-only AC mask, but it regresses the dense both-plane AC control to one decoded frame (`384/768`, `bytestream -9`). That makes the global queue initialization shift non-committable as a source fix.
- Added and then extended `scripts/run_cabac_p16x16_chroma_cb_ac_first_payload_substitution_probe.py`. The probe mutates only the first CABAC residual payload byte after the locked `d0 08 08 6b` P-slice header, leaving the generated RTL stream otherwise untouched.
- Exact `0xeb -> 0x75` and bit7 `0xeb -> 0x6b` first-payload substitutions both promote all 15 Cb-only AC masks to clean two-frame decode (`768/768`) with exact Cb-only decoded-plane SAD (`64 * popcount(mask)`, `V_SAD=0`).
- The dense Cb+Cr AC guard remains strict under both one-byte substitutions with `U_SAD=256 V_SAD=256`, separating the useful first-byte correction family from the later arithmetic/output-state side effect that makes the global queue shift unsafe.
- Next repair target: scoped CABAC first-payload generation/alignment for the chroma-AC residual path while preserving the existing later arithmetic state that keeps dense Cb+Cr AC strict-decodable.

## 2026-05-30 arithmetic trace stdout interleave hardening

- Re-ran `THREADS=1 BUILD_JOBS=1 scripts/run_cabac_p16x16_chroma_cb_ac_arith_trace_probe.sh` and hit a local execution blocker where the C++ testbench frame-complete stdout line split the blk5 CHRAC_CBF debug row for split masks `0x5`/`0x6`.
- Hardened the diagnostic to tolerate only that known non-atomic missing CBF/order row while preserving the full expected trail, residual byte chunks, emitted stream tails, terminate pre-state, FFmpeg signatures, and decoded-plane SAD locks.
- Verification now passes again with the same baseline partition: masks `0x1`, `0x2`, `0x5`, `0x6`, and `0xc` remain one-frame `384/768` misses, while `0x3`, `0x4`, and `0x8` strict-decode full `768/768`.

## 2026-05-31 cross-plane first-payload IDR integrity lock

- Tightened `scripts/run_cabac_p16x16_chroma_ac_cross_plane_first_payload_probe.py` so each expected-short mixed Cb+Cr chroma-AC baseline must still decode a byte-identical IDR frame before failing on the P residual.
- This keeps the cross-plane first-payload repair target scoped below SPS/PPS/IDR/header framing: the sparse mixed-plane misses are now locked as P-residual CABAC failures, while the `0xeb->0x75` and bit7 `0xeb->0x6b` one-byte substitutions still promote them to strict two-frame decode with expected plane-local SAD and preserve the strict dense controls.
- Verification: `THREADS=1 BUILD_JOBS=1 scripts/run_cabac_p16x16_chroma_ac_cross_plane_first_payload_probe.py` passes.

## 2026-05-31 Cb-only first-payload IDR integrity lock

- Tightened `scripts/run_cabac_p16x16_chroma_cb_ac_first_payload_substitution_probe.py` so every expected-short Cb-only chroma-AC baseline must still decode the full byte-identical IDR frame before the probe accepts its one-frame P-residual failure signature.
- The Cb-only first-payload repair target now has the same scope guard as the mixed-plane probe: the short masks remain localized P-residual CABAC failures, not SPS/PPS/IDR/header regressions, while `0xeb->0x75` and bit7 `0xeb->0x6b` still promote all Cb-only AC masks and preserve the dense Cb+Cr guard.
- Verification: `THREADS=1 BUILD_JOBS=1 scripts/run_cabac_p16x16_chroma_cb_ac_first_payload_substitution_probe.py` passes.

## 2026-05-31 Cr-only coefficient-shape partition lock

- Added `scripts/run_cabac_p16x16_chroma_cr_ac_shape_probe.sh`, a Cr-only counterpart to the Cb AC coefficient-shape probe.
- Low-amplitude (`+5`) checker, vertical, and horizontal Cr-only shapes strict-decode across all four chroma AC blocks with exact `U_SAD=0 V_SAD=40` and exact final P-slice tails.
- High-amplitude (`+32`) shapes now expose a Cr-specific residual-tail partition: most checker/axis/diagonal cases remain one-frame `384/768` misses with exact FFmpeg signatures and final tails, but block-1 anti-diagonal and block-2 main/anti diagonals strict-decode with exact `V_SAD=128`.
- This keeps the next source repair below CBF selector and P-slice-boundary handling. The useful target is residual coefficient level/suffix/order arithmetic that explains high-amplitude shape failures without regressing low-amplitude Cr strict controls or existing Cb/Cb+Cr guards.
- Verification: `THREADS=1 BUILD_JOBS=1 scripts/run_cabac_p16x16_chroma_cr_ac_shape_probe.sh` passes.

## 2026-05-31 Cr-only high-amplitude axis-complement lock

- Extended `scripts/run_cabac_p16x16_chroma_cr_ac_shape_probe.sh` with the missing high-amplitude (`+32`) vertical-right and horizontal-bottom complements.
- The complements exactly match the existing opposite-side axis cases per block: block 0 remains `vert_* -> bytestream -7` and `horiz_* -> -11`; block 1 `vert_* -> -10` and `horiz_* -> -9`; block 2 `vert_* -> -10` and `horiz_* -> -11`; block 3 `vert_* -> -11` and `horiz_* -> -11`, all with matching final P-slice tails.
- This rules out simple axis-side polarity/placement as the Cr high-amplitude axis failure mode while preserving the diagonal strict/miss partition; next repair should stay on residual level/suffix/order arithmetic or CABAC tail state.

## 2026-05-31 Cr-only high-amplitude shape first-payload lock

- Tightened `scripts/run_cabac_p16x16_chroma_cr_ac_shape_probe.sh` so every high-amplitude (`+32`) Cr-only checker/axis/diagonal shape now validates exact first-CABAC-payload substitutions in addition to its baseline final-slice tail and FFmpeg strict/miss expectation.
- For every high-amplitude shape case, the baseline first payload remains `0xeb` after the locked `d0 08 08 6b` header tail. Mutating only that byte to either `0x75` or `0x6b` promotes or preserves all high-amplitude shapes as strict two-frame FFmpeg decode with a byte-identical IDR frame and exact Cr-only SAD (`V_SAD=128` for diagonal four-pixel shapes, `256` for checker/axis eight-pixel shapes).
- This brings the Cr high-amplitude coefficient-shape blocker under the same scoped first-payload correction family as the Cb/Cr mask and mixed-plane first-payload probes. The next source repair should target first-payload CABAC arithmetic/renormalization or residual-tail state, not another CBF selector, axis-side polarity, or literal bytestream patch.

## 2026-05-31 Cb-only high-amplitude shape first-payload lock

- Tightened `scripts/run_cabac_p16x16_chroma_cb_ac_shape_probe.sh` with the Cb-side counterpart to the Cr shape first-payload substitution lock.
- The baseline high-amplitude (`+32`) checker/axis/diagonal Cb-only shape cases still remain one-frame misses with their exact final P-slice tails under the shared generated `d0 08 08 6b eb` header/first-payload prefix.
- Mutating only the first CABAC payload byte from `0xeb` to either `0x75` or `0x6b` promotes every high-amplitude Cb shape to strict two-frame FFmpeg decode with a byte-identical IDR frame and exact Cb-only SAD (`U_SAD=128` for diagonal four-pixel shapes, `256` for checker/axis eight-pixel shapes).
- This aligns Cb shape failures with the same scoped first-payload/residual-tail arithmetic target as the Cb mask, Cr mask/shape, and mixed-plane probes, rather than a standalone coefficient placement, CBF selector, or P-slice-boundary issue.

## 2026-05-31 Cb-only phase first-payload lock

- Tightened `scripts/run_cabac_p16x16_chroma_cb_ac_phase_probe.sh` so the `±5` parity/sign lattice now checks the same first-CABAC-payload substitution family as the mask and shape probes.
- The current baseline partition is unchanged: top-row Cb singleton phase/sign cases and the two bottom-left parity/sign misses remain one-frame failures with exact FFmpeg signatures and final P-slice tails, while the existing bottom-left and bottom-right controls still strict-decode.
- Mutating only the first CABAC payload byte from `0xeb` to either `0x75` or `0x6b` promotes or preserves every phase/sign case as a strict two-frame decode with a byte-identical IDR frame and exact Cb-only `U_SAD=40` / `V_SAD=0`.
- Verification: `THREADS=1 BUILD_JOBS=1 scripts/run_cabac_p16x16_chroma_cb_ac_phase_probe.sh` passes. This further confines the repair target to first-payload CABAC arithmetic/renormalization or residual-tail state, not coefficient sign, parity, CBF selector, or P-slice-boundary handling.

## 2026-05-31 Cr-only phase first-payload preservation lock

- Tightened `scripts/run_cabac_p16x16_chroma_cr_ac_phase_probe.sh` with the Cr-side first-payload substitution guard for the singleton `+5/-5/+8` phase/polarity lattice.
- The baseline Cr phase lattice remains strict two-frame decode across all quadrants, with exact final P-slice tails and exact Cr-only decoded-plane SAD.
- Mutating only the first CABAC payload byte from `0xeb` to either `0x75` or `0x6b` now must preserve strict two-frame decode, byte-identical IDR, and exact Cr-only `V_SAD` for every AC phase/sign case, matching the shape and Cb-phase first-payload repair family without weakening Cr controls.
- Verification: `THREADS=1 BUILD_JOBS=1 scripts/run_cabac_p16x16_chroma_cr_ac_phase_probe.sh` passes. This keeps the next source fix scoped to first-payload CABAC arithmetic/renormalization or residual-tail state while explicitly guarding the Cr low-amplitude phase lane.

## 2026-05-31 mixed-plane quality-guard first-payload value sweep

- Extended `scripts/run_cabac_p16x16_chroma_ac_first_payload_value_sweep.py` with the mixed Cb/Cr quality guard (`Cb mask 0xe`, `Cr mask 0x1`) that currently strict-decodes but reconstructs the wrong chroma-plane deltas under the baseline first payload `0xeb`.
- The guard has 190 single-byte first-payload values that strict-decode with the expected plane-local SAD (`U_SAD=192`, `V_SAD=64`); the known repair-family substitutions `0xeb->0x75` and `0xeb->0x6b` are inside that class, while baseline `0xeb` is not.
- Verification: `THREADS=1 BUILD_JOBS=1 python3 scripts/run_cabac_p16x16_chroma_ac_first_payload_value_sweep.py` passes. This keeps the next source repair focused on first-payload CABAC arithmetic/renormalization and requires it to repair decoded-plane quality, not only FFmpeg bytestream short-decodes.

## 2026-05-31 sparse mixed-plane first-payload value sweep

- Extended the same first-payload byte-value sweep with a sparse mixed-plane guard (`Cb mask 0x1`, `Cr mask 0x1`) so the equivalence-class evidence covers a representative sparse/sparse Cb+Cr case, not only Cb-only, Cr-only, dense both-plane, and strict-but-wrong-quality mixed-plane controls.
- The generated baseline still uses the locked `d0 08 08 6b eb` P-slice header/first-payload prefix and remains outside the strict expected-SAD class; exactly `183` single-byte first-payload values strict-decode with byte-identical IDR and exact plane-local SAD (`U_SAD=64`, `V_SAD=64`).
- The known first-payload repair-family substitutions `0xeb->0x75` and bit7 `0xeb->0x6b` are inside that sparse mixed-plane pass class. This reinforces that the next source repair should target the shared CABAC first-payload arithmetic/renormalization boundary rather than adding another CBF selector or bytestream patch special case.
- Verification: `THREADS=1 BUILD_JOBS=1 python3 scripts/run_cabac_p16x16_chroma_ac_first_payload_value_sweep.py` passes.

## 2026-05-31 first-payload value-range lock

- Tightened `scripts/run_cabac_p16x16_chroma_ac_first_payload_value_sweep.py` so the representative first-payload byte sweep now locks the exact pass-value ranges for each Cb-only, Cr-only, sparse/dense mixed-plane, and strict-but-wrong-quality guard case, not just the pass counts plus the known `0x75`/`0x6b` promoted values.
- This makes the diagnostic sensitive to equivalence-class drift: a future arithmetic/renormalization source change must either preserve the current first-payload decode/quality classes or deliberately update the expected ranges with stronger evidence, rather than accidentally swapping one passing value set for another with the same count.
- Verification: `THREADS=1 BUILD_JOBS=1 python3 scripts/run_cabac_p16x16_chroma_ac_first_payload_value_sweep.py` passes with the exact ranges locked for all nine cases.

## 2026-05-31 first-payload baseline stream-tail lock

- Tightened `scripts/run_cabac_p16x16_chroma_ac_first_payload_value_sweep.py` again so each representative baseline stream now locks its generated H.264 length and final 16-byte tail before the single-byte first-payload mutation sweep runs.
- This keeps the first-payload repair family scoped to the already-characterized `d0 08 08 6b eb` residual boundary: a future source repair cannot silently move the second-slice tail/framing while preserving the same decode-equivalence class ranges.
- Verification: `THREADS=1 BUILD_JOBS=1 python3 scripts/run_cabac_p16x16_chroma_ac_first_payload_value_sweep.py` passes with stream lengths, final tails, exact pass-value ranges, and known `0xeb->0x75` / bit7 `0xeb->0x6b` promoted controls locked for all nine cases.

## 2026-05-31 second-payload value-range probe

- Added `scripts/run_cabac_p16x16_chroma_ac_second_payload_value_sweep.py` to mutate only the byte after the shared baseline `d0 08 08 6b eb` header/first-payload prefix for representative Cb-only (`0x1`), Cr-only (`0x3`), and sparse Cb+Cr (`0x1/0x1`) chroma-AC misses.
- The second-byte equivalence classes are much narrower than the first-byte classes but still non-unique: `26`, `36`, and `33` values respectively strict-decode with byte-identical IDR and exact expected plane-local SAD.
- The generated baseline second bytes (`0x2e`, `0x30`, and `0x2e`) stay outside those strict expected-SAD classes, so the residual boundary issue is not just one magic first-byte substitution. The source repair should still target CABAC arithmetic/renormalization/output-byte state, not literal bytestream patching.
- Verification: `THREADS=1 BUILD_JOBS=1 scripts/run_cabac_p16x16_chroma_ac_second_payload_value_sweep.py` passes.

## 2026-05-31 third-payload value-range probe

- Added `scripts/run_cabac_p16x16_chroma_ac_third_payload_value_sweep.py` to mutate the third CABAC payload byte after the same locked `d0 08 08 6b eb` boundary for representative Cb-only (`0x1`), Cr-only (`0x3`), and sparse Cb+Cr (`0x1/0x1`) chroma-AC misses.
- The third-byte equivalence classes are narrow but still non-unique: `16`, `42`, and `23` byte values respectively strict-decode with byte-identical IDR and exact expected plane-local SAD.
- The generated baseline third bytes (`0xd2`, `0x26`, and `0xe2`) stay outside those strict expected-SAD classes. Together with the first/second-payload sweeps, this keeps the repair target on CABAC arithmetic/renormalization/output-byte state instead of a literal bytestream patch or another CBF selector remap.
- Verification: `THREADS=1 BUILD_JOBS=1 python3 scripts/run_cabac_p16x16_chroma_ac_third_payload_value_sweep.py` passes.

## 2026-05-31 fourth-payload value-range probe

- Added `scripts/run_cabac_p16x16_chroma_ac_fourth_payload_value_sweep.py` to mutate the fourth CABAC payload byte after the locked `d0 08 08 6b eb` residual boundary for the same representative Cb-only (`0x1`), Cr-only (`0x3`), and sparse Cb+Cr (`0x1/0x1`) chroma-AC misses.
- The fourth-byte equivalence classes tighten further for the Cb-only and sparse mixed-plane cases: only `0xe5` and `0x7e` respectively strict-decode with byte-identical IDR and exact expected plane-local SAD, while the Cr-only case still has a narrow non-unique 30-value class.
- The generated baseline fourth bytes (`0x26`, `0xa0`, and `0xd4`) stay outside those strict expected-SAD classes. Together with the first/second/third-payload sweeps, this keeps the repair target on CABAC arithmetic/renormalization/output-byte state instead of a CBF selector remap or literal bytestream patch.
- Verification: `THREADS=1 BUILD_JOBS=1 python3 scripts/run_cabac_p16x16_chroma_ac_fourth_payload_value_sweep.py` passes.

## 2026-05-31 fifth-payload value/boundary probe

- Added `scripts/run_cabac_p16x16_chroma_ac_fifth_payload_value_sweep.py` to extend the payload-byte diagnostics one byte further where the generated stream has a fifth residual payload byte.
- The representative Cb-only mask `0x1` stream now has an explicit boundary lock: its final P-slice tail ends immediately after the fourth payload byte `0x26`, so there is no fifth byte to mutate for that case.
- For the continuation cases, mutating only the fifth residual payload byte gives narrow strict expected-SAD classes: Cr-only mask `0x3` has 16 passing values (`0x0d,0x0f,0x18-0x19,0x48,0x4d-0x4e,0x54,0x65,0x8e,0x9a,0xbf,0xd4,0xdf,0xe7,0xf0`) and sparse Cb+Cr `0x1/0x1` has only two (`0x2b,0xf6`).
- The generated baseline fifth bytes (`0xab` and `0x5e`) stay outside those classes, reinforcing that the source repair should target CABAC arithmetic/renormalization/output-byte state rather than bytestream literal patching.
- Verification: `THREADS=1 BUILD_JOBS=1 scripts/run_cabac_p16x16_chroma_ac_fifth_payload_value_sweep.py` passes.

## 2026-05-31 high-amplitude 0x2/0xd first-payload range lock

- Tightened `scripts/run_cabac_p16x16_chroma_ac_high_amp_miss_probe.py` so the remaining high-amplitude Cb singleton / Cr all-but-one `0x2/0xd` complement misses no longer lock only the short-output FFmpeg signatures and final tails.
- The probe now sweeps the first CABAC payload byte after the shared `d0 08 08 6b` P-slice prefix for all four `±32` sign combinations and locks the exact byte-value classes that produce strict two-frame decode with byte-identical IDR and expected plane-local SAD.
- Both known repair-family values (`0x75` and `0x6b`) are inside the expected-SAD class for all four cases, while the generated baseline first payload remains `0xbb` and stays outside those classes. This keeps the high-amplitude miss scoped to the same CABAC first-payload arithmetic/renormalization boundary as the Cb-only, Cr-only, and sparse mixed-plane blockers.

## 2026-05-31 high-amplitude 0x2/0xd second-payload range lock

- Extended `scripts/run_cabac_p16x16_chroma_ac_high_amp_miss_probe.py` again so the same four high-amplitude `Cb0x2/Cr0xd` sign combinations also sweep the second CABAC payload byte after the locked `d0 08 08 6b bb` prefix.
- The generated baseline second payloads are `0xec` for the `Cr=+32` cases and `0xcc` for the `Cr=-32` cases; all stay outside the strict expected-SAD repair class.
- Mutating only the second payload byte has a narrow shared strict expected-SAD class, `0x1a-0x1b`, for all four cases. This reinforces that the repair target is CABAC arithmetic/renormalization/output-byte state across the first residual bytes, not a literal first-payload byte patch.

## 2026-05-31 high-amplitude 0x2/0xd third-payload dead-end lock

- Tightened `scripts/run_cabac_p16x16_chroma_ac_high_amp_miss_probe.py` to mutate the third/final CABAC payload byte for the same four `Cb0x2/Cr0xd` high-amplitude complement misses after the locked `d0 08 08 6b bb {ec,cc}` prefix.
- The generated third payload is `0xf7` for the `Cr=+32` cases and `0xff` for the `Cr=-32` cases. No single third-payload byte value strict-decodes both frames with byte-identical IDR and expected plane-local SAD for any sign combination.
- This boundary lock keeps the next source repair focused on first/second residual output-byte arithmetic/renormalization state instead of chasing the terminating tail byte.

## 2026-06-01 high-amplitude reciprocal trace chunk lock

- Tightened `scripts/run_cabac_p16x16_chroma_ac_high_amp_trace_probe.py` so the remaining high-amplitude `Cb0x2/Cr0xd +32/+32` one-frame miss and reciprocal strict-pass `Cb0xd/Cr0x2` lane now lock the complete residual `CABACBITS` byte chunks in addition to final P-slice tails, CBF walks, emitted CABAC payload bytes, and first-payload arithmetic context.
- Failing lane chunk trail: `(1,05,40),(1,44,48),(1,1e,56),(1,80,64),(4,09,72),(4,84,80),(4,03,88),(4,0e,96),(6,d6,104),(6,e9,112),(6,0f,120),(7,b3,0),(7,a4,8),(7,b6,16)`.
- Reciprocal strict-pass chunk trail: `(0,1a,40),(0,04,48),(0,bc,56),(0,71,64),(2,4a,72),(2,c4,80),(2,6b,88),(2,e5,96),(3,ad,104),(3,ad,112),(3,ae,120),(5,12,0),(5,99,8),(5,b1,16)`.
- Verification: `THREADS=1 BUILD_JOBS=1 scripts/run_cabac_p16x16_chroma_ac_high_amp_trace_probe.py` passes. The next repair should use this residual output-byte divergence against the shared first-payload context state and divergent CBF walk, rather than another mask/selector or literal bytestream patch.

## 2026-06-01 high-amplitude terminate pre-state lock

- Tightened `scripts/run_cabac_p16x16_chroma_ac_high_amp_trace_probe.py` again so the remaining high-amplitude `Cb0x2/Cr0xd +32/+32` miss and reciprocal strict-pass lane now lock the DEBUG_CABAC_P16X16 `[CABACTERM]` pre-flush arithmetic state.
- The miss reaches terminate with `ari_low=0x620e`, `ari_range=326`, `ari_queue=-2`, pending byte `0xdc`; the reciprocal strict-pass reaches terminate with `ari_low=0x318`, `ari_range=312`, `ari_queue=-8`, pending byte `0x62`.
- This keeps the next source repair pinned below header/CBF selector changes and on the residual-output/terminate arithmetic boundary: any candidate must explain both the early first-payload split and the final pre-flush divergence without regressing the reciprocal strict lane.
- Verification: `THREADS=1 BUILD_JOBS=1 scripts/run_cabac_p16x16_chroma_ac_high_amp_trace_probe.py` passes.
