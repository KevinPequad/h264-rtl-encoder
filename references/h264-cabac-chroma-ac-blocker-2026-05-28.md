# H.264 CABAC P16x16 sparse chroma AC blocker notes (2026-05-28)

Branch: `goal/h264-cabac-chroma-contexts`.

Focused gate: `THREADS=1 BUILD_JOBS=1 scripts/run_cabac_p16x16_chroma_cr_ac_probe.sh`.

Current strict-decode pass set after inferred-final coefficient fix:

- Cb dense checker: full 768/768 raw output, decoded-plane sanity `U_SAD=256 V_SAD=0`.
- Cr sparse right column: `single_tr` and `single_br` full 768/768 raw output, decoded-plane sanity `U_SAD=0 V_SAD=64`.
- Cb sparse mirror bottom-right: `cb_mirror_single_br` full 768/768 raw output, decoded-plane sanity `U_SAD=64 V_SAD=0`.
- Dense both-plane AC checker: full 768/768 raw output, decoded-plane sanity exercises both chroma planes.

Current expected-miss set remains decoder-success with short 384/768 raw output:

- Cr dense checker.
- Cr sparse left column: `single_tl`, `single_bl`.
- Cb sparse mirrors except bottom-right: `cb_mirror_single_tl`, `cb_mirror_single_tr`, `cb_mirror_single_bl`.

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
- The mixed results pointed away from a simple edge-default bug. The inferred-final coefficient fix promoted dense both-plane AC, but sparse left-column Cb/Cr and dense Cr remain short-output blockers, so context-state history from zero chroma-AC coded_block_flag bins remains a useful next probe.

Next useful probe:

- Keep the coded-edge CBF behavior as the baseline for now.
- Instrument or isolate the first Cr/Cb sparse-left mismatch after the zero-block CBF emissions: compare block0/block1 zero CBF context-state updates plus the following significant/last/level context state progression for failing `single_tl`/`single_bl` versus strict-pass `single_tr`/`single_br`, while preserving the inferred-final coefficient behavior that promoted dense both-plane AC.
