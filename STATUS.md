# Repository Status

This document inventories what is currently implemented in the repository, what
has been validated, and what is still missing before the project can be called
a full-standard H.264 / AVC encoder.

## Summary

Current state:

- RTL-owned H.264 Annex B bitstream generation works for a constrained subset
- the current flow can produce FFmpeg-decodable `.h264` and packaged `.mp4`
- multi-frame validation has been completed at `320x176` and `1280x720`
- the strict current-tree `320x176` validation path now passes after extending
  the P-slice path to four forward refs and re-closing decode on that banked
  path
- the current P-slice path now supports zero-residual inter-MB header deferral
  and RTL-owned `P_SKIP` skip-run generation
- the P/inter partition lane is now RTL-owned and decoder-validated end-to-end;
  forced P16x8/P8x16/P8x8/P8x4/P4x8/P4x4, nonzero-MVD/ref_idx/MVP, qpel/subpel,
  weighted-P, and followref/reference-consumption gates are green in the
  post-merge smoke matrix (see output/h264_p_inter_lane_closeout_t_8258e748.md)
- the current tree now also supports a limited non-reference `B`-slice path on
  intra / `I_PCM` macroblocks
- the current tree now also supports limited non-reference inter-coded
  `B_L0_16x16`, `B_L1_16x16`, and `B_BI_16x16` macroblocks on a reordered
  dual-list `16x16` B path
- the current tree now also supports a limited `B_DIRECT_16x16` path on that
  reordered dual-list `16x16` B flow, with spatial direct derivation, a
  current limited temporal-direct mode, slice-level automatic
  temporal/spatial selection on reordered `B` and reordered-`BREF` slices
  when the future picture's `List0 ref0` bank maps back into the current
  past-reference set, and force hooks for targeted validation
- the current tree now also supports limited `B_SKIP` emission on that
  reordered dual-list `16x16` direct path when a chosen direct macroblock
  reaches zero residual
- the current tree now also supports limited reference-`B` / `BREF`
  `B_L0_16x16`, `B_L1_16x16`, and `B_BI_16x16` pictures on that reordered
  dual-list `16x16` B path
- the deblock/reconstructed-frame ownership lane is validated on canonical
  commit `dc1d47094238f8ad973cdfb5738abd4f0d2ea951` with the standalone oracle,
  public-decoder checks, and a two-frame reference-bank-consumption proof
- CABAC `P_L0_16x16` integration currently covers the strict zero-MVD/single-ref zero-CBP lane, a focused luma-only residual lane, reduced 4:2:0 chroma-only residual smoke cases for Cb/Cr DC-only and Cb/Cr DC+AC, combined luma+single-plane Cb/Cr DC and dense AC residual smoke cases, sparse luma+chroma AC residual smoke cases, and a combined luma+Cb+Cr AC residual smoke case; all are strict FFmpeg-decodable, with the combined lane explicitly locking the current luma/chroma decoded-plane metrics rather than claiming full reconstruction quality
- the standalone CABAC residual scan-event helper and bin/context helper exist; the scan helper now has explicit luma, first/middle-event backpressure-hold, bounded chroma-DC, and bounded chroma-AC event coverage, the bin/context helper supports category-specific chroma DC/AC context bases plus an explicit coded-block-flag context-increment input, and encoder-top buffers chroma DC/AC scan vectors while preserving the `cbp_chroma=1` DC-only vs `cbp_chroma=2` DC+AC distinction; the integrated writer path now emits both coded-block-pattern chroma bins, initializes/updates the chroma DC/AC residual CABAC context-state banks, selects plane-local Cr AC and guarded sparse-Cb AC CBF context walks, reports per-plane chroma AC block counters, and skips luma residual category emission when a chroma-only residual macroblock has `cbp_luma=0`; the chroma residual gate now strict-decodes the four reduced Cb/Cr DC and DC+AC smoke streams; the CABAC core now initializes `cod_i_queue` at `-7`, which the queue-init sweep locks as the sampled plane-safe neighborhood value: legacy `-9` preserves the old sparse Cb misses, `-8` still regresses the dense Cb+Cr guard, `-10` overflows, and checked-in `-7` promotes sparse Cb mask `0x1`/`0x2` plus dense Cb+Cr representative controls to strict two-frame FFmpeg decode with expected plane-local SAD; the focused sparse chroma AC singleton probe now strict-decodes dense Cb, dense Cr, all sparse Cr single-block quadrants, dense both-plane AC, and all sparse Cb mirror singletons under the `-7` queue initializer; promoted Cb/Cr AC shape and singleton-amplitude gates now lock +4 no-AC controls and +5/+8 first-residual steps across all four chroma blocks with exact plane-local SAD and final P-slice tails; the cross-plane chroma-AC gate now additionally locks bottom-row cross-corners, reciprocal diagonal singletons, sparse+dense right-column masks, an asymmetric three-block reciprocal mirror, all-but-one reciprocal complement masks, and a mixed-sign sparse-Cb/dense-Cr high-amplitude guard as strict two-frame FFmpeg decodes
- the CABAC P16x16 cross-plane chroma-AC gate now also guards high-amplitude three-plus-one-block asymmetric complements `Cb0x7/Cr0x8` and `Cb0x8/Cr0x7` with exact plane-local SAD and locked final P-slice tails under the checked-in `cod_i_queue=-7` initializer
- the repository is still not complete as a full H.264 standard encoder

Completion is still blocked by major missing features including full CABAC
residual coefficient syntax beyond the current reduced `P_L0_16x16` luma/chroma smoke subset,
broader `B` / `BREF` / DPB support, broader direct-mode support, deblock,
transform/profile/color closure, and the final long-run target.

## Source Inventory

### Top-Level Files

| Path | Purpose |
| --- | --- |
| `README.md` | Public project overview, run instructions, and high-level status |
| `STATUS.md` | Detailed implementation and gap inventory |
| `AGENTS.md` | Working rules for autonomous development in this repo |
| `build_run.sh` | Build simulator, run encoder, optionally package MP4 |
| `run.sh` | Download sample media, prep YUV, build, run, and package |
| `docker_run.sh` | Linux Docker smoke-run entrypoint |
| `docker_run.bat` | Windows helper for the Docker smoke path |
| `.gitignore` | Ignore local artifacts and generated junk |
| `.gitattributes` | Line-ending and binary handling rules |
| `.editorconfig` | Editor defaults for consistent formatting |

### RTL Modules

| Path | Purpose |
| --- | --- |
| `rtl/h264_encoder_top.v` | Top-level pipeline and frame / macroblock orchestration |
| `rtl/h264_fetch.v` | Input frame fetch and plane address handling |
| `rtl/h264_me.v` | Motion estimation for the current inter path |
| `rtl/h264_intra_pred.v` | Full `Intra_4x4` directional prediction logic |
| `rtl/h264_intra16_pred.v` | `Intra_16x16` luma prediction mode search |
| `rtl/h264_transform.v` | Forward integer transform |
| `rtl/h264_quantize.v` | Quantization |
| `rtl/h264_zigzag.v` | Zigzag coefficient scan |
| `rtl/h264_cabac_core.v` | Standalone CABAC arithmetic coding core |
| `rtl/h264_cavlc.v` | CAVLC syntax generation |
| `rtl/h264_chroma_dc.v` | Chroma DC transform support |
| `rtl/h264_luma_dc.v` | `Intra_16x16` luma DC transform support |
| `rtl/h264_inverse_quant.v` | Inverse quantization |
| `rtl/h264_inverse_transform.v` | Inverse transform |
| `rtl/h264_reconstruct.v` | Reconstruction and reference update path |
| `rtl/h264_bitstream.v` | Annex B writer, parameter sets, slice syntax, output bytes |

### Testbench And Utilities

| Path | Purpose |
| --- | --- |
| `tb/Makefile` | Verilator build and run flow |
| `tb/tb_h264_encoder.cpp` | Main testbench harness |
| `scripts/download_and_decode.sh` | Sample media fetch and YUV extraction |
| `scripts/yuv_to_mem.py` | YUV-to-memory conversion helper |
| `scripts/package_mp4.py` | Remux raw H.264 into MP4 |
| `scripts/calc_psnr.py` | Metric helper |
| `scripts/rtl_runner.py` | Staged runner for clean simulator execution |
| `scripts/regress_smoke_matrix.py` | Reproducible smoke regression matrix |
| `scripts/trace_header_matrix.py` | Trace-header assertion matrix for SPS/PPS/slice profile, VUI/HRD, entropy, and transform-signaling gates |
| `scripts/validate_clip.py` | Multi-frame validation, strict decode gating, optional decode-only fast path, and comparison flow |
| `scripts/run_deblock_oracle_check.sh` | Standalone Verilator oracle check for the deblock edge datapath |
| `scripts/run_deblock_reference_check.sh` | Public-decoder and two-frame reconstructed-reference consumption check for in-loop deblocking |
| `scripts/run_cabac_residual4x4_scan_check.sh` | Standalone Verilator check for the CABAC residual 4x4 scan-event helper, including luma scan ordering, first/middle-event backpressure hold, bounded chroma-DC, and bounded chroma-AC event coverage |
| `scripts/run_cabac_residual4x4_bins_check.sh` | Standalone Verilator check for CABAC residual 4x4 bin/context emission scaffold, including chroma DC/AC zero/nonzero CBF context overrides, explicit chroma DC/AC CBF context-increment coverage, chroma DC tail clamp coverage, and chroma AC tail-context coverage |
| `scripts/run_cabac_p16x16_residual_green_check.sh` | GREEN gate proving integrated CABAC P16x16 luma-only nonzero residual strict-decodes with FFmpeg |
| `scripts/run_cabac_p16x16_chroma_residual_red_check.sh` | Legacy-named promoted gate proving integrated CABAC P16x16 Cb/Cr DC-only and Cb/Cr DC+AC residual smoke streams strict-decode with FFmpeg, exact decoded-plane SAD locks for the reduced Cb/Cr DC/AC fixtures, plane-local DC MB counters, and plane-local AC block counters after running the chroma residual wiring audit |
| `scripts/run_cabac_p16x16_luma_chroma_dc_residual_check.py` | Combined CABAC P16x16 luma+Cb+Cr DC-only residual smoke gate; locks strict two-frame FFmpeg decode, aggregate and plane-local CABAC/chroma-DC counters, `cavlc_suppressed_bits=164`, exact final P-slice bytes, and current decoded-plane metrics (`Y_SAD=2048 U_SAD=512 V_SAD=512`) so mixed luma/chroma-DC residual progress is tracked separately from the AC path |
| `scripts/run_cabac_p16x16_luma_single_chroma_dc_residual_check.py` | Combined CABAC P16x16 luma plus single-plane Cb/Cr DC-only residual smoke gate; locks strict two-frame FFmpeg decode, aggregate and plane-local chroma-DC counters, `cavlc_suppressed_bits=152`, exact final P-slice bytes, and current decoded-plane metrics (`Y_SAD=2048`, one active chroma plane at `SAD=512`, inactive plane at `0`) |
| `scripts/run_cabac_p16x16_luma_single_chroma_ac_residual_check.py` | Combined CABAC P16x16 luma plus single-plane Cb/Cr AC residual smoke gate; locks strict two-frame FFmpeg decode, plane-local CABAC chroma-AC counters, `cavlc_suppressed_bits=190`, exact final P-slice bytes, and current decoded-plane metrics (`Y_SAD=2048`, one active chroma plane at `SAD=256`, inactive plane at `0`) |
| `scripts/run_cabac_p16x16_luma_sparse_chroma_ac_residual_check.py` | Combined CABAC P16x16 luma plus sparse chroma-AC residual smoke gate; locks strict two-frame FFmpeg decode for representative single-block Cb, single-block Cr, and top-left/bottom-right same-block Cb+Cr AC cases, plane-local CABAC chroma-AC counters, exact CAVLC suppression counts, exact final P-slice bytes, and current decoded-plane metrics (`Y_SAD=2048`, active sparse chroma block at `SAD=64`) |
| `scripts/run_cabac_p16x16_luma_chroma_residual_check.py` | Combined CABAC P16x16 luma+Cb+Cr AC residual smoke gate; locks strict two-frame FFmpeg decode, CABAC/chroma counters, `cavlc_suppressed_bits=240`, exact final P-slice bytes, and current decoded-plane metrics (`Y_SAD=2048 U_SAD=256 V_SAD=256`) so mixed residual progress is tracked without overclaiming quality |
| `scripts/run_cabac_p16x16_chroma_cr_ac_probe.sh` | Focused sparse-chroma-AC probe that keeps dense Cb, dense Cr, all sparse Cr single-block quadrants, dense both-plane AC, and all sparse Cb mirror singletons as strict-pass controls while locking expected CABAC plane MB counters, per-plane AC block counters, and decoded-plane sanity for pass controls |
| `scripts/run_cabac_p16x16_chroma_cb_ac_mask_probe.sh` | Cb-only chroma-AC mask-lattice gate covering all 15 nonzero 2x2 Cb AC block masks; under the checked-in `cod_i_queue=-7` initializer every mask strict-decodes two FFmpeg frames with exact Cb-only SAD (`64 * popcount(mask)`) and zero Cr delta |
| `scripts/run_cabac_p16x16_chroma_cr_ac_mask_probe.py` | Cr-only chroma-AC mask-lattice gate covering all 15 nonzero 2x2 Cr AC block masks; under the checked-in `cod_i_queue=-7` initializer every mask strict-decodes two FFmpeg frames with exact Cr-only SAD (`64 * popcount(mask)`) and zero Cb delta |
| `scripts/run_cabac_p16x16_chroma_cr_ac_phase_probe.sh` | Cr-only chroma-AC phase/polarity diagnostic covering the first nonzero singleton residual step; locks `+4` quantized/no-AC controls and `+5`/`+8` strict two-frame FFmpeg decodes across all quadrants so the matching sparse top-row failure stays scoped to Cb/mixed-plane first-payload behavior |
| `scripts/run_cabac_p16x16_chroma_cr_ac_shape_probe.sh` | Promoted post-`cod_i_queue=-7` Cr-only chroma-AC coefficient-shape gate; locks complementary checker parities, full vertical/horizontal sweeps, and high-amplitude checker/diagonal/axis shapes across all four Cr AC blocks as strict two-frame FFmpeg decodes with byte-identical IDR, exact Cr-only SAD (`40`, `128`, or `256` by shape/amplitude), and exact final P-slice tails under the generated `d0 08 08 6b 3a...` payload prefix |
| `scripts/run_cabac_p16x16_chroma_cr_ac_amplitude_probe.sh` | Promoted post-`cod_i_queue=-7` Cr-only chroma-AC singleton-amplitude gate; locks `+4` checker perturbations as no-AC full-decode controls with exact Cr-only mismatch and `+5`/`+8` singleton residuals across all four Cr AC blocks as strict two-frame FFmpeg decodes with byte-identical IDR, exact Cr-only SAD, and exact final P-slice tails |
| `scripts/run_cabac_p16x16_chroma_cr_ac_first_payload_substitution_probe.py` | Cr-only counterpart to the first-CABAC-payload substitution diagnostic; locks that exact `0xeb->0x75` and bit7 `0xeb->0x6b` mutations promote the Cr-only miss masks while preserving already-strict Cr-only masks plus the dense Cb+Cr guard, keeping the repair target on scoped first-payload generation |
| `scripts/run_cabac_p16x16_chroma_ac_cross_plane_first_payload_probe.py` | Representative post-`cod_i_queue=-7` cross-plane Cb+Cr chroma-AC gate; locks sparse/sparse, bottom/top mirror, split-row, orthogonal axis-pair, dense-Cb, dense-Cr, dense-both, bottom-row sparse+dense, asymmetric three-block plus reciprocal mirror, prior wrong-plane mixed cases, reciprocal high-amplitude Cb/Cr cases, and mixed-sign split-row/axis-pair guards as strict two-frame FFmpeg decodes with exact plane-local SAD and exact generated final P-slice tails |
| `scripts/run_cabac_p16x16_chroma_ac_debug_compare.sh` | DEBUG_CABAC_P16X16 diagnostic compare for sparse chroma AC fail/pass pairs; locks CABACRES bin traces, CABACCTX context-state updates, CBF-before-payload ordering, decoded byte counts, and FFmpeg bytestream signatures for Cr sparse controls and Cb sparse mirror top/bottom rows so the next repair can target top-row Cb context-state/ordering behavior with known decode outcomes |
| `scripts/run_cabac_p16x16_chroma_cb_ac_arith_trace_probe.sh` | DEBUG_CABAC_P16X16 arithmetic trace probe for representative Cb-only AC masks, now including split top+bottom miss controls `0x5`/`0x6`; locks fail/pass decoded byte counts, FFmpeg signatures, CBF arithmetic/context trails, P-slice prefix emission and bit-buffer rows, residual output/emit byte chunks, stream tails, terminate pre-state, first-payload state, IDR-frame integrity, and Cb-only decoded-plane sanity for strict-pass controls |
| `scripts/run_cabac_p16x16_chroma_cb_ac_phase_probe.sh` | Cb-only sparse chroma-AC phase/polarity diagnostic covering the first nonzero singleton residual step; locks top-row parity/sign one-frame misses, the bottom-left parity/sign strict-vs-miss split, bottom-right strict controls, and exact final P-slice tails matching the checker shape probe |
| `scripts/run_cabac_p16x16_chroma_cb_ac_first_cabac_bitflip_sweep.sh` | Diagnostic bitflip sweep for the first CABAC payload byte after the locked `d0 08 08 6b` P-slice header; preserves the all-mask baseline partition and locks which single-bit mutations of `0xeb` produce strict two-frame Cb-only decodes, distinguishing the common bit7 promotion from density-dependent bit0/bit2 promotions |
| `scripts/run_cabac_p16x16_chroma_cb_ac_queue_align_probe.py` | Staged arithmetic-core queue-alignment probe that keeps the canonical source untouched, changes only the isolated workspace CABAC core initial `cod_i_queue` from `-9` to `-8`, verifies all 15 Cb-only and all 15 Cr-only chroma-AC masks strict-decode two frames with byte-identical IDR and expected plane-local SAD, locks representative mixed Cb+Cr mask pairs as strict under that candidate, and locks the remaining dense Cb+Cr AC regression final-slice mutation (`...6beb -> ...6bf599`, `0xeb->0xf5` plus trailing `0x99`) while proving bytestream-side first-payload substitution (`0xf5->0xeb/0x75`) restores strict two-frame decode and trimming only `0x99` does not |
| `scripts/run_cabac_p16x16_chroma_ac_scoped_queue_probe.py` | Historical staged scoped queue-init probe for the pre-`-7` source that ruled out selecting `-8` from current chroma-AC scan contents at slice start as a source promotion path |
| `scripts/run_cabac_p16x16_chroma_ac_queue_init_sweep.py` | Queue-initializer neighborhood sweep around the checked-in `cod_i_queue=-7` value; locks legacy `-9` sparse Cb miss signatures, known `-8` dense Cb+Cr regression, `-10` overflow behavior, and the sampled `-7` strict-decode pass for sparse Cb `0x1`/`0x2`, Cb `0x3`, and dense Cb+Cr controls with expected plane-local SAD |
| `scripts/run_cabac_p16x16_chroma_cb_ac_first_payload_substitution_probe.py` | Bytestream-side exact first-payload substitution probe that mutates only the first CABAC residual byte after the locked `d0 08 08 6b` P-slice header; proves `0xeb->0x75` and bit7 `0xeb->0x6b` both promote all Cb-only AC masks while the dense Cb+Cr guard still strict-decodes under both one-byte substitutions, separating the useful first-byte correction family from the non-committable global queue-shift side effect |
| `scripts/run_cabac_p16x16_chroma_ac_first_payload_value_sweep.py` | Representative first-CABAC-payload byte-value sweep for sparse Cb-only, Cr-only, sparse/dense Cb+Cr, and mixed-plane strict-but-wrong-quality chroma-AC controls; locks the exact byte-value ranges that produce FFmpeg strict-decode / quality-repair outcomes, proves the known `0xeb->0x75` / `0xeb->0x6b` promotions sit inside those broad equivalence classes rather than being unique byte signatures, and keeps baseline sparse Cb/Cr `0xeb` outside the short/quality-repair classes so the source repair should target the arithmetic/renormalization boundary |
| `scripts/run_cabac_p16x16_chroma_ac_second_payload_value_sweep.py` | Representative second-CABAC-payload byte-value sweep for sparse Cb-only, Cr-only, and sparse Cb+Cr chroma-AC misses; mutates only the byte after the shared baseline `d0 08 08 6b eb` prefix and locks narrower expected-SAD decode-equivalence classes while proving the current second bytes remain outside those classes |
| `scripts/run_cabac_p16x16_chroma_ac_third_payload_value_sweep.py` | Representative third-CABAC-payload byte-value sweep for the same sparse Cb-only, Cr-only, and sparse Cb+Cr chroma-AC miss set; mutates only the next payload byte, locks narrow non-unique expected-SAD decode-equivalence classes, and proves the current third bytes remain outside those classes so future fixes target CABAC arithmetic/renormalization instead of literal bytestream patching |
| `scripts/run_cabac_p16x16_chroma_ac_fourth_payload_value_sweep.py` | Representative fourth-CABAC-payload byte-value sweep for the same sparse Cb-only, Cr-only, and sparse Cb+Cr chroma-AC miss set; mutates only the fourth residual payload byte after the locked `d0 08 08 6b eb` boundary, locks very narrow expected-SAD decode-equivalence classes, and proves the current fourth bytes remain outside those classes |
| `scripts/run_cabac_p16x16_chroma_ac_fifth_payload_value_sweep.py` | Continuation fifth-CABAC-payload byte-value sweep for the representative Cr-only and sparse Cb+Cr chroma-AC misses, plus a Cb-only boundary lock proving the Cb-only stream ends at the fourth payload byte; mutates only the fifth residual payload byte where present and locks the current narrow expected-SAD decode-equivalence classes |
| `scripts/run_cabac_p16x16_chroma_ac_sixth_payload_value_sweep.py` | Continuation sixth-CABAC-payload byte-value sweep for the representative Cr-only and sparse Cb+Cr chroma-AC misses, plus a Cb-only boundary lock proving the Cb-only stream ends before this byte; mutates only the sixth residual payload byte where present, locks the Cr-only narrow expected-SAD decode-equivalence class, and locks that the sparse Cb+Cr sixth byte has no single-byte strict expected-SAD repair |
| `scripts/run_cabac_p16x16_chroma_ac_seventh_payload_value_sweep.py` | Continuation seventh-CABAC-payload byte-value sweep for the representative Cr-only chroma-AC miss, plus Cb-only and sparse Cb+Cr stream-boundary locks; mutates only the Cr-only seventh/final payload byte, locks its narrow expected-SAD decode-equivalence class, and proves the baseline final payload byte remains outside that strict class |
| `scripts/run_cabac_p16x16_chroma_cb_ac_shape_probe.sh` | Promoted post-`cod_i_queue=-7` Cb-only chroma-AC coefficient-shape gate; locks complementary checker parities, full vertical/horizontal sweeps, and high-amplitude checker/diagonal/axis shapes across all four Cb AC blocks as strict two-frame FFmpeg decodes with byte-identical IDR, exact Cb-only SAD (`40`, `128`, or `256` by shape/amplitude), and exact final P-slice tails under the generated `d0 08 08 6b 3a...` payload prefix |
| `scripts/run_cabac_p16x16_chroma_cb_ac_amplitude_probe.sh` | Promoted post-`cod_i_queue=-7` Cb-only chroma-AC singleton-amplitude gate; locks `+4` checker perturbations as no-AC full-decode controls with exact Cb-only mismatch and `+5`/`+8` singleton residuals across all four Cb AC blocks as strict two-frame FFmpeg decodes with byte-identical IDR, exact Cb-only SAD, and exact final P-slice tails |
| `scripts/run_cabac_p16x16_chroma_cb_ac_prefix_bitflip_sweep.sh` | Legacy-named all-mask diagnostic that now locks the `d0 08 08 6b` P-slice header field layout, proves the shared `0x6b` byte is the final header/CABAC-alignment byte rather than the first residual payload byte, and keeps the two strict-decode header-tail bitflips classified as parser-realignment diagnostics instead of residual-prefix repairs |
| `scripts/run_cabac_p16x16_chroma_cb_ac_tail_bitflip_probe.sh` | Focused sparse-Cb AC payload mutation probe; locks the common pre-residual slice-header/payload-boundary bit flips separately from residual-byte bit flips that can make the currently short masks strict-decode with Cb-only decoded deltas |
| `scripts/run_cabac_p16x16_chroma_cb_ac_level_suffix_probe.py` | Staged diagnostic probe that swaps the residual level suffix scaffold to a unary stop-bit form in an isolated workspace and verifies representative sparse Cb AC masks still short-decode while strict controls remain green, ruling out that simple suffix-form change as a promotion path |
| `scripts/run_cabac_p16x16_chroma_cb_ac_ctx_latency_probe.py` | Staged diagnostic probe that inserts a residual-bin handoff bubble in an isolated workspace and verifies the simple CABAC context-writeback-latency hypothesis does not promote sparse top/split Cb AC masks; it also locks the top-pair control regression and bottom-single controls under that experiment |
| `scripts/run_cabac_p16x16_chroma_cb_ac_terminate_wait_probe.py` | Staged diagnostic probe that keeps the CABAC terminate(1) wait-for-flush experiment aligned with current debug instrumentation and verifies it only shifts failing sparse-Cb signatures, not full two-frame decode promotion, while strict controls stay green |
| `scripts/run_cabac_p16x16_chroma_cb_ac_neighbor_cbf_probe.py` | Staged diagnostic probe that replaces the current sparse-Cb-only synthetic CBF walk with direct plane-local-neighbor CBF derivation and verifies representative masks `0x1`, `0x2`, `0x3`, `0x4`, `0x8`, and `0xc` all remain one-frame FFmpeg misses, rejecting that simple selector restoration as the repair path |
| `scripts/run_cabac_p16x16_chroma_cb_ac_cbf_selector_sweep.py` | Staged sparse-Cb CBF selector-table regression sweep covering the current mapping plus unavailable-edge, actual-ish, and all-same selector variants; locks that top-row Cb masks `0x1`/`0x2` remain one-frame misses while simple table remaps also regress one or more current strict controls |
| `scripts/run_cabac_p16x16_residual_red_check.sh` | Legacy alias for the promoted luma residual GREEN gate |
| `scripts/audit_cabac_chroma_residual_scaffold.py` | Static audit that locks the CABAC chroma residual CBP, scan-buffer, context-base, guarded Cb/Cr AC CBF selection, context-state dispatch, category-scheduling wiring, decoded-plane sanity checks, strict Cb/Cr DC+AC gate promotion, promoted Cb/Cr chroma-AC mask-lattice gates, promoted Cb/Cr shape/amplitude gates, dense Cb/both-plane AC strict-pass controls, per-plane chroma DC/AC counter reporting, and the combined luma+Cb+Cr residual smoke gate |
| `scripts/audit_no_testbench_repair.py` | Static audit that proves RTL bitstream ownership is retained in the TB and helper repair hooks are absent |
| `scripts/run_cabac_p16x16_residual_quality_check.sh` | Focused validation gate for the CABAC `P_L0_16x16` zero-CBP subset |
| `docker/Dockerfile` | Containerized smoke-run environment |
| `docker/run_one_frame.sh` | One-frame Docker smoke flow |
| `tools/parse_422.c` | Small debug/parser utility |

### Local-Only Directories

| Path | Contents |
| --- | --- |
| `data/` | Source media, extracted YUV inputs, generated hex data |
| `output/` | Generated streams, MP4s, logs, JSON summaries, decoded output, comparisons |
| `references/` | Spec PDFs and local development references |

These directories are intentionally treated as local-only working areas and are
ignored by default except for their small README files. Generated `.yuv`, `.h264`,
`.json`, `.log`, Verilator `obj_dir`, and scratch `.worktrees` are disposable;
keep validation evidence in committed scripts/docs, not in checked-in output blobs.
When local artifact bloat accumulates, use `git clean -fdX` from the repo root
(after verifying `git status --short` has no real source edits) to remove ignored
outputs without deleting tracked source.

## Software Baseline

The normative reference remains the H.264 / AVC specification at
`references/itu/T-REC-H.264-202408-I.pdf`.

For practical implementation comparison, the current software baseline for this
repo is the official VideoLAN `x264` encoder source tree at:

- `references/software/x264`

Local checkout used for the current docs update:

- commit: `0480cb05fa188d37ae87e8f4fd8f1aea3711f7ee`
- date: `2025-08-31`

Why this baseline was chosen:

- it is a current and widely used H.264 encoder implementation
- its public source clearly exposes the standard feature classes this repo still
  needs to close
- it is a better practical implementation target than treating the spec PDF
  alone as the gap checklist

Feature evidence in the local `x264` source:

- `x264.c` exposes `--profile`, `--level`, `--bframes`, `--b-pyramid`, `--ref`,
  `--no-deblock`, `--direct`, `--weightp`, `--me`, `--subme`, and
  `--no-cabac`
- `x264.h` exposes `I420`, `I422`, `I444`, high-depth pixel formats, and
  `IDR`, `P`, `BREF`, and `B` picture types

## Implemented Features

Current implemented features in the RTL encoder, based on the actual pipeline
in `rtl/h264_encoder_top.v` and bitstream writer in `rtl/h264_bitstream.v`:

- end-to-end RTL-owned H.264 Annex B byte-stream generation
- SPS generation in RTL
- SPS `level_idc` selection in RTL from frame macroblock count and target frame
  rate
- SPS `pic_order_cnt_type = 0` signaling in RTL with
  `log2_max_pic_order_cnt_lsb_minus4 = 5`
- SPS `log2_max_frame_num_minus4 = 4` signaling in RTL for an 8-bit
  `frame_num` field
- SPS VUI timing signaling in RTL with `num_units_in_tick`,
  `time_scale`, and `fixed_frame_rate_flag`
- SPS VUI bitstream-restriction signaling in RTL: current I/P-only streams
  advertise `max_num_reorder_frames = 0`; streams whose control lane can emit
  B/BREF pictures advertise `max_num_reorder_frames = 1` while retaining
  `max_dec_frame_buffering = 4` for the current four-reference subset
- PPS generation in RTL
- IDR slice header generation in RTL
- non-IDR slice header generation in RTL
- `pic_order_cnt_lsb` signaling in RTL on IDR and non-IDR slice headers
- 8-bit `frame_num` signaling and 9-bit `pic_order_cnt_lsb` signaling on
  IDR and non-IDR slice headers
- `pic_order_cnt_lsb` now comes from a dedicated RTL input instead of being
  derived from `frame_num`, so reordered GOPs can keep display order and
  reference numbering separate
- macroblock header generation in RTL
- RBSP trailing bits in RTL
- emulation-prevention byte insertion in RTL
- CAVLC entropy coding in RTL
- CAVLC for luma coefficients
- CAVLC for chroma DC coefficients
- CAVLC for chroma AC coefficients
- standalone 8x8 transform / inverse-transform / quantization /
  inverse-quantization / zigzag-scan support plus High-profile 8x8 luma
  transform integration
- I-frame support
- P-frame support
- P/inter partition lane now green: forced P16x8/P8x16/P8x8/P8x4/P4x8/P4x4,
  per-partition ref_idx/MVD/MVP, nonzero-MVD, qpel/subpel, chroma fractional
  interpolation, weighted-P, and following-frame reference-consumption gates
  are RTL-owned and decoder-validated
- non-reference `B`-slice support on the current intra / `I_PCM` path
- limited non-reference inter-coded `B_L0_16x16`, `B_L1_16x16`, and
  `B_BI_16x16` support on the current reordered dual-list `16x16` B path
- limited `B_DIRECT_16x16` support on the current reordered dual-list `16x16`
  B path, with spatial direct derivation from neighbor state plus colocated MB
  metadata captured per reference bank
- current limited temporal-direct support on the reordered dual-list `16x16`
  B path when the future reference picture's `List0 ref0` bank maps back to
  the current past reference, including slice-level automatic temporal-direct
  selection on reordered `B` and reordered-`BREF` slices plus
  `direct_spatial_mv_pred_flag = 0` signaling in RTL
- limited reference-`B` / `BREF` support on the current reordered dual-list
  `B_L0_16x16` / `B_L1_16x16` / `B_BI_16x16` path
- reordered `B`-GOP scheduling support in the testbench / validation flow for
  encode orders such as `0,2,1,4,3`, with non-reference `B` pictures reusing
  the same `frame_num` as the surrounding reference pair while carrying their
  own `pic_order_cnt_lsb`
- current reordered B inter selection can choose past `List0`, future `List1`,
  or bidirectional `B_BI_16x16` prediction per macroblock on the current
  limited reordered dual-list `16x16` B path
- the current reordered dual-list `B_BI_16x16` path now seeds its past-side
  search from the best stored past-reference/future-reference pair instead of
  always collapsing to `List0 ref_idx 0`, so reordered validation can exercise
  nonzero `ref_idx_l0` values on the limited B path
- the current limited `B_BI_16x16` path now writes back both motion-vector
  lists into neighbor state and refines each list through the quarter-pel luma
  path before the bidirectional average is formed
- the current limited `B_DIRECT_16x16` path now derives decoder-matching
  spatial direct vectors from neighbor state, applies the colocated zero-MV
  rule from per-bank MB metadata, uses an exact direct interpolation path
  instead of the normal qpel search loop, and can now win automatically
  against the current reordered `B_L0_16x16` / `B_L1_16x16` / `B_BI_16x16`
  candidates instead of only via a force flag
- reference-bank metadata now also retains picture-order and frame-level
  list0-reference-bank state alongside the per-MB colocated metadata, and the
  current limited temporal-direct path now consumes that metadata on reordered
  B and reordered-`BREF` slices
- reference-bank metadata now also retains the additional stored future-picture
  `List0` bank mappings needed for the current limited temporal-direct path, so
  nonzero colocated future `ref_idx_l0` values can map back into the current B
  picture's past-reference set instead of only handling future `ref_idx_l0=0`
- reference-bank metadata now also retains the current limited future-picture
  `List1 ref0` bank mapping for reordered `BREF` pictures, and the temporal-
  direct path can now derive a candidate from colocated `List1` motion when
  that stored future mapping is the usable path back into the current past-
  reference set
- plain `B_L1_16x16` final selection now explicitly stores `List1 ref_idx 0`
  instead of leaking stale `List0` ref-index state into the colocated
  metadata, so reordered-`BREF` reference slots coded as `B_L1_16x16` can
  seed later temporal-direct derivation from colocated `List1`
- the current limited `B_DIRECT_16x16` path can now collapse zero-residual
  macroblocks into RTL-owned B-slice skip-run syntax through the same late
  deferred-header path already used for zero-residual `P_SKIP`
- reordered GOP forcing can now emit reference-slot pictures as `BREF` instead
  of `P`, so encode orders such as `0,2,1,4,3` can be driven as all-BREF
  non-IDR GOPs for validation
- IDR + non-IDR encoded stream output
- `16x16` macroblock raster-order processing
- up to four forward reference pictures for P-slice motion search
- inter / intra macroblock decisioning for P-frames
- slice-level active reference override and per-macroblock `ref_idx_l0` syntax
- standards-correct `TE(v)` coding for `ref_idx_l0` in the two-reference
  P-slice case, with `UE(v)` fallback when three references are active
- deferred inter-macroblock header emission so zero-residual inter MBs can
  legally choose `cbp=0` or `P_SKIP` before any residual syntax is released
- `mb_skip_run` accumulation and flush in RTL for P-slices
- zero-residual inter MB FIFO discard in RTL when no residual syntax should be
  emitted
- zero-residual `P_SKIP` selection in RTL when the chosen inter MB is
  `ref_idx_l0 = 0` and its motion vector matches the inferred `P_SKIP`
  predictor
- motion-vector-difference syntax for supported P macroblocks
- integer-pel motion estimation
- fixed search range motion estimation
- diamond-style luma ME search
- the integer-pel ME core now resets its per-search diamond/refine state on
  every new macroblock search, preventing stale candidate state from leaking
  between macroblocks
- quarter-pel luma refinement on the current `16x16` P-macroblock inter path
- luma inter prediction from the previous reconstructed frame
- chroma fractional interpolation on the current inter path
- weighted P prediction for inter luma and chroma on the RTL path
- `pred_weight_table` slice signaling in RTL for weighted P slices
- explicit weighted B prediction on the current single-list reordered B
  subpaths and limited `B_BI_16x16` path, including B-slice
  `pred_weight_table` signaling for `List0` and `List1`
- single-list weighted `P` / `B` / direct qpel refinement now scores weighted
  luma samples during mode decision instead of scoring the unweighted
  predictor and applying weights only later in reconstruction
- full directional `Intra_4x4` mode support
- `Intra_16x16` luma prediction with `Vertical`, `Horizontal`, `DC`, and
  `Plane` mode search
- `Intra_16x16` luma-DC CAVLC now derives `nC` from the normal surrounding
  `4x4` nnz context instead of a special neighbor luma-DC count path
- current IDR-path and P-slice intra-path `I_PCM` macroblock coding with raw
  luma / Cb / Cr sample emission owned by the RTL writer
- chroma intra prediction: DC-style path
- `4x4` H.264 integer transform
- inverse transform path
- quantization path
- inverse quantization path
- zigzag scan path
- reconstruction loop in RTL
- reference-frame writeback for reconstructed luma
- reference-frame writeback for reconstructed chroma
- in-loop deblock/reconstructed-frame ownership validated on canonical commit
  `dc1d47094238f8ad973cdfb5738abd4f0d2ea951`; coverage includes the standalone
  oracle, public-decoder checks, and two-frame reference-bank consumption
- standalone CABAC arithmetic coder core RTL, plus a current final-path CABAC
  subset for skip-capable P slices with dual PPS emission, CABAC
  slice-header fields, CABAC-coded `mb_skip_flag`, CABAC-coded
  `end_of_slice_flag`, an explicit single-ref / zero-CBP / zero-MVD
  `P_L0_16x16` subset, and reduced strict-decode luma/chroma residual
  `P_L0_16x16` smoke cases. Full CABAC residual coefficient syntax is still open.
- parameterized resolution
- parameterized bit depth
- parameterized chroma format

Implemented now relative to the chosen `x264` baseline:

- Annex B bitstream generation owned by RTL
- SPS / PPS / slice-header / macroblock-header ownership in RTL
- CAVLC entropy path owned by RTL
- in-loop deblocking and deblocked reconstructed-frame reference ownership for
  the current validated path
- current CABAC final-path subset on skip-capable P slices, with CABAC PPS
  selection, CABAC-coded `mb_skip_flag`, CABAC-coded `end_of_slice_flag`, an
  explicit single-ref / zero-CBP / zero-MVD `P_L0_16x16` subset, and reduced
  strict-decode luma/chroma residual `P_L0_16x16` smoke cases
- I-picture and P-picture coding
- non-reference `B`-picture syntax on the current intra / `I_PCM` path
- limited non-reference `B_L0_16x16`, `B_L1_16x16`, and `B_BI_16x16` inter
  coding on the current reordered dual-list `16x16` B path
- limited `B_DIRECT_16x16` inter coding on the current reordered dual-list
  `16x16` B path, with automatic selection plus a force hook for targeted
  validation
- limited `B_SKIP` ownership on the current reordered dual-list `16x16`
  direct path when a chosen direct macroblock reaches zero residual
- limited reference-`B` / `BREF` picture support on the current reordered
  dual-list `16x16` B path
- explicit weighted prediction on the current single-list reordered B subpaths
- limited spatial direct prediction on the current reordered dual-list
  `16x16` B path, plus a current limited temporal-direct mode for reordered
  B slices whose future reference maps back to the current past reference
- full `Intra_4x4` directional luma mode coverage
- `Intra_16x16` luma prediction and syntax support
- current IDR-path `Intra_16x16` macroblock coding through the RTL byte stream
- current IDR-path and P-slice intra-path `I_PCM` macroblock coding through
  the RTL byte stream
- exact `I_PCM` byte-path coverage now also reaches `4:4:4` on the current IDR and
  P-slice intra path at `32x16` for both `8-bit` and `10-bit`, but the dedicated
  strict FFmpeg `4:4:4 I_PCM` smoke rows are still red on the current tree
- up-to-four-reference P-slice inter coding with integer-pel search and
  current quarter-pel luma refinement
- zero-residual inter-MB handling and `P_SKIP` skip-run ownership on the RTL
  path
- weighted P prediction and `pred_weight_table` signaling on the RTL path
- `8-bit` and `10-bit` support for `4:2:0` and `4:2:2`

## Supported And Smoke-Verified Modes

- `8-bit 4:2:0`
- `8-bit 4:2:2`
- `10-bit 4:2:0`
- `10-bit 4:2:2`

Transform / profile / color closeout snapshot (`t_267d06fd`):

- `8-bit 4:2:0` I/P-only -> Constrained Baseline; B-direct / CABAC P16x16 -> Main
- `10-bit 4:2:0` -> High 10
- `8-bit 4:2:2` -> High 4:2:2
- `8-bit 4:4:4` / `10-bit 4:4:4` -> High 4:4:4 Predictive
- High-profile 8x8 smoke -> High with `transform_8x8_mode_flag = 1`
- Evidence: `output/header_trace_matrix_summary_filtered.json`, `output/smoke_8b_420*.trace_headers.txt`, and `output/smoke_32x16_2f_{10b,422,high8x8,444,10b_444}.h264`
- Residual risk: the dedicated strict-FFmpeg `4:4:4 I_PCM` smoke rows are still red.

Current additional I_PCM-byte-path coverage (strict FFmpeg decode on the dedicated `4:4:4` smoke rows is still red):

- `8-bit 4:4:4`
- `10-bit 4:4:4`

## Validated Capabilities

Verified validation and tooling coverage around the encoder flow:

- FFmpeg-decodable RTL-generated `.h264`
- MP4 remux of the RTL-generated stream
- Docker one-frame smoke run producing RTL-generated `.h264` and `.mp4`
- reproducible smoke matrix for fast strict-decode/profile sanity on generated
  tiny `I_PCM` inputs plus tiny forced spatial-direct, temporal-direct,
  auto temporal-direct reordered-`B` and reordered-`BREF` cases,
  temporal-direct reordered-`BREF` `B_DIRECT_16x16`, mixed reordered-`BREF`
  ref-slot / B-slot temporal-direct cases, explicit reordered-`BREF`
  ref-slot `B_L1_16x16` guards, multi-ref reordered `B_BI_16x16` cases, and
  a generated flat exact-reference CABAC P-skip case plus a generated flat
  exact-reference explicit CABAC `P_L0_16x16` case
- multi-frame validation at `320x176`
- multi-frame validation at `1280x720`
- PSNR / SSIM comparison scripts
- x264 reference comparison scripts
- standalone 8x8 transform / inverse-transform / quantization /
  inverse-quantization gates at 8-bit and 10-bit, plus High-profile 8x8 smoke
  coverage
- chroma/profile/bit-depth validation on the `tpc_i_cavlc_8b420_4x4` row
- side-by-side decoded-vs-source image generation
- staged clean-build log capture for reproducible validation runs
- simulator log and cycle-count capture for regressions
- runtime-configurable `idr_interval` support in the testbench and validation
  scripts
- runtime-configurable `force_b_slice` support in the testbench and validation
  scripts for the current non-reference `B`-slice path
- runtime-configurable `force_bref_slice` support in the testbench and
  validation scripts for the current limited reference-`B` path
- runtime-configurable `reorder_b_gop` support in the testbench and validation
  scripts for reordered B-picture encode order
- runtime-configurable `force_b_bi` support in the testbench and validation
  scripts for the current limited `B_BI_16x16` path
- runtime-configurable `force_b_l0` support in the testbench and validation
  scripts for targeted validation of the current limited `B_L0_16x16` path
- runtime-configurable `force_b_l1` support in the testbench and validation
  scripts for targeted validation of the current limited `B_L1_16x16` path
- runtime-configurable `force_b_direct` support in the testbench and
  validation scripts for targeted validation of the current limited
  `B_DIRECT_16x16` path
- runtime-configurable `force_b_direct_temporal` support in the testbench and
  validation scripts so reordered B slices can switch to the current limited
  temporal-direct derivation and emit `direct_spatial_mv_pred_flag = 0`
- runtime-configurable slot-scoped `force_b_bi` / `force_b_l0` /
  `force_b_l1` / `force_b_direct` / `force_b_direct_temporal` support on
  reordered reference slots and reordered B slots, so mixed reordered-`BREF`
  validations can pin the future reference slot to `B_L0_16x16` or
  `B_L1_16x16` while pinning the later B slot to temporal direct in the same
  run
- simulator-side per-frame `b_l1_mbs` logging so reordered B validation can
  prove that the future-reference `List1` path was actually selected
- simulator-side per-frame `b_bi_mbs` logging so reordered B validation can
  prove that the bidirectional `B_BI_16x16` path was actually selected
- simulator-side per-frame `b_direct_mbs` logging so reordered B validation can
  prove that the current limited `B_DIRECT_16x16` path was actually selected,
  whether automatically or via force
- staged validation JSON and smoke summaries now carry parsed
  `skip_mbs` / `b_l1_mbs` / `b_bi_mbs` / `b_direct_mbs` /
  `b_l0_refgt0_mbs` / `b_direct_refgt0_mbs` / `b_direct_l1src_mbs` /
  `cabac_p16x16_mbs` aggregates so B-path behavior can be asserted without
  manual log scraping
- reordered validation can now combine `--reorder-b-gop` and
  `--force-bref-slice` so the reference slots are emitted as `BREF` pictures
- fast strict-decode-only validation mode in `validate_clip.py` for longer
  regression runs that do not need metrics or x264 comparison
- RTL-owned `P_SKIP` skip-run generation validated on the current P-slice path

Measured validation points:

- `docker_320x176_1f`: `816,975` cycles
- `32x16_4f_cabac_pskip_ipcmidr`: strict FFmpeg-decodable CABAC skip-only
  P-slice validation on a flat exact-reference clip, `234,131` cycles,
  `473` bytes, `Main` profile, `output/validation_cabac_pskip_ipcmidr_32x16_4f.h264`,
  `output/validation_cabac_pskip_ipcmidr_32x16_4f.mp4`, and
  `b_mode_summary.total_skip = 6`
- `32x16_2f_cabac_p16x16`: strict FFmpeg-decodable explicit CABAC
  `P_L0_16x16` zero-CBP / single-ref / zero-MVD smoke, `47,268` cycles,
  `74` bytes, `Main` profile, `output/smoke_32x16_2f_cabac_p16x16.h264`, and
  `b_mode_summary.total_cabac_p16x16 = 2`
- `32x16_2f_cabac_p16x16`: strict FFmpeg-decodable 2-frame CABAC
  `P_L0_16x16` zero-CBP checkpoint, `ffmpeg PASS`, `total_cabac_p16x16 >= 1`
- `32x16_1f_nonipcm_10b420_main_ncfix`: strict FFmpeg-decodable one-frame
  non-`I_PCM` `10-bit 4:2:0` probe, RTL PSNR avg `7.9009`, RTL SSIM
  `0.345989`
- `32x16_2f_nonipcm_10b420_idr1_ncfix`: strict FFmpeg-decodable two-frame
  all-IDR non-`I_PCM` `10-bit 4:2:0` probe, RTL PSNR avg `9.8896`, RTL SSIM
  `0.469719`
- `32x16_2f_nonipcm_10b420_p_ncfix`: strict FFmpeg-decodable two-frame IDR+P
  non-`I_PCM` `10-bit 4:2:0` probe, RTL PSNR avg `10.9076`, RTL SSIM
  `0.643681`
- `32x16_2f_nonipcm_10b422_idr1_ncfix`: strict FFmpeg-decodable two-frame
  all-IDR non-`I_PCM` `10-bit 4:2:2` probe, RTL PSNR avg `11.1312`, RTL SSIM
  `0.544361`
- `32x16_2f_nonipcm_10b422_p_ncfix`: strict FFmpeg-decodable two-frame IDR+P
  non-`I_PCM` `10-bit 4:2:2` probe, RTL PSNR avg `12.1470`, RTL SSIM
  `0.674832`
- `32x16_2f_nonipcm_8b444_idr1_ncfix`: strict FFmpeg-decodable two-frame
  all-IDR non-`I_PCM` `8-bit 4:4:4` probe, RTL PSNR avg `35.8758`, RTL SSIM
  `0.968007`
- `32x16_2f_nonipcm_8b444_p_ncfix`: strict FFmpeg-decodable two-frame IDR+P
  non-`I_PCM` `8-bit 4:4:4` probe, RTL PSNR avg `24.2915`, RTL SSIM
  `0.827152`
- `32x16_1f_nonipcm_10b444_probe_ncfix`: strict FFmpeg-decodable one-frame
  non-`I_PCM` `10-bit 4:4:4` probe, RTL PSNR avg `38.5022`, RTL SSIM
  `0.897306`
- `32x16_2f_nonipcm_10b444_idr1_ncfix`: strict FFmpeg-decodable two-frame
  all-IDR non-`I_PCM` `10-bit 4:4:4` probe, RTL PSNR avg `38.5059`, RTL SSIM
  `0.899397`
- `32x16_2f_nonipcm_10b444_p_ncfix`: strict FFmpeg-decodable two-frame IDR+P
  non-`I_PCM` `10-bit 4:4:4` probe, RTL PSNR avg `28.3215`, RTL SSIM
  `0.886921`
- `320x176_10f_nonipcm_10b420_p`: strict FFmpeg-decodable ten-frame IDR+P
  non-`I_PCM` `10-bit 4:2:0` validation, `420,156,980` cycles, `11,433`
  bytes
- `320x176_10f_nonipcm_10b422_p`: strict FFmpeg-decodable ten-frame IDR+P
  non-`I_PCM` `10-bit 4:2:2` validation, `422,555,097` cycles, `12,108`
  bytes
- `320x176_10f_nonipcm_8b444_p`: strict FFmpeg-decodable ten-frame IDR+P
  non-`I_PCM` `8-bit 4:4:4` validation, `472,182,097` cycles, `11,736`
  bytes
- `320x176_10f_nonipcm_10b444_p`: strict FFmpeg-decodable ten-frame IDR+P
  non-`I_PCM` `10-bit 4:4:4` validation, `461,752,849` cycles, `11,019`
  bytes
- `320x176_2f_nonipcm_8b444_f16f17_fixcbp`: strict FFmpeg-decodable extracted
  `8-bit 4:4:4` IDR+P validation over source frames `16..17`, `14,159,804`
  cycles, `5,298` bytes
- `320x176_4f_nonipcm_8b444_f14f17_fixcbp`: strict FFmpeg-decodable extracted
  `8-bit 4:4:4` IDR+P validation over source frames `14..17`, `88,709,796`
  cycles, `10,442` bytes
- `320x176_6f_nonipcm_8b444_f12f17_fixcbp`: strict FFmpeg-decodable extracted
  `8-bit 4:4:4` IDR+P validation over source frames `12..17`, `212,087,014`
  cycles, `16,327` bytes
- `320x176_8f_nonipcm_8b444_f10f17_fixcbp`: strict FFmpeg-decodable extracted
  `8-bit 4:4:4` IDR+P validation over source frames `10..17`, `337,204,428`
  cycles, `21,715` bytes
- `320x176_24f_nonipcm_8b444_fixcbp`: strict FFmpeg-decodable full current-tree
  `8-bit 4:4:4` IDR+P validation, `1,350,672,124` cycles, `58,281` bytes
- `320x176_24f_nonipcm_10b444_fixcbp`: strict FFmpeg-decodable full current-tree
  `10-bit 4:4:4` IDR+P validation, `1,336,320,075` cycles, `56,308` bytes
- `320x176_1f_vui`: strict FFmpeg-decodable one-frame SPS/VUI timing smoke,
  `732,748` cycles, FFmpeg `level=12`, and raw-stream timing metadata behavior
  matching a one-frame `x264` elementary stream at the same settings
- `320x176_1f_vui_restrict`: strict FFmpeg-decodable one-frame SPS/VUI
  restriction smoke, `732,753` cycles, `trace_headers` confirming
  `bitstream_restriction_flag = 1`,
  `motion_vectors_over_pic_boundaries_flag = 1`,
  `max_num_reorder_frames = 0`, and `max_dec_frame_buffering = 4`
- `320x176_1f_frame_num8`: strict FFmpeg-decodable one-frame SPS/frame-number
  smoke, `732,751` cycles, `trace_headers` confirming
  `pic_order_cnt_type = 0`,
  `log2_max_frame_num_minus4 = 4`, and
  `log2_max_pic_order_cnt_lsb_minus4 = 5`
- `320x176_4f_frame_num8`: strict FFmpeg-decodable four-frame SPS/frame-number
  validation, `92,027,135` cycles, `trace_headers` confirming
  8-bit `frame_num` values `0..3` and 9-bit `pic_order_cnt_lsb` values
  `0`, `2`, `4`, and `6`
- `320x176_4f_idr1`: strict FFmpeg-decodable all-IDR validation with
  runtime `idr_interval = 1`, `2,930,968` cycles, `5,652` bytes, and four
  SPS/PPS/IDR groups generated by the RTL path
- `320x176_1f_i16_dcquantfix`: strict FFmpeg-decodable one-frame IDR
  `Intra_16x16` validation on the current tree, `796,556` cycles, `1,147`
  bytes, RTL PSNR avg `69.336543`, RTL SSIM all `0.999940`
- `320x176_4f_i16_dcquantfix_clean`: strict FFmpeg-decodable all-IDR
  `Intra_16x16` validation on the current tree, `3,186,164` cycles, `4,588`
  bytes, RTL PSNR avg `69.336543`, RTL SSIM all `0.999940`
- `ipcm_320x176_1f`: strict FFmpeg-decodable forced-`I_PCM` IDR validation on
  the RTL byte path, `242,396` cycles, `84,963` bytes, and decoded YUV exactly
  matching the source frame byte-for-byte
- `ipcm_320x176_4f`: strict FFmpeg-decodable four-frame forced-`I_PCM`
  all-IDR validation on the RTL byte path, `969,524` cycles, `339,852` bytes,
  packaged MP4 output, and decoded YUV exactly matching the first four source
  frames byte-for-byte
- `ipcm_32x16_1f_422`: strict FFmpeg-decodable forced-`I_PCM` IDR validation
  at `32x16`, `8-bit 4:2:2`, `3,651` cycles, `1,071` bytes, High 4:2:2
  profile MP4 output, and decoded YUV exactly matching the source frame
  byte-for-byte
- `ipcm_p_32x16_2f`: strict FFmpeg-decodable two-frame validation with frame
  `0` on the IDR `I_PCM` path and frame `1` on the P-slice `I_PCM` path,
  `59,889` cycles, `1,595` bytes, packaged MP4 output, and decoded YUV exactly
  matching both source frames byte-for-byte
- `ipcm_32x16_1f_10b_latched`: strict FFmpeg-decodable forced-`I_PCM` IDR
  validation at `32x16`, `10-bit 4:2:0`, `5,965` cycles, `1,007` bytes, and
  decoded YUV exactly matching the source frame byte-for-byte
- `ipcm_32x16_1f_10b_422_latched`: strict FFmpeg-decodable forced-`I_PCM` IDR
  validation at `32x16`, `10-bit 4:2:2`, `7,885` cycles, `1,327` bytes, and
  decoded YUV exactly matching the source frame byte-for-byte
- `ipcm_p_32x16_2f_10b_latched`: strict FFmpeg-decodable two-frame validation
  with frame `0` on the IDR `I_PCM` path and frame `1` on the P-slice `I_PCM`
  path at `32x16`, `10-bit 4:2:0`, `59,645` cycles, `1,980` bytes, and decoded
  YUV exactly matching both source frames byte-for-byte
- `ipcm_p_32x16_2f_10b_422_latched`: strict FFmpeg-decodable two-frame
  validation with frame `0` on the IDR `I_PCM` path and frame `1` on the
  P-slice `I_PCM` path at `32x16`, `10-bit 4:2:2`, `62,973` cycles, `2,620`
  bytes, and decoded YUV exactly matching both source frames byte-for-byte
- `ipcm_32x16_1f_444`: strict FFmpeg-decodable forced-`I_PCM` IDR validation at
  `32x16`, `8-bit 4:4:4`, `5,065` cycles, `1,583` bytes, profile
  `High 4:4:4 Predictive`, and decoded YUV exactly matching the source frame
  byte-for-byte
- `ipcm_p_32x16_2f_444`: strict FFmpeg-decodable two-frame validation with
  frame `0` on the IDR `I_PCM` path and frame `1` on the P-slice `I_PCM` path
  at `32x16`, `8-bit 4:4:4`, `64,387` cycles, `3,132` bytes, and decoded YUV
  exactly matching both source frames byte-for-byte
- `ipcm_32x16_1f_10b_444`: strict FFmpeg-decodable forced-`I_PCM` IDR
  validation at `32x16`, `10-bit 4:4:4`, `11,723` cycles, `1,968` bytes,
  profile `High 4:4:4 Predictive`, and decoded YUV exactly matching the source
  frame byte-for-byte
- `ipcm_p_32x16_2f_10b_444`: strict FFmpeg-decodable two-frame validation with
  frame `0` on the IDR `I_PCM` path and frame `1` on the P-slice `I_PCM` path
  at `32x16`, `10-bit 4:4:4`, `69,371` cycles, `3,901` bytes, and decoded YUV
  exactly matching both source frames byte-for-byte
- `bslice_ipcm_320x176_2f`: strict FFmpeg-decodable two-frame validation with
  frame `0` on the IDR `I_PCM` path and frame `1` on the non-reference
  `B`-slice `I_PCM` path at `320x176`, `484,677` cycles, `169,893` bytes,
  packaged MP4 output, exact decoded-YUV match, and `trace_headers`
  confirmation of `nal_ref_idc = 0` and `slice_type = 1` on the second picture
- `bslice_inter_320x176_2f`: strict FFmpeg-decodable two-frame validation with
  frame `0` on the IDR `I_PCM` path and frame `1` on the non-reference
  inter-coded `B_L0_16x16` path at `320x176`, `10,048,976` cycles, `85,388`
  bytes total, exact decoded-YUV match, `trace_headers` confirmation of
  `nal_ref_idc = 0` and `slice_type = 1` on the second picture, and a `425`
  byte second-slice payload with `ENABLE_P_IPCM=0`
- `bref_inter_320x176_3f`: strict FFmpeg-decodable three-frame validation with
  frame `0` on the IDR `I_PCM` path and frames `1` and `2` on the reference-`B`
  / `BREF` inter-coded `B_L0_16x16` path at `320x176`, `19,820,383` cycles,
  `85,799` bytes total, exact decoded-YUV match, and `trace_headers`
  confirmation that both non-IDR B pictures use `nal_ref_idc = 2` with
  `slice_type = 1`
- `reorderbgop_320x176_3f`: strict FFmpeg-decodable reordered B-GOP validation
  at `320x176`, encode order `0,2,1`, `20,392,794` cycles, RTL PSNR avg
  `30.444086`, RTL SSIM all `0.774761`, with the reference P picture carrying
  `frame_num = 1`, `pic_order_cnt_lsb = 4` and the following non-reference B
  picture carrying `frame_num = 1`, `pic_order_cnt_lsb = 2`,
  `output/validation_reorderbgop_320x176_3f.h264`, and
  `output/validation_reorderbgop_320x176_3f.mp4`
- `reorderbgop_320x176_5f`: strict FFmpeg-decodable reordered B-GOP validation
  at `320x176`, encode order `0,2,1,4,3`, `62,543,870` cycles, decode-only
  strict check closed cleanly, `output/validation_reorderbgop_320x176_5f.h264`,
  and `output/validation_reorderbgop_320x176_5f.mp4`
- `bl1_320x176_3f`: strict FFmpeg-decodable reordered B-GOP validation at
  `320x176`, encode order `0,2,1`, `37,760,283` cycles, `3,797` bytes, RTL
  PSNR avg `30.444086`, RTL SSIM all `0.774761`,
  `output/validation_bl1_320x176_3f.h264`, and
  `output/validation_bl1_320x176_3f.mp4`
- `bl1_force_32x16_3f`: strict FFmpeg-decodable forced-`B_L1_16x16`
  reordered-B validation at `32x16`, `3` frames, `129,691` cycles, `98` bytes,
  `output/validation_bl1_force_32x16_3f.h264`, and
  `output/validation_bl1_force_32x16_3f.mp4`, with simulator logging showing
  `b_l1_mbs=2` on the B picture
- `reorderbrefgop2_320x176_5f`: strict FFmpeg-decodable reordered all-`BREF`
  validation at `320x176`, encode order `0,2,1,4,3`, `93,507,221` cycles,
  `4,761` bytes, `output/validation_reorderbrefgop2_320x176_5f.h264`, and
  `output/validation_reorderbrefgop2_320x176_5f.mp4`, with simulator logging
  showing every non-IDR picture emitted as `BREF`
- `weightedb_bl1_32x16_3f`: strict FFmpeg-decodable weighted-B reordered
  validation at `32x16`, `3` frames, `130,005` cycles,
  `output/validation_weightedb_bl1_32x16_3f.h264`, and
  `output/validation_weightedb_bl1_32x16_3f.mp4`, with `trace_headers`
  confirming `weighted_bipred_idc = 1` in PPS and B-slice `pred_weight_table`
  entries for both `List0` and `List1`
- `autobi_qpelprobe_320x176_5f`: strict FFmpeg-decodable current-tree reordered
  all-`BREF` validation at `320x176`, `5` frames, `93,525,885` cycles,
  `4,761` bytes, RTL PSNR avg `32.579259`, RTL SSIM all `0.863570`,
  `output/validation_autobi_qpelprobe_320x176_5f.h264`, and
  `output/validation_autobi_qpelprobe_320x176_5f.json`, with simulator logging
  showing `b_bi_mbs=0` on the three non-IDR pictures
- `forcebbi_qpelprobe_32x16_3f`: strict FFmpeg-decodable current-tree
  forced-`B_BI_16x16` reordered-B validation at `32x16`, `3` frames,
  `130,715` cycles, `150` bytes, RTL PSNR avg `30.120198`, RTL SSIM all
  `0.774794`, `output/validation_forcebbi_qpelprobe_32x16_3f.h264`, and
  `output/validation_forcebbi_qpelprobe_32x16_3f.json`
- `forcebbi_qpelprobe_320x176_5f`: strict FFmpeg-decodable current-tree
  forced-`B_BI_16x16` reordered all-`BREF` validation at `320x176`, `5`
  frames, `91,943,969` cycles, `10,281` bytes, RTL PSNR avg `15.889197`,
  RTL SSIM all `0.837371`,
  `output/validation_forcebbi_qpelprobe_320x176_5f.h264`, and
  `output/validation_forcebbi_qpelprobe_320x176_5f.json`, with simulator
  logging showing `b_bi_mbs=220` on the last two non-IDR pictures
- `forcebbi_qpelcmp_weightedbi5_320x176_5f`: strict FFmpeg-decodable
  current-tree forced-`B_BI_16x16` reordered all-`BREF` validation at
  `320x176`, `5` frames, non-default explicit B weights (`5` with denom `2`),
  `92,405,579` cycles, `19,258` bytes, RTL PSNR avg `32.63735`, RTL SSIM all
  `0.864016`,
  `output/validation_forcebbi_qpelcmp_weightedbi5_320x176_5f.h264`, and
  `output/validation_forcebbi_qpelcmp_weightedbi5_320x176_5f.json`, with
  simulator logging showing `b_bi_mbs=220` on the last two non-IDR pictures
  and `output/validation_forcebbi_qpelcmp_weightedbi5_320x176_5f.trace.txt`
  confirming
  `weighted_bipred_idc = 1`, `luma_log2_weight_denom = 2`,
  `chroma_log2_weight_denom = 2`, and list0/list1 luma/chroma weights of `5`
- `bmultiref_ref1win_32x16_5f_ipcmrefs`: strict FFmpeg-decodable current-tree
  forced-`B_BI_16x16` reordered-B validation at `32x16`, `5` frames, exact
  IDR/P `I_PCM` references, `329,003` cycles, `1,408` bytes,
  `output/validation_bmultiref_ref1win_32x16_5f_ipcmrefs.h264`, and
  `output/validation_bmultiref_ref1win_32x16_5f_ipcmrefs.json`, with
  `b_mode_summary` showing `total_bi = 4` and `total_l0_refgt0 = 2`, proving
  the limited reordered multi-ref `B_BI_16x16` path can now emit nonzero
  `List0 ref_idx` values
- `autobi_qpelcmp_weightedbi5_320x176_5f`: strict FFmpeg-decodable
  current-tree reordered all-`BREF` validation at `320x176`, `5` frames,
  non-default explicit B weights (`5` with denom `2`), `97,793,335` cycles,
  `18,872` bytes, RTL PSNR avg `32.421436`, RTL SSIM all `0.86191`,
  `output/validation_autobi_qpelcmp_weightedbi5_320x176_5f.h264`, and
  `output/validation_autobi_qpelcmp_weightedbi5_320x176_5f.json`, with
  simulator logging still showing `b_l1_mbs=220` on the two middle non-IDR
  pictures and `b_bi_mbs=0` across the run
- `bdirect_force_32x16_3f`: strict FFmpeg-decodable forced-`B_DIRECT_16x16`
  reordered-`BREF` validation at `32x16`, `3` frames, `131,068` cycles,
  `265` bytes, RTL PSNR avg `27.36622`, RTL SSIM all `0.554193`,
  `output/validation_bdirect_force_32x16_3f.h264`,
  `output/validation_bdirect_force_32x16_3f.mp4`, and simulator logging
  showing `b_direct_mbs=2` on the last picture
- `bdirect_force_320x176_5f`: strict FFmpeg-decodable forced-`B_DIRECT_16x16`
  reordered all-`BREF` validation at `320x176`, `5` frames, `97,641,789`
  cycles, `25,505` bytes, RTL PSNR avg `13.670634`, RTL SSIM all `0.668749`,
  `output/validation_bdirect_force_320x176_5f.h264`,
  `output/validation_bdirect_force_320x176_5f.mp4`, and simulator logging
  showing `b_direct_mbs=220` on each non-IDR picture
- `bdirect_auto_probe_32x16_3f`: strict FFmpeg-decodable non-forced auto
  `B_DIRECT_16x16` reordered-B validation at `32x16`, `3` frames, `130,756`
  cycles, `122` bytes, RTL PSNR avg `30.120198`, RTL SSIM all `0.774794`,
  `output/validation_bdirect_auto_probe_32x16_3f.h264`, and simulator logging
  showing `b_direct_mbs=1` on the last picture
- `bdirect_auto_probe_320x176_5f`: strict FFmpeg-decodable non-forced
  decode-only reordered all-`BREF` validation at `320x176`, `5` frames,
  `93,162,228` cycles, `4,666` bytes,
  `output/validation_bdirect_auto_probe_320x176_5f.h264`, and simulator
  logging showing nonzero `b_direct_mbs` across all three non-IDR pictures
  (`219`, `148`, and `31`)
- `bdirect_bskip_auto_320x176_5f_json`: strict FFmpeg-decodable non-forced
  decode-only reordered all-`BREF` validation at `320x176`, `5` frames,
  `93,158,455` cycles, `4,541` bytes,
  `output/validation_bdirect_bskip_auto_320x176_5f_json.h264`, with staged
  JSON `b_mode_summary` reporting `frames_with_skip=3`, `total_skip=393`,
  `max_skip=219`, `frames_with_direct=3`, and simulator skip counts of
  `219`, `148`, and `26` across the three non-IDR pictures
- `temporal_direct_force_32x16_3f`: strict FFmpeg-decodable forced
  temporal-direct reordered-B validation at `32x16`, `3` frames, `131,063`
  cycles, `263` bytes, `output/validation_temporal_direct_32x16_3f.h264`,
  `output/validation_temporal_direct_32x16_3f.json`, and header-trace proof of
  `direct_spatial_mv_pred_flag = 0` with `b_direct_mbs=2`
- `temporal_direct_force_320x176_3f`: strict FFmpeg-decodable decode-only
  forced temporal-direct reordered-B validation at `320x176`, `3` frames,
  `37,905,407` cycles, `21,423` bytes,
  `output/validation_temporal_direct_320x176_3f.h264`,
  `output/validation_temporal_direct_320x176_3f.json`, and header-trace proof
  of `direct_spatial_mv_pred_flag = 0` with `b_direct_mbs=220`
- `temporal_direct_bref_force_32x16_3f`: strict FFmpeg-decodable forced
  temporal-direct reordered-`BREF` validation at `32x16`, `3` frames,
  `131,068` cycles, `265` bytes,
  `output/validation_temporal_direct_bref_fix_32x16_3f.h264`,
  `output/validation_temporal_direct_bref_fix_32x16_3f.json`, and
  header-trace proof that both non-IDR `BREF` slices emit
  `direct_spatial_mv_pred_flag = 0` while the last picture reports
  `b_direct_mbs=2`
- `temporal_direct_bref_force_320x176_3f`: strict FFmpeg-decodable decode-only
  forced temporal-direct reordered-`BREF` validation at `320x176`, `3`
  frames, `37,905,588` cycles, `21,534` bytes,
  `output/validation_temporal_direct_bref_fix_320x176_3f.h264`,
  `output/validation_temporal_direct_bref_fix_320x176_3f.json`, and
  header-trace proof that both non-IDR `BREF` slices emit
  `direct_spatial_mv_pred_flag = 0` while the last picture reports
  `b_direct_mbs=220`
- `temporal_direct_ref1_32x16_7f`: strict FFmpeg-decodable decode-only forced
  temporal-direct reordered-B validation at `32x16`, `7` frames, `608,780`
  cycles, `525` bytes, `output/validation_temporal_direct_ref1_32x16_7f.h264`,
  `output/validation_temporal_direct_ref1_32x16_7f.json`, and header-trace
  proof that the B slices emit `direct_spatial_mv_pred_flag = 0`, with
  `b_mode_summary` reporting `total_direct=6` and `total_direct_refgt0=4`,
  proving the current limited temporal-direct path can now consume nonzero
  future-picture `List0 ref_idx` mappings
- `temporal_direct_auto_32x16_7f_autoslice`: strict FFmpeg-decodable
  decode-only auto temporal-direct reordered-B validation at `32x16`, `7`
  frames, `608,096` cycles, `274` bytes,
  `output/validation_temporal_direct_b_auto_32x16_7f_autoslice.h264`,
  `output/validation_temporal_direct_b_auto_32x16_7f_autoslice.json`, with
  header-trace proof that the reordered B slices emit
  `direct_spatial_mv_pred_flag = 0`, with the RTL auto-switching the slice to
  temporal direct and `b_mode_summary` reporting `total_direct=4` and
  `total_direct_refgt0=4`
- `temporal_direct_bref_auto_refslotl0_32x16_7f_autoslice`: strict
  FFmpeg-decodable decode-only auto temporal-direct reordered-`BREF`
  validation at `32x16`, `7` frames, `707,309` cycles, `253` bytes,
  `output/validation_temporal_direct_bref_auto_from_refslotl0_32x16_7f_autoslice.h264`,
  `output/validation_temporal_direct_bref_auto_from_refslotl0_32x16_7f_autoslice.json`,
  with header-trace proof that the first reordered `BREF` ref slot stays
  `direct_spatial_mv_pred_flag = 1` while the later reordered `BREF` slices
  auto-switch to `0`, the future reordered `BREF` ref slot pinned to
  `B_L0_16x16`, and the later reordered `BREF` slice auto-switching to
  temporal direct,
  `b_mode_summary` reporting `total_l0_refgt0=6`, `total_direct=2`, and
  `total_direct_refgt0=2`
- `temporal_direct_bref_mixed_refslotl0_32x16_7f`: strict FFmpeg-decodable
  decode-only mixed reordered-`BREF` validation at `32x16`, `7` frames,
  `718,775` cycles, `505` bytes,
  `output/validation_temporal_direct_bref_mixed_refslotl0_32x16_7f.h264`,
  `output/validation_temporal_direct_bref_mixed_refslotl0_32x16_7f.json`,
  and simulator-log proof that reordered reference slots ran with
  `force_l0=1` while reordered B slots ran with
  `force_direct=1 force_direct_temporal=1`, with `b_mode_summary`
  reporting `total_l0_refgt0=6`, `total_direct=4`, and
  `total_direct_refgt0=2`, proving the current limited temporal-direct path
  can now consume nonzero future `List0` mappings coming from reordered
  `BREF` reference slots instead of only future P pictures
- `temporal_direct_bref_mixed_refslotl0_320x176_3f`: strict
  FFmpeg-decodable decode-only mixed reordered-`BREF` validation at
  `320x176`, `3` frames, `37,905,588` cycles, `21,534` bytes,
  `output/validation_temporal_direct_bref_mixed_refslotl0_320x176_3f.h264`,
  `output/validation_temporal_direct_bref_mixed_refslotl0_320x176_3f.json`,
  and simulator-log proof that the same slot-scoped forcing holds on the
  larger real clip, with the middle reordered `BREF` picture pinned to
  `B_L0_16x16` and the final reordered `BREF` picture pinned to temporal
  direct
- `temporal_direct_bref_mixed_refslotbi_32x16_5f`: strict FFmpeg-decodable
  decode-only mixed reordered-`BREF` validation at `32x16`, `5` frames,
  `404,704` cycles, `1,521` bytes,
  `output/validation_temporal_direct_bref_mixed_refslotbi_32x16_5f.h264`,
  `output/validation_temporal_direct_bref_mixed_refslotbi_32x16_5f.json`,
  and simulator-log proof that reordered reference slots ran with
  `force_bi=1` while reordered B slots ran with
  `force_direct=1 force_direct_temporal=1`, with `b_mode_summary`
  reporting `total_bi=6`, `total_l0_refgt0=4`, `total_direct=4`, and
  `total_direct_refgt0=2`, proving the current limited temporal-direct path
  can also consume nonzero future `List0` mappings coming from reordered
  `BREF` reference slots that were themselves coded on the limited
  `B_BI_16x16` path
- `temporal_direct_bref_bi_ref1_l1src_32x16_5f`: strict FFmpeg-decodable
  decode-only mixed reordered-`BREF` validation at `32x16`, `5` frames,
  `404,573` cycles, `1,537` bytes,
  `output/validation_temporal_direct_bref_bi_ref1_l1src_32x16_5f.h264`, and
  `output/validation_temporal_direct_bref_bi_ref1_l1src_32x16_5f.json`, with
  reordered reference slots pinned to `B_BI_16x16` and reordered B slots
  pinned to temporal direct, and `b_mode_summary` reporting `total_direct=4`
  plus `total_direct_l1src=2`, proving the current limited temporal-direct
  path can now derive direct macroblocks from colocated `List1` on future
  reordered-`BREF` BI pictures
- `temporal_direct_bref_bi_ref1_l1src_320x176_5f`: strict FFmpeg-decodable
  decode-only mixed reordered-`BREF` validation at `320x176`, `5` frames,
  `119,819,413` cycles, `152,910` bytes,
  `output/validation_temporal_direct_bref_bi_ref1_l1src_320x176_5f.h264`,
  `output/validation_temporal_direct_bref_bi_ref1_l1src_320x176_5f.json`, and
  header-trace proof that the later reordered `BREF` slices still emit
  `direct_spatial_mv_pred_flag = 0`, with `b_mode_summary` reporting
  `total_direct=607`, `total_direct_refgt0=357`, and `total_direct_l1src=30`
- `temporal_direct_bref_auto_from_refslotbi_32x16_5f_l1src`: strict
  FFmpeg-decodable decode-only mixed reordered-`BREF` auto probe at `32x16`,
  `5` frames, `400,988` cycles, `1,497` bytes,
  `output/validation_temporal_direct_bref_auto_from_refslotbi_32x16_5f_l1src.h264`,
  and `output/validation_temporal_direct_bref_auto_from_refslotbi_32x16_5f_l1src.json`,
  showing that the new colocated-`List1` temporal-direct path is present but
  the non-forced selector on this tiny probe still prefers `B_BI_16x16` /
  `B_L1_16x16`, with `total_direct=0`
- `temporal_direct_bref_auto_from_refslotbi_320x176_5f_l1src`: strict
  FFmpeg-decodable decode-only mixed reordered-`BREF` auto validation at
  `320x176`, `5` frames, `121,592,814` cycles, `150,112` bytes,
  `output/validation_temporal_direct_bref_auto_from_refslotbi_320x176_5f_l1src.h264`,
  `output/validation_temporal_direct_bref_auto_from_refslotbi_320x176_5f_l1src.json`,
  and header-trace proof that the later reordered `BREF` slices still emit
  `direct_spatial_mv_pred_flag = 0`, with `b_mode_summary` reporting
  `total_direct=337`, `total_direct_refgt0=167`, and `total_direct_l1src=170`
- `temporal_direct_bref_mixed_refslotl1_32x16_7f_inter_fix1`: strict
  FFmpeg-decodable decode-only mixed reordered-`BREF` validation at `32x16`,
  `7` frames, `724,380` cycles, `1,821` bytes,
  `output/validation_temporal_direct_bref_mixed_refslotl1_32x16_7f_inter_fix1.h264`,
  `output/validation_temporal_direct_bref_mixed_refslotl1_32x16_7f_inter_fix1.json`,
  and header-trace proof in
  `output/validation_temporal_direct_bref_mixed_refslotl1_32x16_7f_inter_fix1.trace_headers.txt`
  that later reordered `BREF` slices emit `direct_spatial_mv_pred_flag = 0`,
  with reordered reference slots pinned to `B_L1_16x16`, reordered B slots
  pinned to temporal direct, and `b_mode_summary` reporting `total_l1=4`,
  `total_direct=6`, and `total_direct_l1src=4`
- `temporal_direct_bref_auto_from_refslotl1_32x16_7f_inter_fix1`: strict
  FFmpeg-decodable decode-only mixed reordered-`BREF` auto validation at
  `32x16`, `7` frames, `739,640` cycles, `1,587` bytes,
  `output/validation_temporal_direct_bref_auto_from_refslotl1_32x16_7f_inter_fix1.h264`,
  `output/validation_temporal_direct_bref_auto_from_refslotl1_32x16_7f_inter_fix1.json`,
  and header-trace proof in
  `output/validation_temporal_direct_bref_auto_from_refslotl1_32x16_7f_inter_fix1.trace_headers.txt`
  that the first reordered `BREF` slice stays spatial while later ones switch
  to temporal direct, with `b_mode_summary` reporting `total_l1=6`,
  `total_direct=2`, and `total_direct_l1src=2`
- `temporal_direct_bref_mixed_refslotl1_320x176_7f_fix1`: strict
  FFmpeg-decodable decode-only mixed reordered-`BREF` validation at
  `320x176`, `7` frames, `233,261,934` cycles, `129,453` bytes,
  `output/validation_temporal_direct_bref_mixed_refslotl1_320x176_7f_fix1.h264`,
  `output/validation_temporal_direct_bref_mixed_refslotl1_320x176_7f_fix1.json`,
  and simulator-log proof that reordered reference slots pinned to
  `B_L1_16x16` can drive later temporal-direct slices through colocated
  `List1`, with `b_mode_summary` reporting `total_l1=20`, `total_direct=1080`,
  `total_direct_refgt0=640`, and `total_direct_l1src=220`
- `temporal_direct_bref_auto_from_refslotl1_320x176_7f_fix1`: strict
  FFmpeg-decodable decode-only mixed reordered-`BREF` auto validation at
  `320x176`, `7` frames, `233,399,683` cycles, `97,921` bytes,
  `output/validation_temporal_direct_bref_auto_from_refslotl1_320x176_7f_fix1.h264`,
  `output/validation_temporal_direct_bref_auto_from_refslotl1_320x176_7f_fix1.json`,
  and simulator-log proof that the non-forced selector now reaches the same
  colocated-`List1` temporal-direct path on the larger clip, with
  `b_mode_summary` reporting `total_l1=341`, `total_bi=759`,
  `total_direct=727`, `total_direct_refgt0=413`, and `total_direct_l1src=314`
- `bl0_force_ref1_32x16_7f_ipcmrefs`: strict FFmpeg-decodable decode-only
  reordered-B validation at `32x16`, `7` frames, exact IDR/P `I_PCM`
  references, `581,041` cycles, `4,234` bytes,
  `output/validation_bl0_force_ref1_32x16_7f_ipcmrefs.h264`, and
  `output/validation_bl0_force_ref1_32x16_7f_ipcmrefs.json`, with
  `force_b_l0=1` pinning the current limited `B_L0_16x16` path and
  `b_mode_summary` reporting `total_l0_refgt0=2` while `total_bi=0`,
  `total_direct=0`, and `total_direct_refgt0=0`, proving the plain
  `B_L0_16x16` path can emit nonzero past-reference indices without BI/direct
  fallback
- `bdirect_auto_weighted_32x16_3f`: strict FFmpeg-decodable weighted
  non-forced auto `B_DIRECT_16x16` reordered-B validation at `32x16`, `3`
  frames, `131,078` cycles, `180` bytes, RTL PSNR avg `30.158513`, RTL SSIM
  all `0.775715`, `output/validation_bdirect_auto_weighted_32x16_3f.h264`,
  and simulator logging showing `b_direct_mbs=1` on the last picture
- `bdirect_bskip_auto_32x16_3f`: strict FFmpeg-decodable non-forced auto
  reordered-`BREF` validation at `32x16`, `3` frames, `130,749` cycles,
  `122` bytes, RTL PSNR avg `30.120198`, RTL SSIM all `0.774794`,
  `output/validation_bdirect_bskip_auto_32x16_3f.h264`, and simulator logging
  showing `skip_mbs=1`, `b_l1_mbs=2`, and `b_direct_mbs=1` on the last
  picture, proving the current limited `B_DIRECT_16x16` path can collapse to
  B-slice skip syntax on a zero-residual macroblock
- `weightedp_small_32x16_2f`: strict FFmpeg-decodable small weighted-P
  validation at `32x16`, `2` frames, `51,117` cycles, `112` bytes, RTL PSNR
  avg `28.420753`, RTL SSIM all `0.66449`, and
  `output/validation_weightedp_small_32x16_2f.h264`
- `32x16_2f_444_ipcm_scripted`: strict staged validation through
  `scripts/validate_clip.py` with `--enable-idr-ipcm 1 --enable-p-ipcm 1`
  at `32x16`, `8-bit 4:4:4`, packaged MP4 output, and JSON summary in
  `output/validation_32x16_2f_444_ipcm_scripted.json`
- `320x176_4f_decodeonly`: strict FFmpeg-decodable multi-frame decode-only
  validation on the current tree, `92,028,425` cycles, `1,912` bytes, paired
  staged `.build.log` / `.sim.log`, JSON validation-mode recording, and
  packaged MP4 output without PSNR / SSIM, x264, or side-by-side PNG work
- `320x176_10f_tefix`: strict FFmpeg-decodable current-tree validation,
  `253,064,186` cycles, RTL PSNR avg `45.745576`, RTL SSIM all `0.994893`
- `320x176_24f_tefix`: strict FFmpeg-decodable current-tree validation,
  `640,575,297` cycles, RTL PSNR avg `43.767484`, RTL SSIM all `0.989193`
- `320x176_10f_multiref3`: strict FFmpeg-decodable three-reference P-slice
  validation, `367,542,946` cycles, `15,781` bytes, SPS
  `max_num_ref_frames = 3`, RTL PSNR avg `45.752063`, RTL SSIM all `0.994913`
- `320x176_24f_multiref3`: strict FFmpeg-decodable three-reference P-slice
  validation, `913,475,277` cycles, `51,219` bytes, later P-slices with
  `num_ref_idx_l0_active_minus1 = 2`, RTL PSNR avg `43.7528`, RTL SSIM all
  `0.989176`
- `320x176_4f_multiref4`: strict FFmpeg-decodable four-reference P-slice
  validation, `92,027,039` cycles, `5,058` bytes, SPS
  `max_num_ref_frames = 4`, RTL PSNR avg `43.883472`, RTL SSIM all `0.995357`
- `320x176_6f_multiref4`: strict FFmpeg-decodable four-reference P-slice
  validation, `217,593,800` cycles, `7,844` bytes, later P-slices with
  `num_ref_idx_l0_active_minus1 = 3`, RTL PSNR avg `45.207556`, RTL SSIM all
  `0.996333`
- `320x176_4f_weightedp`: strict FFmpeg-decodable weighted-P validation on the
  RTL path, Main profile stream, RTL PSNR avg `25.806041`, RTL SSIM all
  `0.333568`
- `320x176_4f_pskip3`: strict FFmpeg-decodable deferred-inter-header /
  zero-residual-`P_SKIP` validation on the RTL path, `92,028,425` cycles,
  `1,912` bytes, RTL PSNR avg `43.883472`, RTL SSIM all `0.995357`, and
  simulator-reported `P_SKIP` counts of `123`, `152`, and `134` across the
  three validated P-frames
- `320x176_4f_multiref`: earlier strict FFmpeg-decodable two-reference P-slice
  validation on the RTL path, `50,611,399` cycles, SPS
  `max_num_ref_frames = 2`, later P-slices with
  `num_ref_idx_active_override_flag = 1`, RTL PSNR avg `25.806041`, RTL SSIM
  all `0.333568`
- `720p_24f`: `4,096,671,438` cycles, RTL PSNR avg `41.759917`, RTL SSIM all
  `0.995232`
- `320x176_1f_i16x16_fix2`: current-tree FFmpeg-decodable `Intra_16x16`
  smoke, RTL PSNR avg `25.8060`, RTL SSIM all `0.333568`

Current verified milestone outputs:

- `320x176`, `24` frames: packaged MP4 from RTL-generated H.264
- `1280x720`, `24` frames: packaged MP4 from RTL-generated H.264
- Docker one-frame `320x176` smoke run: packaged MP4 from RTL-generated H.264

## Known Correctness Notes

- a `720p` chroma corruption issue was traced to raw input address overflow on
  the Cr plane fetch path and fixed by widening the raw input address width
- a directional `Intra_4x4` top-right reference fetch bug was fixed in
  `rtl/h264_encoder_top.v`
- the multi-reference P-slice path was fixed to encode `ref_idx_l0` with
  standards-correct `TE(v)` coding when two refs are active, removing the
  later-frame parser corruption seen in strict `320x176` multi-frame decode
- the current tree now advertises `max_num_ref_frames = 3` and later P-slices
  can emit `num_ref_idx_l0_active_minus1 = 2`
- the current tree now advertises `max_num_ref_frames = 4` and later P-slices
  can emit `num_ref_idx_l0_active_minus1 = 3`
- the current inter path already performs quarter-pel luma refinement and
  chroma fractional interpolation after the integer-pel ME pass
- SPS `level_idc` is now selected from frame size and configured frame rate
  instead of the earlier hardcoded split
- SPS VUI timing fields are now emitted from RTL for the configured frame rate
- SPS profile/VUI signalling now consumes a stream-level B-slice GOP contract:
  current I/P-only 8-bit 4:2:0 streams stay Constrained Baseline with
  `max_num_reorder_frames = 0`, while B/BREF/reordered-GOP runs escalate to
  Main profile and advertise `max_num_reorder_frames = 1` from the first SPS
- SPS VUI bitstream-restriction fields otherwise keep HRD absent and retain the
  current four-reference `max_dec_frame_buffering = 4` subset
- baseline/main SPS now uses `pic_order_cnt_type = 0`, and the current RTL
  IDR / P slice headers emit `pic_order_cnt_lsb`
- the current RTL path now advertises `log2_max_frame_num_minus4 = 4` and
  emits 8-bit `frame_num` values in slice headers
- the testbench and `validate_clip.py` now accept a runtime `idr_interval`;
  `1` forces every frame to IDR, and `0` means only the first frame is IDR
- `validate_clip.py` now supports `--decode-only` plus granular skip flags for
  metrics, x264 reference encode, side-by-side PNG generation, and MP4
  packaging so longer strict-decode regressions can stay cheaper
- the `Intra_16x16` IDR path now emits mb_type values that match the residual
  syntax the RTL actually outputs, removing the earlier first-row FFmpeg decode
  failure at `MB 2 0`
- the current RTL writer now supports `I_PCM` macroblocks on the IDR path,
  byte-aligns with `pcm_alignment_zero_bit`, emits raw luma / Cb / Cr samples
  through the RTL byte path itself, and decodes back to an exact byte-for-byte
  match on the validated `320x176 4:2:0` and `32x16 4:2:2` all-IDR cases
- the `I_PCM` source path is now latched in `rtl/h264_encoder_top.v` before the
  bitstream emit begins, which closes the earlier corruption where the live
  fetch bus could be overwritten by the next macroblock during `10-bit` sample
  emission
- the current tree now supports `I_PCM` on the IDR path and the current
  P-slice intra path for `8-bit` and `10-bit` builds in both `4:2:0` and
  `4:2:2`, and `tb/Makefile` exposes `ENABLE_IDR_IPCM`, `ENABLE_P_IPCM`,
  `IPCM_SAD_THRESHOLD`, and `INTER_SAD_THRESHOLD` so the path can be
  reproduced without raw `EXTRA_VERILATOR_ARGS`
- the current tree emits `4:4:4 I_PCM` bytes on the IDR path and current P-slice intra path at `32x16` for `8-bit` and
  `10-bit`, and ffprobe still reports `High 4:4:4 Predictive`, but the dedicated strict FFmpeg `4:4:4 I_PCM` smoke rows are still red on the current tree
- the `4:4:4` inter path must use the ChromaArrayType `3`
  `coded_block_pattern` table rather than the `4:2:x` inter code; the current
  RTL writer now emits the correct full-residual inter code on that path, and
  focused strict-decode reruns ending on the old bad picture re-close at
  `320x176` for extracted `2`-frame and `4`-frame clips
- the current reordered B path now carries explicit list0/list1 neighbor MV
  state, list-specific MVD syntax, per-list quarter-pel luma refinement,
  qpel-aware final `B_L0` / `B_L1` / `B_BI` luma comparison on the dual-ref B
  path, and explicit weighted bipred combine on the limited `B_BI_16x16`
  path, which re-opened forced strict-decode validation at `32x16` and
  `320x176`; the real `320x176` weighted reordered clip still selects
  `B_L1_16x16` automatically rather than `B_BI_16x16`
- `scripts/validate_clip.py` and `scripts/rtl_runner.py` now expose
  `ENABLE_IDR_IPCM`, `ENABLE_P_IPCM`, `IPCM_SAD_THRESHOLD`, and
  `INTER_SAD_THRESHOLD` so staged validation can reproduce the `I_PCM` paths
  instead of relying on ad-hoc `make` commands
- the `Intra_16x16` luma-DC path in `rtl/h264_luma_dc.v` now keeps the
  forward rounded Hadamard output, uses the DC-specific forward quant step,
  latches the input payload for execution, and restores the missing
  scaling-list factor on inverse dequant; that re-closed the current IDR-path
  `Intra_16x16` reconstruction quality on the validated `320x176` all-IDR run
- `scripts/trace_header_matrix.py` now regenerates focused smoke rows, runs
  strict FFmpeg decode plus `ffprobe`, stores per-row `trace_headers` text, and
  asserts the current header-control contract: no Baseline+B/CABAC overclaim,
  B/reordered streams advertise Main plus `max_num_reorder_frames >= 1`, HRD
  flags stay absent, and High-profile `transform_8x8_mode_flag` stays `0`
- deferred inter headers and FIFO discard now prevent illegal zero-residual
  CAVLC payloads from leaking after `cbp=0` or `P_SKIP`, which is what made
  the earlier zero-residual inter-header attempt invalid

## Not Done Yet

Important missing features, so this does not get confused with a full-standard
H.264 encoder yet:

- CABAC context modelling, syntax binarization, and final bitstream-path
  integration beyond the current skip-capable plus reduced single-ref /
  zero-MVD `P_L0_16x16` P-slice subset with luma/chroma residual smokes
- no broader `B` / `BREF` picture support beyond the current limited
  reordered dual-list `B_L0_16x16` / `B_L1_16x16` / `B_BI_16x16` `16x16` path
- direct prediction modes beyond the current limited
  `B_DIRECT_16x16` reordered-`BREF` path
- reference-picture management beyond the current four-reference P-slice subset
- broader full-standard sub-pel motion handling beyond the current `16x16`
  quarter-pel luma path
- broader inter partition coverage beyond the current High-profile 8x8
  transform gates
- broader `4:4:4` chroma support beyond the current `320x176` strict-decode non-`I_PCM` path and the still-red `32x16` `4:4:4 I_PCM` smoke rows is not implemented
- full-standard profile / level / tool coverage

Still missing relative to the chosen `x264` software baseline:

- full CABAC slice integration beyond the current standalone arithmetic core
  and current skip-capable plus reduced single-ref / zero-MVD `P_L0_16x16`
  P-slice checkpoint with luma/chroma residual smokes
- broader inter-coded `B` / `BREF` picture handling and the associated
  reference management
- reference-picture management beyond the current four-reference P-slice subset
- weighted bipred support beyond the current limited `B_BI_16x16` path
- direct prediction modes beyond the current limited
  `B_DIRECT_16x16` reordered-`BREF` path
- broader sub-pel motion estimation / compensation and richer mode decision
- broader partition / transform coverage beyond the current High-profile 8x8
  transform gates
- broader `I444` / `4:4:4` format coverage beyond the current `320x176`
  strict-decode non-`I_PCM` path through `24` frames for `8-bit` and
  `10-bit`, plus spot `I_PCM` coverage
- enough profile / level / tool coverage to stop calling the repo a subset

Additional project-level open work:

- the Docker flow is still a smoke path rather than the primary long-run path
- the repo still has Verilator width and lint warnings outside the validated
  bitstream path
- the final `240`-frame `1280x720 @ 24 fps` run is not closed yet
- full-standard completion still requires closing the broader H.264 feature
  gaps rather than freezing the current subset

## Completion Criteria

The encoder should only be marked complete once:

- the remaining feature classes have the smallest representative RTL-owned
  proof that actually exercises their behavior; fixed 10-second/240-frame clips
  are optional soak evidence only
- the stream came from the RTL byte path itself
- the remaining gaps against full H.264 standard support are closed
- the final result is visually verified and decodable in FFmpeg

## Development Rules That Matter

- use the H.264 spec and primary references before making codec decisions
- use the local `x264` source tree as the default software encoder comparison
  baseline after consulting the spec
- keep the encoder end to end through the RTL bitstream path
- use `THREADS=1 BUILD_JOBS=1` by default; only use more threads for an explicit fast/max-thread run or a justified batch gate
- be wary of simulation times and prove fixes on small cases first

- 2026-05-30: added `DEBUG_CABAC_P16X16` byte-emission tracing in `rtl/h264_bitstream.v` and tightened `scripts/run_cabac_p16x16_chroma_cb_ac_arith_trace_probe.sh` to lock the common P-slice header tail emission (`d0 08 08 6b`) separately from the first CABAC payload byte and residual emitted byte tail; sparse masks `0x1`, `0x2`, and `0xc` remain one-frame `384/768` misses while `0x3`, `0x4`, and `0x8` remain full `768/768` controls.
- 2026-05-30: repaired `scripts/run_cabac_p16x16_chroma_cb_ac_terminate_wait_probe.py` after terminate-state debug instrumentation moved its staged patch anchor. The probe now preserves the current `[CABACTERM]` / header-debug calls inside the staged wait-for-flush experiment and verifies that waiting for terminate(1) output only shifts sparse-Cb miss signatures (`0x1 -> bytestream -24`, `0x2 -> -22`, `0xc -> -15`) while strict controls `0x3` and `0x4` remain full `768/768`; next repair target is still the top-row sparse-Cb AC context/order path rather than terminate flush timing.
- 2026-05-30: added `scripts/run_cabac_p16x16_chroma_cb_ac_neighbor_cbf_probe.py`, a staged negative diagnostic that replaces the current sparse-Cb-only synthetic CBF walk with direct plane-local-neighbor CBF derivation and verifies representative masks `0x1`, `0x2`, `0x3`, `0x4`, `0x8`, and `0xc` all short-decode at `384/768` (`bytestream -9/-15/-6/-15/-23/-22`). This rules out simply restoring neighbor-derived Cb AC CBF selectors: it regresses the current green controls as well as leaving the sparse cases short.
- 2026-05-30: tightened `scripts/run_cabac_p16x16_chroma_cb_ac_arith_trace_probe.sh` decoded-plane sanity from a loose nonzero-Cb-delta check to exact current second-frame SAD locks for the full-decode Cb AC controls (`0x3 -> U_SAD 128`, `0x4 -> 64`, `0x8 -> 64`, all `V_SAD 0`). This keeps the strict-decode controls honest about current reconstruction mismatch while the CABAC sparse-Cb arithmetic/tail repair remains open.
- 2026-05-30: corrected the legacy-named `scripts/run_cabac_p16x16_chroma_cb_ac_prefix_bitflip_sweep.sh` diagnostic so the common `0x6b` byte is explicitly locked as the final P-slice header/CABAC-alignment byte, with the first CABAC payload byte locked separately as `0xeb`. The two all-mask strict-decode mutations are now identified as slice-header-tail flips (`slice_qp_delta` prefix bit and `adaptive_ref_pic_marking_mode_flag`), not residual payload prefix flips, so the next repair should target the actual CABAC byte/tail path instead of chasing the header byte label.
- 2026-05-30: tightened the same prefix-bitflip diagnostic with machine-checked CABAC P-slice header field spans for the generated `d0 08 08 6b` RBSP (`pps_id=1`, `adaptive_ref_pic_marking_mode_flag=0`, `cabac_init_idc=0`, `slice_qp_delta=0`, `disable_deblocking_filter_idc=1`, and the two CABAC alignment one-bits) before accepting the first `0xeb` CABAC payload byte. This keeps future sparse-Cb AC probes from relabeling header-tail parser realignment as residual-prefix progress.
- 2026-05-30: added `scripts/run_cabac_p16x16_chroma_cb_ac_cbf_selector_sweep.py`, a staged sparse-Cb CBF selector-table regression sweep. It locks the current mapping plus simple unavailable-edge/actual-ish/all-same remaps and verifies none promote top-row masks `0x1`/`0x2` to full `768/768`; several variants also regress existing strict controls, so the next repair stays below static CBF selector choice and on CABAC arithmetic/prefix-tail decisions.
- 2026-05-30: added `scripts/run_cabac_p16x16_chroma_cb_ac_first_cabac_bitflip_sweep.sh`, an all-mask bitflip diagnostic for the first CABAC payload byte after the locked `d0 08 08 6b` P-slice header. It preserves the current baseline partition and locks that flipping bit7 of `0xeb` to `0x6b` strict-decodes every Cb-only AC mask with the expected Cb-only SAD, while bit0 only promotes high-density masks and bit2 only additionally promotes mask `0x2`. This keeps the next repair target on the first CABAC payload arithmetic decision rather than another header-tail or CBF-selector tweak.
- 2026-05-30: tightened `scripts/run_cabac_p16x16_chroma_cb_ac_queue_align_probe.py` with a both-plane Cb+Cr AC guard. The isolated `cod_i_queue -9 -> -8` workspace still promotes every Cb-only AC mask `0x1..0xf` to strict two-frame decode with byte-identical IDR, final P-slice header tail `0x6b`, first residual payload `0x75`, and expected Cb-only SAD, but the same global queue shift now explicitly locks a non-committable regression on a dense Cb+Cr AC control (`384/768`, `bytestream -9`). The next repair target is a scoped first-CABAC-payload/alignment fix that preserves both-plane Cb+Cr AC rather than changing the CABAC core start globally.
- 2026-05-30: extended `scripts/run_cabac_p16x16_chroma_cb_ac_first_payload_substitution_probe.py`, the bytestream-side diagnostic that mutates only the first CABAC payload byte after the locked `d0 08 08 6b` P-slice header. Exact `0xeb -> 0x75` and bit7 `0xeb -> 0x6b` substitutions both promote every Cb-only AC mask `0x1..0xf` to strict `768/768` decode with expected Cb-only SAD, and the dense Cb+Cr guard still strict-decodes with `U_SAD=256 V_SAD=256` under both substitutions; this separates the useful first-byte correction family from the non-committable global queue-shift side effect, so the next fix should target first-payload generation while preserving later both-plane arithmetic/output state.
- 2026-05-30: hardened `scripts/run_cabac_p16x16_chroma_cb_ac_arith_trace_probe.sh` after Verilator/testbench stdout interleaving split the blk5 CHRAC_CBF row for masks `0x5`/`0x6`. The probe now tolerates only that known non-atomic trace-row loss while still locking emitted byte chunks, stream tails, terminate pre-state, FFmpeg signatures, and decoded-plane SAD; verification passes with the same fail/pass partition (`0x1/0x2/0x5/0x6/0xc` short, `0x3/0x4/0x8` strict).
- 2026-05-30: added `scripts/run_cabac_p16x16_chroma_cr_ac_mask_probe.py` to cover the Cr-only chroma-AC mask lattice beyond the older single-block/dense controls. The new gate locks strict full `768/768` decodes for masks `0x1`, `0x2`, `0x4`, `0x6`, `0x8`, `0x9`, and `0xf` with Cr-only SAD, plus exact one-frame miss signatures for masks `0x3 -> bytestream -6`, `0x5 -> -16`, `0x7 -> -37`, `0xa -> -12`, `0xb -> -17`, `0xc -> -16`, `0xd -> -17`, and `0xe -> -7`. This widens the open chroma-AC blocker from Cb-only sparse/top-row masks to Cr multi-block ordering/arithmetic cases as well.
- 2026-05-30: added `scripts/run_cabac_p16x16_chroma_cr_ac_first_payload_substitution_probe.py`, the Cr-only counterpart to the first-CABAC-payload byte substitution diagnostic. It verifies that both exact `0xeb -> 0x75` and bit7 `0xeb -> 0x6b` mutations promote all Cr-only miss masks to strict two-frame FFmpeg decode with Cr-only SAD while preserving already-strict Cr-only masks and the dense Cb+Cr guard, matching the Cb-side first-byte correction family and keeping the next repair target on scoped first-payload generation.
- 2026-05-30: added `scripts/run_cabac_p16x16_chroma_ac_cross_plane_first_payload_probe.py`, a bounded mixed-plane Cb+Cr chroma-AC diagnostic. Representative sparse/sparse cases (`Cb/Cr 0x1/0x1`, `0x1/0x2`, `0x2/0x1`, `0x3/0x3`, `0x5/0x5`, `0xc/0xc`, `0x1/0xf`) retain their current one-frame FFmpeg miss signatures at baseline, while exact first-payload substitutions `0xeb -> 0x75` and `0xeb -> 0x6b` promote each to strict `768/768` decode with expected plane-local SAD; the dense-Cb/sparse-Cr `0xf/0x1` control remains strict under the same substitutions, and the `Cb/Cr 0xe/0x1` guard now locks the current full-decode-but-wrong-plane baseline (`U_SAD=240 V_SAD=192` instead of expected `192/64`) while the same substitutions repair it to expected plane-local SAD. This extends the first-payload repair target from single-plane probes to representative mixed-plane AC residuals and a decoded-quality failure without endorsing a global CABAC queue shift.
- 2026-05-31: tightened `scripts/run_cabac_p16x16_chroma_cb_ac_queue_align_probe.py` so the non-committable global `cod_i_queue -9 -> -8` experiment now locks the dense Cb+Cr guard at both baseline and candidate final-slice granularity. Baseline dense both-plane AC remains strict with final slice `0000000141d008086beb` and `U_SAD=256 V_SAD=256`; the queue-shift candidate short-decodes at `384/768` with `bytestream -9` and final slice `0000000141d008086bf599`, proving the regression is not the same `0xeb->0x75/0x6b` single-byte promotion family but an `0xeb->0xf5` first-residual-byte change plus trailing `0x99`.
- 2026-05-31: added `scripts/run_cabac_p16x16_chroma_cr_ac_phase_probe.sh`, the Cr-only counterpart to the sparse-Cb singleton phase/polarity probe. It locks `+4` Cr singleton perturbations as strict full-decode no-AC controls (`cr_ac_mbs=0`, `V_SAD=32`) and `+5`/`+8` Cr singleton perturbations as strict two-frame decodes with plane-local Cr-only SAD across all four quadrants and both checker parities/signs, keeping the sparse top-row short-decode blocker scoped to Cb/mixed-plane first-payload behavior rather than generic chroma-AC singleton thresholding.
- 2026-05-31: added `scripts/run_cabac_p16x16_chroma_ac_first_payload_value_sweep.py`, a bounded first-CABAC-payload value sweep over representative sparse Cb-only masks `0x1`, `0x2`, `0xc` and the dense Cb+Cr guard. It verifies the current baseline sparse-Cb `0xeb` byte stays outside the strict-decode set while known `0x6b`/`0x75` substitutions remain promoted, but also locks broad pass-counts (`180`, `180`, `181`, and `174` values respectively). This shows the first-byte symptom is a wide arithmetic-decode equivalence class, not a unique `0x75` target, so the next repair should inspect the CABAC renormalization/pending-byte boundary that generates baseline `0xeb` for sparse Cb without using a literal bytestream patch.
- 2026-05-31: tightened `scripts/run_cabac_p16x16_chroma_cb_ac_shape_probe.sh` with exact final P-slice hex locks for each coefficient-shape case. The probe now proves all strict and short Cb-only shape cases share the same `d0 08 08 6b eb` header-tail/first-payload prefix while only the following residual tail differs (`...2ed226`, `...2e`, `...2f6b5d`, `...2fa1d4`, `...2fc7`, etc.), so the next source repair should target residual coefficient emission/order or CABAC arithmetic-tail state rather than another P-slice boundary relabel or block-placement-only tweak.
- 2026-05-31: expanded the same Cb AC shape probe with the missing checker-even complements for blocks 0, 1, and 3. Blocks 0/1 now match the checker-odd short-decode signatures exactly (`bytestream -19` and `-21`, final tails `...2ed226` and `...2f6b5d`), while block 3 checker-even matches checker-odd as a strict decode with tail `...2fc5f8`; this rules out checker parity as a standalone repair axis and keeps the bug scoped to block/shape-specific residual-tail arithmetic.
- 2026-05-31: extended `scripts/run_cabac_p16x16_chroma_cb_ac_shape_probe.sh` with high-amplitude (`+32`) diagonal main/anti Cb-only shapes across all four chroma AC blocks. Every diagonal case remains a one-frame FFmpeg miss with exact final-slice tails (`...31d8697707c50a/53d`, `...31d8e37a23e285/29e`, `...31d8f0eab89b5f/6f`, `...31d87ae4c8b5f3/f4`) while preserving the existing vertical/horizontal/checker strict/miss partition, so the next source repair should inspect diagonal/zigzag coefficient ordering and CABAC residual-tail arithmetic rather than a low-amplitude threshold or CBF selector change.
- 2026-05-31: tightened `scripts/run_cabac_p16x16_chroma_cb_ac_shape_probe.sh` strict-pass validation from "nonzero Cb delta" to exact `U_SAD=40 V_SAD=0` for the current low-amplitude (`+5`) Cb-only shape cases that fully decode. The audit now requires that exact-SAD check, keeping future sparse-Cb arithmetic fixes honest about decoded-plane reconstruction while the high-amplitude shape cases remain one-frame FFmpeg misses.
- 2026-05-31: added `scripts/run_cabac_p16x16_chroma_cr_ac_shape_probe.sh`, the Cr-only counterpart to the Cb AC shape probe. Low-amplitude (`+5`) checker/vertical/horizontal shapes strict-decode across all four Cr AC blocks with exact `U_SAD=0 V_SAD=40`, while high-amplitude (`+32`) shapes now lock a Cr-specific partition: most checker/axis/diagonal cases remain one-frame misses with exact tails, but block-1 anti-diagonal and block-2 diagonals strict-decode with `V_SAD=128`. This keeps the next repair target on residual coefficient level/suffix/order arithmetic shared by Cb/Cr high-amplitude shape failures, not on a plane-generic singleton threshold or CBF selector tweak.
- 2026-05-31: extended the Cr AC shape probe with the missing high-amplitude (`+32`) axis complements. For every block, `vert_right` matches `vert_left` and `horiz_bottom` matches `horiz_top` at both the FFmpeg miss signature and final P-slice tail (`blk0 -7/-11`, `blk1 -10/-9`, `blk2 -10/-11`, `blk3 -11/-11`), ruling out simple axis-side polarity as the Cr high-amplitude blocker while preserving the diagonal strict/miss partition.
- 2026-05-31: tightened the same Cr AC shape probe with first-CABAC-payload substitution checks for every high-amplitude (`+32`) checker/axis/diagonal shape. The baseline strict/miss partition and exact final-slice tails remain locked, while both `0xeb->0x75` and bit7 `0xeb->0x6b` substitutions promote or preserve all high-amplitude shapes as strict two-frame decodes with exact Cr-only SAD (`V_SAD=128` for diagonals, `256` for checker/axis). This aligns the shape blocker with the first-payload correction family instead of a standalone coefficient-placement or axis-polarity issue.
- 2026-05-31: tightened `scripts/run_cabac_p16x16_chroma_cb_ac_shape_probe.sh` with the matching high-amplitude Cb-only first-payload substitution checks. All generated high-amplitude checker/axis/diagonal cases still keep their baseline one-frame miss signatures and exact final P-slice tails under `d0 08 08 6b eb`, but both `0xeb->0x75` and bit7 `0xeb->0x6b` one-byte substitutions promote every shape to strict `768/768` decode with byte-identical IDR and exact Cb-only SAD (`U_SAD=128` for diagonals, `256` for checker/axis). This aligns Cb shape failures with the same scoped first-payload correction family as the Cb mask, Cr mask/shape, and mixed-plane probes.
- 2026-05-31: extended `scripts/run_cabac_p16x16_chroma_ac_first_payload_value_sweep.py` with a sparse mixed-plane `Cb/Cr 0x1/0x1` guard. Its generated baseline still uses the locked `d0 08 08 6b eb` header/payload prefix and remains outside the strict expected-SAD class, while `183` single-byte first-payload values strict-decode with byte-identical IDR and exact plane-local SAD (`U_SAD=64 V_SAD=64`), including the known `0xeb->0x75` and bit7 `0xeb->0x6b` repair-family substitutions. This keeps the source target on the shared first-payload CABAC arithmetic/renormalization boundary across sparse Cb-only, Cr-only, and mixed-plane cases.
- 2026-05-31: extended `scripts/run_cabac_p16x16_chroma_ac_first_payload_value_sweep.py` from Cb-only/dense controls to representative Cr-only cases. The gate now locks pass-counts for baseline-strict `Cr mask 0x1` (`178`) and short `Cr masks 0x3/0x5` (`181`/`185`), with baseline `0xeb` outside the strict-decode class for the short Cr cases while `0x6b`/`0x75` remain promoted. This keeps the first-payload equivalence-class evidence symmetric across Cb and Cr before attempting a source arithmetic repair.
- 2026-05-31: added `scripts/run_cabac_p16x16_chroma_ac_second_payload_value_sweep.py`, a bounded second-CABAC-payload value sweep for representative Cb-only (`0x1`), Cr-only (`0x3`), and sparse Cb+Cr (`0x1/0x1`) chroma-AC misses. It keeps the shared baseline `d0 08 08 6b eb` header/first-payload prefix fixed, mutates only the following payload byte, and locks narrower strict expected-SAD classes (`26`, `36`, and `33` values respectively) with the baseline second bytes still outside those classes. This shows the byte-boundary symptom extends past the first payload byte, but the source repair should still target CABAC arithmetic/renormalization rather than literal bytestream patching.
- 2026-05-31: added `scripts/run_cabac_p16x16_chroma_ac_fourth_payload_value_sweep.py`, extending the byte-boundary diagnostics to the fourth CABAC residual payload byte for representative Cb-only (`0x1`), Cr-only (`0x3`), and sparse Cb+Cr (`0x1/0x1`) chroma-AC misses. The gate locks baseline second/third/fourth bytes and stream tails, then proves the fourth-byte expected-SAD pass classes are extremely narrow (`1`, `30`, and `1` values respectively) with baseline fourth bytes (`0x26`, `0xa0`, `0xd4`) outside those classes. This keeps the immediate source target on CABAC arithmetic/renormalization/output-byte state rather than another CBF selector or literal byte patch.
- 2026-05-31: added `scripts/run_cabac_p16x16_chroma_ac_fifth_payload_value_sweep.py`, extending the payload-boundary diagnostics one byte further where a fifth residual payload byte exists. The gate locks the Cb-only `0x1` stream as ending immediately after the fourth payload byte (`0x26`), then mutates only the fifth payload byte for Cr-only `0x3` and sparse Cb+Cr `0x1/0x1`; the strict expected-SAD pass classes are narrow (`16` and `2` values respectively) with baseline fifth bytes (`0xab`, `0x5e`) outside those classes. This reinforces that the repair target is CABAC arithmetic/renormalization/output-byte state, not a literal stream patch.
- 2026-05-31: added `scripts/run_cabac_p16x16_chroma_ac_sixth_payload_value_sweep.py`, carrying the residual-payload byte-boundary sweep to the sixth byte for streams long enough to have one. It keeps the Cb-only `0x1` boundary locked as no fifth/sixth payload byte, then proves Cr-only `0x3` has a narrow sixth-byte strict expected-SAD class (`18` values) with baseline `0xd3` outside it, while sparse Cb+Cr `0x1/0x1` has no single sixth-byte value that produces a strict expected-SAD decode from the baseline stream (`0xa4` outside an empty class). This pushes the next source repair below individual payload-byte substitution and toward CABAC arithmetic/renormalization/output-byte state across the residual tail.
- 2026-05-31: added `scripts/run_cabac_p16x16_chroma_ac_seventh_payload_value_sweep.py`, carrying the residual-payload byte-boundary sweep to the final seventh byte for the representative Cr-only `0x3` stream while locking Cb-only as ending after the fourth byte and sparse Cb+Cr `0x1/0x1` as ending after the sixth. The new gate mutates only Cr-only byte `0xf7`, finds a narrow strict expected-SAD class of `12` values (`0x03,0x12,0x31,0x76,0x7c,0x95-0x96,0xa4,0xba,0xe2,0xfa,0xfc`), and proves baseline `0xf7` remains outside it, keeping the repair target on CABAC arithmetic/renormalization/output-byte termination state rather than literal byte substitution.
- 2026-05-31: added `scripts/run_cabac_p16x16_chroma_ac_scoped_queue_probe.py`, a staged negative source-promotion probe for the queue-alignment candidate. It temporarily adds an `init_queue` port and bitstream-selected `-8` queue init based on current chroma-AC scan contents, then verifies the result behaves like baseline at slice start: sparse Cb masks `0x1`/`0x2` stay one-frame FFmpeg misses (`bytestream -19` / `-21`) while Cb mask `0x3` and dense Cb+Cr stay strict. This rules out landing queue alignment as a simple slice-start conditional on MB residual inputs and keeps the next repair target on the CABAC arithmetic/renormalization/output-byte path.
- 2026-05-31: changed the checked-in CABAC core initial `cod_i_queue` from `-9` to `-7` after `scripts/run_cabac_p16x16_chroma_ac_queue_init_sweep.py` found `-7` is the sampled plane-safe neighborhood value: legacy `-9` preserves sparse Cb `0x1`/`0x2` one-frame misses, `-8` promotes sparse Cb but regresses dense Cb+Cr, `-10` overflows, and `-7` strict-decodes sparse Cb `0x1`/`0x2`, Cb `0x3`, and dense Cb+Cr with expected plane-local SAD. The chroma singleton probe was promoted so all Cb mirror singletons now strict-decode, while the luma residual, chroma residual, zero-CBP, residual-bin, and residual-scan gates stayed green.
- 2026-05-31: promoted `scripts/run_cabac_p16x16_chroma_cb_ac_mask_probe.sh` to the post-`-7` Cb-only chroma-AC mask lattice. The gate now locks all 15 nonzero 2x2 Cb AC masks as strict two-frame FFmpeg decodes with exact Cb-only SAD (`64 * popcount(mask)`) and zero Cr delta, replacing the stale pre-`-7` one-frame miss expectations for sparse/top/split Cb masks.
- 2026-05-31: promoted `scripts/run_cabac_p16x16_chroma_cr_ac_mask_probe.py` to the matching post-`-7` Cr-only chroma-AC mask lattice. The gate now locks all 15 nonzero 2x2 Cr AC masks as strict two-frame FFmpeg decodes with exact Cr-only SAD (`64 * popcount(mask)`) and zero Cb delta, replacing the stale adjacent/top+bottom Cr one-frame miss expectations.
- 2026-05-31: promoted `scripts/run_cabac_p16x16_chroma_ac_cross_plane_first_payload_probe.py` into a post-`-7` cross-plane Cb+Cr chroma-AC strict-decode gate. The representative sparse/sparse, mirror, split-row, dense-Cb, dense-Cr, dense-both, and prior `Cb/Cr 0xe/0x1` wrong-plane case now all strict-decode two frames with exact plane-local SAD and locked final P-slice tails, replacing the stale first-payload substitution expectations.
- 2026-05-31: promoted `scripts/run_cabac_p16x16_chroma_cb_ac_shape_probe.sh` to the post-`-7` Cb-only chroma-AC coefficient-shape gate. Low-amplitude checker/axis shapes and high-amplitude checker/axis/diagonal shapes across all four Cb AC blocks now strict-decode two FFmpeg frames with byte-identical IDR, exact Cb-only SAD (`40`, `128`, or `256`), and locked final P-slice tails under the generated `d0 08 08 6b 3a...` payload prefix, replacing the stale `0xeb` first-payload substitution diagnostics for this gate.
- 2026-05-31: promoted `scripts/run_cabac_p16x16_chroma_cb_ac_amplitude_probe.sh` to the post-`-7` Cb-only chroma-AC singleton-amplitude gate. The former top-row `+5/+8` sparse-Cb short-decode expectations now strict-decode for all four Cb AC blocks with byte-identical IDR, exact Cb-only SAD (`40` or `64`), and locked `d0 08 08 6b 3a...` final P-slice tails, while `+4` checker perturbations remain no-AC full-decode controls with exact expected Cb-only mismatch (`U_SAD=32`).
- 2026-05-31: added `scripts/run_cabac_p16x16_luma_chroma_residual_check.py`, a combined integrated CABAC `P_L0_16x16` luma+Cb+Cr AC residual smoke gate. It drives one macroblock with luma residual plus both-plane chroma AC residuals, verifies strict two-frame FFmpeg decode, CABAC/chroma counters (`cb_ac_blocks=4 cr_ac_blocks=4`), `cavlc_suppressed_bits=240`, exact final P-slice `0000000141d008086b3afee9ffdd7d77fdb6f7`, and current decoded-plane metrics (`Y_SAD=2048 U_SAD=256 V_SAD=256`), making the mixed residual lane visible without overclaiming luma reconstruction quality.
- 2026-05-31: added `scripts/run_cabac_p16x16_luma_chroma_dc_residual_check.py`, the matching combined CABAC `P_L0_16x16` luma+Cb+Cr DC-only residual smoke gate. It drives one macroblock with luma residual plus both-plane chroma DC residuals, verifies strict two-frame FFmpeg decode, CABAC chroma-DC/no-AC counters, `cavlc_suppressed_bits=164`, exact final P-slice `0000000141d008086b3ab6beea5045573d34f76b`, and current decoded-plane metrics (`Y_SAD=2048 U_SAD=512 V_SAD=512`), separating DC-only mixed residual coverage from the existing AC smoke gate.
- 2026-05-31: added `scripts/run_cabac_p16x16_luma_single_chroma_ac_residual_check.py`, a mixed luma plus single-plane chroma-AC residual smoke gate. It drives separate Cb-only and Cr-only AC cases with luma residual present, verifies strict two-frame FFmpeg decode, plane-local counters (`cb_ac_blocks=4/cr_ac_blocks=0` and `0/4`), `cavlc_suppressed_bits=190`, exact final P-slices (`0000000141d008086b3abeff` and `0000000141d008086b3af7ef`), and current decoded-plane metrics (`Y_SAD=2048`, active chroma plane `SAD=256`, inactive plane `0`), covering the gap between chroma-only gates and dense both-plane luma+chroma AC smoke.
- 2026-05-31: added `scripts/run_cabac_p16x16_luma_sparse_chroma_ac_residual_check.py`, a mixed luma plus sparse chroma-AC residual smoke gate. It drives representative one-block Cb-only, one-block Cr-only, and same-block Cb+Cr AC cases with luma residual present, verifies strict two-frame FFmpeg decode, plane-local chroma-AC counters (`cb_ac_blocks` / `cr_ac_blocks`), exact CAVLC suppression counts (`151` for single-plane sparse, `162` for same-block Cb+Cr), exact final P-slice bytes, and current decoded-plane metrics (`Y_SAD=2048`, active sparse chroma block `SAD=64`, inactive plane `0`).
- 2026-05-31: added `scripts/run_cabac_p16x16_luma_single_chroma_dc_residual_check.py`, a mixed luma plus single-plane chroma-DC residual smoke gate. It drives separate Cb-only and Cr-only DC cases with luma residual present, verifies strict two-frame FFmpeg decode, chroma-DC counters (`cabac_chroma_dc_mbs=1`, no chroma-AC blocks), `cavlc_suppressed_bits=152`, exact final P-slice `0000000141d008086b3ab6beea5045573d34f7`, and current decoded-plane metrics (`Y_SAD=2048`, active chroma plane `SAD=512`, inactive plane `0`).
- 2026-05-31: added plane-local CABAC chroma-DC MB reporting in `rtl/h264_encoder_top.v` (`cb_dc_mbs` / `cr_dc_mbs`) and tightened the luma+chroma DC smoke gates plus scaffold audit to require the expected Cb-vs-Cr DC counters. This makes asymmetric DC residual coverage as explicit as the existing per-plane chroma-AC counters without changing the generated slice bytes.
- 2026-05-31: tightened the legacy-named promoted chroma residual gate (`scripts/run_cabac_p16x16_chroma_residual_red_check.sh`) to require plane-local DC MB counters for Cb-only vs Cr-only DC fixtures, the active-plane DC counters observed in Cb/Cr DC+AC fixtures, and plane-local AC block counters for Cb-only vs Cr-only DC+AC fixtures. The scaffold audit now locks those expectations so the all-chroma smoke cannot pass on only aggregate `cabac_chroma_*` counters.
- 2026-05-31: extended `scripts/run_cabac_p16x16_chroma_ac_cross_plane_first_payload_probe.py` with reciprocal and both-plane high-amplitude Cb+Cr AC guards (`Cb/Cr 0x5/0xa` at `136/160` and `160/160`). The gate now locks strict two-frame FFmpeg decode, byte-identical IDR, exact plane-local SAD (`U/V 128/512` and `512/512`), and final P-slice tails for Cb-high, Cr-high, and both-high mixed chroma-AC cases under the checked-in `cod_i_queue=-7` initializer.
- 2026-05-31: extended the cross-plane chroma-AC gate with the reciprocal `Cb/Cr 0xa/0x5` high-amplitude guards at `160/136`, `136/160`, and `160/160`. These cases strict-decode two FFmpeg frames with exact plane-local SAD (`U/V 512/128`, `128/512`, and `512/512`) and lock the generated final P-slice tails, closing the mirror-mask amplitude coverage gap without changing RTL.
- 2026-05-31: extended the same cross-plane chroma-AC high-amplitude guard with all-but-one complements `Cb/Cr 0x1/0xe`, `0xe/0x1`, and `0xd/0x2` at `160/160`. These strict-decode two FFmpeg frames with exact plane-local SAD (`U/V 256/768`, `768/256`, and `768/256`) and locked final P-slice tails, while keeping the known `0x2/0xd` complement out of the promoted set until its `bytestream -16` miss is understood.
